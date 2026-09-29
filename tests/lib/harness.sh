#!/bin/sh
# netmode 测试沙箱：用假 uci/ubus/ip/jsonfilter/ifup/ifdown/logger/pgrep 在离线环境里
# 跑真实控制器，从而统计子进程开销、验证幂等性与事件入口，全程不碰真机网络。
#
# 用法（在测试脚本里）：
#   NM_TEST_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
#   NM_ROOT="$(CDPATH= cd -- "${NM_TEST_DIR}/.." && pwd)"
#   . "${NM_TEST_DIR}/lib/harness.sh"
#
# 注：POSIX sh 里 `$0` 在被 source 的文件中仍指向调用者，所以仓库根必须由调用方
# 显式传进来（不能用 ${BASH_SOURCE}，那在 dash/busybox ash 下不存在）。
#
# 所有外部命令的调用都会记进 ${NM_STATE}/calls.log，nm_count 用来数次数。
# 注意：本文件是库，不改调用方的 shell 选项。跑外部命令时要临时关掉 errexit，
# nm_run / nm_hotplug 进出都会用 nm_save_shell_opts / nm_restore_shell_opts 还原
# （set -e 一旦漏给调用方，后面任何一条失败命令都会把用例提前掐死）。
# 需要严格模式的用例自己 set -eu。

NM_ROOT="${NM_ROOT:?NM_ROOT must be set by the caller before sourcing harness.sh}"
NM_CONTROLLER="${NM_ROOT}/root/usr/sbin/h5000m-netmode"
NM_HOTPLUG="${NM_ROOT}/root/etc/hotplug.d/iface/95-h5000m-netmode"

# nm_run 的退出码（注意：nm_run 放在 $( ) 里跑的话这个变量不会传出来）
NM_RC=0

nm_sandbox() {
	NM_STATE="$(mktemp -d)"
	NM_BIN="${NM_STATE}/bin"
	# 控制器与钩子读取的绝对路径在这里统一导出一次：nm_run 与 nm_hotplug 都要用。
	# 早先两个入口各写一份 6 行赋值前缀，改一处忘一处就会让两边跑在不同的沙箱里。
	export NM_STATE NM_BIN
	export H5000M_NETMODE_LOCK_DIR="${NM_STATE}/lock"
	export H5000M_NETMODE_DAED_EXIT_STATE="${NM_STATE}/daed-exit"
	export H5000M_NETMODE_NETWORK_INIT="${NM_BIN}/network-init"
	export H5000M_NETMODE_DAED_INIT="${NM_BIN}/daed-init"
	export H5000M_NETMODE_MANAGER="${NM_BIN}/mt5700m-manager"
	export H5000M_NETMODE_USB_SH="${NM_STATE}/usb.sh"
	export H5000M_NETMODE_BIN="${NM_BIN}/netmode-bin"
	mkdir -p "${NM_BIN}"

	# ---------------------------------------------------------------- uci 桩
	# 每个配置文件是一行一条：@<节>=<类型> 与 <节>.<选项>=<值>。
	cat > "${NM_BIN}/uci" <<'STUB'
#!/bin/sh
[ "${1:-}" = "-q" ] && shift
cmd="${1:-}"; shift 2>/dev/null || true
state="${NM_STATE}/uci"
cffile() { printf '%s/%s' "${state}" "$1"; }
setkv() { # setkv <file> <key> <value>
	f="${1}"; k="${2}"; v="${3}"
	if grep -q "^${k}=" "${f}" 2>/dev/null; then
		grep -v "^${k}=" "${f}" > "${f}.tmp" || true
		printf '%s=%s\n' "${k}" "${v}" >> "${f}.tmp"
		mv "${f}.tmp" "${f}"
	else
		printf '%s=%s\n' "${k}" "${v}" >> "${f}"
	fi
}
echo "uci $cmd $*" >> "${NM_STATE}/calls.log"
case "${cmd}" in
	get)
		path="${1:-}"; cfg="${path%%.*}"; rest="${path#*.}"
		[ "${rest}" != "${path}" ] || exit 1
		f="$(cffile "${cfg}")"; [ -f "${f}" ] || exit 1
		case "${rest}" in
			*.*) sec="${rest%%.*}"; opt="${rest#*.}"
			     v="$(sed -n "s/^${sec}\.${opt}=//p" "${f}" | head -n 1)"
			     [ -n "${v}" ] || exit 1
			     printf '%s\n' "${v}" ;;
			*)   v="$(sed -n "s/^@${rest}=//p" "${f}" | head -n 1)"
			     [ -n "${v}" ] || exit 1
			     printf '%s\n' "${v}" ;;
		esac
		;;
	show)
		cfg="${1:-}"; f="$(cffile "${cfg}")"; [ -f "${f}" ] || exit 1
		sed -n "s/^@\([^=]*\)=\(.*\)/${cfg}.\1=\2/p" "${f}"
		;;
	set)
		kv="${1:-}"; path="${kv%%=*}"; val="${kv#*=}"
		cfg="${path%%.*}"; rest="${path#*.}"
		mkdir -p "${state}"; f="$(cffile "${cfg}")"
		if [ "${rest}" = "${path}" ]; then setkv "${f}" "@${rest}" "${val}"
		else
			case "${rest}" in
				*.*) sec="${rest%%.*}"; opt="${rest#*.}"; setkv "${f}" "${sec}.${opt}" "${val}" ;;
				*)   setkv "${f}" "@${rest}" "${val}" ;;
			esac
		fi
		;;
	delete)
		path="${1:-}"; cfg="${path%%.*}"; rest="${path#*.}"
		f="$(cffile "${cfg}")"
		if [ -f "${f}" ]; then
			grep -vE "^(@${rest}|${rest}\.)" "${f}" > "${f}.tmp" 2>/dev/null || true
			mv "${f}.tmp" "${f}"
		fi
		;;
	commit|add_list|del_list) : ;;
	*) exit 1 ;;
esac
exit 0
STUB

	# --------------------------------------------------------------- ubus 桩
	cat > "${NM_BIN}/ubus" <<'STUB'
#!/bin/sh
echo "ubus $*" >> "${NM_STATE}/calls.log"
[ "${1:-}" = "call" ] || exit 1
obj="${2:-}"
case "${obj}" in
	network.interface.*)
		name="${obj#network.interface.}"
		f="${NM_STATE}/iface/${name}.json"
		[ -f "${f}" ] || exit 1
		cat "${f}"
		;;
	*) exit 1 ;;
esac
exit 0
STUB

	# --------------------------------------------------------- jsonfilter 桩
	cat > "${NM_BIN}/jsonfilter" <<'STUB'
#!/bin/sh
echo "jsonfilter $*" >> "${NM_STATE}/calls.log"
expr=""
while [ $# -gt 0 ]; do
	case "$1" in
		-e) expr="${2:-}"; shift 2 ;;
		*) shift ;;
	esac
done
field="${expr#@.}"
body="$(cat)"
line="$(printf '%s' "${body}" | tr -d '\n' \
	| sed -n "s/.*\"${field}\"[[:space:]]*:[[:space:]]*\([^,}]*\).*/\1/p")"
[ -n "${line}" ] || exit 1
case "${line}" in
	\"*\") printf '%s\n' "${line}" | sed 's/^"//; s/"$//' ;;
	*)     printf '%s\n' "${line}" ;;
esac
exit 0
STUB

	# ----------------------------------------------------------------- ip 桩
	cat > "${NM_BIN}/ip" <<'STUB'
#!/bin/sh
echo "ip $*" >> "${NM_STATE}/calls.log"
case "$*" in
	"-4 route show default") cat "${NM_STATE}/route4" 2>/dev/null || true ;;
	"-6 route show default") cat "${NM_STATE}/route6" 2>/dev/null || true ;;
	"-4 addr show dev "*)     cat "${NM_STATE}/addr4_${4}" 2>/dev/null || true ;;
	*) : ;;
esac
exit 0
STUB

	# ------------------------------------------------- ifup / ifdown / logger
	for stub in ifup ifdown logger; do
		cat > "${NM_BIN}/${stub}" <<STUB
#!/bin/sh
echo "${stub} \$*" >> "\${NM_STATE}/calls.log"
exit 0
STUB
	done

	cat > "${NM_BIN}/pgrep" <<'STUB'
#!/bin/sh
echo "pgrep $*" >> "${NM_STATE}/calls.log"
[ -s "${NM_STATE}/pgrep" ] || exit 1
cat "${NM_STATE}/pgrep"
exit 0
STUB

	# ------------------------------------------------- 可被替换的 init 脚本桩
	# 默认都成功退出；用例可以覆写成失败版本来验证错误路径。
	for init in network-init daed-init; do
		cat > "${NM_BIN}/${init}" <<STUB
#!/bin/sh
echo "${init} \$*" >> "\${NM_STATE}/calls.log"
exit 0
STUB
	done

	# hotplug 里的控制器路径是绝对的，PATH 拦不住 —— 用包装脚本记录并转发。
	cat > "${NM_BIN}/netmode-bin" <<STUB
#!/bin/sh
echo "netmode-bin \$*" >> "\${NM_STATE}/calls.log"
exec sh "${NM_CONTROLLER}" "\$@"
STUB
	chmod +x "${NM_BIN}"/* 2>/dev/null || true
	mkdir -p "${NM_STATE}/uci" "${NM_STATE}/iface"
	: > "${NM_STATE}/route4"; : > "${NM_STATE}/route6"; : > "${NM_STATE}/calls.log"

	# 默认装置：有线 WAN 与 5G 模组都在网络配置里，默认路由走 5G（本机现状）
	nm_uci_raw network.MT5700M=interface
	nm_uci_raw network.MT5700M.device=eth2
	nm_uci_raw network.MT5700M.proto=dhcp
	nm_uci_raw network.wan=interface
	nm_uci_raw network.wan.device=eth1
	nm_uci_raw network.wan6=interface
	nm_uci_raw network.wan6.device=eth1
	nm_uci_raw h5000m_netmode.settings=settings
	nm_uci_raw h5000m_netmode.settings.mode=wan_first
	nm_iface wan      '{"up":false,"available":false,"l3_device":"eth1"}'
	nm_iface wan6     '{"up":false,"available":false,"l3_device":"eth1"}'
	nm_iface MT5700M  '{"up":true,"available":true,"l3_device":"eth2"}'
	nm_route4 'default via 10.0.0.1 dev eth2 proto static metric 50'
}

nm_cleanup() { [ -n "${NM_STATE:-}" ] && rm -rf "${NM_STATE}"; }

# nm_on_exit <收尾函数> —— 用例统一的收尾方式。
# EXIT 负责正常路径；INT/TERM 必须真的 `exit`：只挂函数的话信号处理返回后
# 脚本会继续跑，CI 上一个卡住的用例连超时都杀不干净。
nm_on_exit() {
	trap "$1" EXIT
	trap 'exit 130' INT
	trap 'exit 143' TERM
}

# nm_uci_raw <cfg>.<sec>[.<opt>]=<value>   —— 直接写沙箱里的配置
nm_uci_raw() { "${NM_BIN}/uci" set "$1" >/dev/null; }

# nm_uci_get <path> —— 直接读沙箱里的配置（读不到时打印空串）
nm_uci_get() { "${NM_BIN}/uci" get "$1" 2>/dev/null || true; }

# nm_uci_del <cfg>.<sec> —— 从沙箱配置里真的删掉一个节（连它的选项一起）。
# 用它才能测出"段不存在时的兜底"：只把节类型改掉是不够的 —— 桩把
# `network.wan6` 记成 `@wan6=`，读的时候照样命中，用例会以为自己覆盖了缺失场景。
nm_uci_del() { "${NM_BIN}/uci" delete "$1" >/dev/null 2>&1 || true; }

# nm_iface <name> <json>
nm_iface() { printf '%s\n' "$2" > "${NM_STATE}/iface/$1.json"; }

nm_route4() { printf '%s\n' "$1" > "${NM_STATE}/route4"; }
nm_route6() { printf '%s\n' "$1" > "${NM_STATE}/route6"; }

# 跑外部命令要临时关掉 errexit（才拿得到真实退出码），但**不能**把自己的
# errexit 留给调用方 —— 库改了调用方的选项，后面任何一条失败命令都会把用例
# 提前掐死在莫名其妙的位置，看着像环境问题而不是断言失败。所以进出各记一次。
nm_save_shell_opts() {
	case "$-" in
		*e*) NM_HAD_ERREXIT=1 ;;
		*)   NM_HAD_ERREXIT=0 ;;
	esac
}

nm_restore_shell_opts() {
	if [ "${NM_HAD_ERREXIT:-0}" = "1" ]; then
		set -e
	else
		set +e
	fi
}

# nm_run [--allow-fail] <控制器参数...>
# 沙箱用的那些环境变量统一由 nm_sandbox 导出，这里只把沙箱 bin 顶到 PATH 最前。
nm_run() {
	local _af=0 _rc
	[ "${1:-}" = "--allow-fail" ] && { _af=1; shift; }
	nm_save_shell_opts
	set +e
	PATH="${NM_BIN}:${PATH}" sh "${NM_CONTROLLER}" "$@" 2>&1
	_rc=$?
	nm_restore_shell_opts
	NM_RC="${_rc}"
	[ "${_af}" = "1" ] || [ "${_rc}" = "0" ] || {
		echo "nm_run $* 失败 rc=${_rc}" >&2
		return "${_rc}"
	}
	return 0
}

# nm_hotplug <INTERFACE> <ACTION> —— 走真实的 hotplug 入口（含 1 秒延迟）
nm_hotplug() {
	local _rc
	nm_save_shell_opts
	set +e
	PATH="${NM_BIN}:${PATH}" INTERFACE="$1" ACTION="$2" sh "${NM_HOTPLUG}" 2>&1
	_rc=$?
	nm_restore_shell_opts
	[ "${_rc}" = "0" ] || { echo "hotplug $* 失败 rc=${_rc}" >&2; return "${_rc}"; }
	return 0
}

nm_calls_reset() { : > "${NM_STATE}/calls.log"; }

# nm_count <正则前缀> —— 数 calls.log 里以该前缀开头的调用行（锚在行首）。
# 参数直接当扩展正则用，所以字面量点号要转义（例如 `uci set network\.`）。
# 这里**不加**「前缀后面必须紧跟空白或行尾」这种要求：真实调用长这样
# `uci set network.wan.metric=50`，前缀后面直接接选项名，硬要词边界就一条都数不到。
# 那不是"更严格"，而是**恒为 0**：期望 0 的断言会恒绿、期望 ≥1 的会假红，两种都在骗人。
nm_count() { grep -cE "^$1" "${NM_STATE}/calls.log" 2>/dev/null || true; }

# nm_wait_call <cmd> [max_seconds] —— hotplug 是后台触发的，等它真的发生
nm_wait_call() {
	local _n=0 _max="${2:-8}"
	while [ "${_n}" -lt "${_max}" ]; do
		[ "$(nm_count "$1")" -gt 0 ] && return 0
		sleep 1; _n=$((_n + 1))
	done
	return 1
}

# nm_wait_file <路径> [max_seconds] —— 等某个标记文件出现（轮询 0.2 秒）。
# 需要「某件事正在发生」的用例用它造确定性的窗口，而不是 sleep 一个猜出来的时长：
# 机器快慢不同，猜出来的窗口迟早会假红（慢机器上"还没发生"，快机器上"已经结束"）。
nm_wait_file() {
	local _n=0 _max="${2:-30}"
	while [ ! -e "$1" ]; do
		[ "${_n}" -lt "$((_max * 5))" ] || return 1
		sleep 0.2
		_n=$((_n + 1))
	done
	return 0
}

# nm_wait_quiet_window [seconds] —— 给「不该触发」的用例留出一段静默观察时间。
# 名字说的是"等一段静默窗口"，不是"验证真的静默"：它只负责等，判断由调用方
# 用 nm_count 做（钩子本身有 1 秒固定延迟，窗口必须长于它）。
nm_wait_quiet_window() { sleep "${1:-3}"; }

nm_fail() { echo "FAIL: $*" >&2; exit 1; }
