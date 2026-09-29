#!/bin/sh
# 测试装置自身的契约。
#
# 所有用例都站在 harness 上，装置一旦失真，别的用例"通过"就不说明任何问题。
# 最典型的一种：库把 errexit 漏给调用方 —— 之后任何一条失败命令都会把用例
# 掐死在莫名其妙的位置，现象看着像"环境问题"，而不是断言失败。
# 这里钉七件装置承诺的事：进出不改调用方的 shell 选项、退出码如实报回、
# 计数辅助必须真的数得到（第 ⑤ 项 —— 一条数不到的断言比没有断言更危险）、
# 等待辅助必须有超时上限（第 ⑥ 项）、删除辅助的锚点必须精确（第 ⑦ 项）、
# uci show 的输出形态与空值语义必须与真机同形（第 ⑧ 项）、
# jsonfilter 必须实现多表达式语义（第 ⑨ 项）。
# 第 ④ 项反向验证：调用方本来就开着 errexit 时，装置必须还回去。
set -u
NM_TEST_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
NM_ROOT="$(CDPATH= cd -- "${NM_TEST_DIR}/.." && pwd)"
. "${NM_TEST_DIR}/lib/harness.sh"

nm_sandbox
nm_on_exit nm_cleanup

echo '=== ① nm_run 不得改变调用方的 shell 选项 ==='
options_before="$-"
nm_run status >/dev/null 2>&1 || nm_fail 'nm_run status 失败'
[ "$-" = "${options_before}" ] \
	|| nm_fail "nm_run 改了调用方的 shell 选项：调用前 [${options_before}]，调用后 [$-]"
echo "  ok  nm_run 前后一致（[${options_before}]）"

echo '=== ② nm_hotplug 不得改变调用方的 shell 选项 ==='
nm_hotplug wan ifup >/dev/null 2>&1 || nm_fail 'nm_hotplug 失败'
[ "$-" = "${options_before}" ] \
	|| nm_fail "nm_hotplug 改了调用方的 shell 选项：[$-]"
echo '  ok  nm_hotplug 前后一致'

echo '=== ③ 退出码要如实报回 ==='
nm_run --allow-fail set bogus >/dev/null 2>&1 || true
[ "${NM_RC}" = "64" ] || nm_fail "非法模式应报回 64，实际 ${NM_RC}"
echo "  ok  NM_RC=${NM_RC}（非法模式 exit 64）"

echo '=== ④ 调用方本来就开着 errexit 时必须还回去 ==='
(
	set -e
	nm_run status >/dev/null 2>&1 || true
	case "$-" in
		*e*) echo restored ;;
		*)   echo lost ;;
	esac
) > "${NM_STATE}/errexit.out" 2>&1 || true
grep -q '^restored$' "${NM_STATE}/errexit.out" \
	|| nm_fail "调用方开着 errexit，nm_run 没有还回去：$(cat "${NM_STATE}/errexit.out")"
echo '  ok  调用方的 errexit 被还原'

echo '=== ⑤ nm_count 必须是行首前缀匹配 ==='
# 真实调用长这样：`uci set network.wan.metric=50` —— 前缀后面直接接选项名。
# 若要求"前缀后必须紧跟空白或行尾"，这些行一条都数不到，于是「期望 0」的断言
# 恒绿、「期望 ≥1」的断言假红，两种都在骗人。这里连同"点号要转义"一起钉住。
cat > "${NM_STATE}/calls.log" <<'EOF'
uci set network.wan.metric=50
uci set network.wan6.metric=50
uci set h5000m_netmode.settings.mode=modem_only
uci set networkish=1
uci commit network
EOF
n="$(nm_count 'uci set network\.')"
[ "${n}" = "2" ] || nm_fail "uci set network. 应数到 2 行，实际 ${n}（点号不转义会误命中 networkish）"
n="$(nm_count 'uci set h5000m_netmode\.')"
[ "${n}" = "1" ] || nm_fail "uci set h5000m_netmode. 应数到 1 行，实际 ${n}"
n="$(nm_count 'uci commit network')"
[ "${n}" = "1" ] || nm_fail "uci commit network 应数到 1 行，实际 ${n}"
n="$(nm_count 'uci set networkish')"
[ "${n}" = "1" ] || nm_fail "前缀匹配本身应当生效，实际 ${n}"
echo '  ok  nm_count 行首前缀匹配（2 / 1 / 1，且不误命中 networkish）'

echo '=== ⑥ nm_wait_file 必须有超时上限 ==='
# 它是用来代替 sleep 猜窗口的：一旦没有上限，用例在卡死时会连失败都报不出来。
if nm_wait_file "${NM_STATE}/never-appears" 1; then
	nm_fail 'nm_wait_file 对永不出现的文件返回了成功'
fi
: > "${NM_STATE}/appears"
nm_wait_file "${NM_STATE}/appears" 5 || nm_fail 'nm_wait_file 没有等到已经存在的文件'
echo '  ok  超时返回失败；文件已存在时立即返回成功'

echo '=== ⑦ uci delete 桩的锚点必须精确 ==='
# 两个方向都会骗人：锚点太宽（原先的 `^@${rest}` 未带等号）会在删 network.USB 时
# 把 network.USBv6 一起删掉 —— 于是"删干净了"的断言恒绿；锚点太窄则删选项时静默
# 什么都不做 —— 于是"选项没了"的断言永远测不到真实行为。两种都要钉住。
nm_uci_raw network.USB=interface
nm_uci_raw network.USB.device=eth2
nm_uci_raw network.USBv6=interface
nm_uci_raw network.USBv6.device=@USB
nm_uci_raw network.USBv6.auto=1

nm_uci_del network.USB
[ -z "$(nm_uci_get network.USB)" ] || nm_fail 'delete 没有删掉 network.USB 这个节'
[ "$(nm_uci_get network.USBv6)" = "interface" ] \
	|| nm_fail '删 network.USB 时误伤了 network.USBv6（前缀相同的另一个节）'
echo '  ok  删节很精确（@USB 走了，@USBv6 留着）'

nm_uci_del network.USBv6.auto
[ -z "$(nm_uci_get network.USBv6.auto)" ] || nm_fail 'delete 没有删掉选项 network.USBv6.auto'
[ "$(nm_uci_get network.USBv6)" = "interface" ] || nm_fail '删选项时把整个节也删了'
[ "$(nm_uci_get network.USBv6.device)" = "@USB" ] || nm_fail '删选项时误删了同节里的其它选项'
echo '  ok  删选项很精确（选项走了，节与其它选项留着）'

echo '=== ⑧ uci show 桩的输出形态必须与真机同形 ==='
# 控制器不再按段逐个 `uci get`，而是直接在 `uci show network` 的文本上用参数
# 展开取段与选项。桩的输出形态一旦偏离真机（节行不带引号、选项行的值带单引号、
# 空值选项不落盘），那套取值链就会在"测试全绿"的假象下失灵。
nm_uci_raw network.showprobe=interface
nm_uci_raw network.showprobe.device=eth9
nm_uci_raw network.showprobe.empty=
show_out="$("${NM_BIN}/uci" show network)"
printf '%s\n' "${show_out}" | grep -qxF 'network.showprobe=interface' \
	|| nm_fail "show 的节行形态不对：$(printf '%s\n' "${show_out}" | grep showprobe | tr '\n' '|')"
printf '%s\n' "${show_out}" | grep -qxF "network.showprobe.device='eth9'" \
	|| nm_fail "show 的选项行形态不对（值必须带单引号）：$(printf '%s\n' "${show_out}" | grep showprobe | tr '\n' '|')"
printf '%s\n' "${show_out}" | grep -q 'showprobe\.empty' \
	&& nm_fail 'show 打印了空值选项，真机不打印（会把"选项缺省"与"选项为空"混为一谈）'
"${NM_BIN}/uci" get network.showprobe.empty >/dev/null 2>&1 \
	&& nm_fail 'get 读到了空值选项，真机读不到'
echo '  ok  show 的节行/选项行/空值语义都与真机一致'

echo '=== ⑨ jsonfilter 桩必须实现多表达式语义 ==='
# 真机实测：按 -e 顺序逐个求值、取不到的键直接跳过（不打印空行）、
# 只要有一个取不到退出码就是 1。控制器一次调用取 up + l3_device + device，
# 靠的正是"第一个值一定是 up、第二个一定是设备"这个顺序性质。
jf_multi="$(printf '%s' '{"up":true,"l3_device":"eth2","device":"eth2"}' \
	| "${NM_BIN}/jsonfilter" -e '@.up' -e '@.l3_device' -e '@.device')"
[ "${jf_multi}" = 'true
eth2
eth2' ] || nm_fail "多表达式输出形态不对：[${jf_multi}]"

jf_miss="$(printf '%s' '{"up":false,"device":"eth1"}' \
	| "${NM_BIN}/jsonfilter" -e '@.up' -e '@.l3_device' -e '@.device' 2>/dev/null)"
jf_rc=$?
[ "${jf_miss}" = 'false
eth1' ] || nm_fail "缺键时必须跳过而不是打印空行：[${jf_miss}]"
[ "${jf_rc}" = '1' ] || nm_fail "有键取不到时退出码应为 1，实际 ${jf_rc}"
echo '  ok  多表达式按序输出、缺键跳过、任一缺失即非 0'

echo 'harness contract tests passed'
