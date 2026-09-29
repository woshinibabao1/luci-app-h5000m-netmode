#!/bin/sh
# 成本契约：「不做多余的工作」。
#
# 控制器跑在路由器上，每次探测、每个外部命令都是一个真实进程；LuCI 又用
# rpcd 的 file-exec 拉起状态查询，而 rpcd 是单线程的 —— 多起一个进程就是
# 多阻塞一次整个 LuCI。这份用例钉住三件在优化里最容易退化的事：
#   ① 一次 reconcile 只探测一次链路状态（多个调用点不能各探一遍）
#   ② 没有变化的 apply 不写 /etc/config/network
#   ③ 没有变化的 apply 不写 /etc/config/h5000m_netmode
# ④ 反过来：策略真的变了必须落盘，否则上面三条会退化成"什么都不写"
set -u
NM_TEST_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
NM_ROOT="$(CDPATH= cd -- "${NM_TEST_DIR}/.." && pwd)"
. "${NM_TEST_DIR}/lib/harness.sh"

nm_sandbox
nm_on_exit nm_cleanup

eq() { # eq <说明> <实际> <期望>
	[ "$2" = "$3" ] || nm_fail "$1：实际 [$2] 期望 [$3]"
	echo "  ok  $1 = $2"
}

# nm_run_ok <说明> <控制器参数...> —— 失败时把控制器的输出一并带出来，
# 否则只有一句"失败"，连是环境问题还是真缺陷都分不清。
nm_run_ok() {
	_desc="$1"; shift
	nm_run "$@" > "${NM_STATE}/last.out" 2>&1 \
		|| nm_fail "${_desc}（rc=${NM_RC}）：$(cat "${NM_STATE}/last.out")"
}

# 先让配置收敛到稳定态，后面才有"无变化"可谈
nm_run_ok '收敛用的首次 apply' apply

echo '=== ① 一次 reconcile 只探测一次链路状态 ==='
nm_run_ok 'reconcile' reconcile
nm_run_ok 'reconcile' reconcile
nm_calls_reset
nm_run_ok 'reconcile' reconcile
# align_ipv6_to_active4 与 reload_daed_on_exit_change 都要读实时状态，
# 但同一次调用里那是同一份快照，不该把 4 次 ubus 查询各做两遍。
eq '探测 wan 状态'  "$(nm_count 'ubus call network.interface.wan status')"  '1'
eq '探测 wan6 状态' "$(nm_count 'ubus call network.interface.wan6 status')" '1'
eq '探测模组口状态' "$(nm_count 'ubus call network.interface.MT5700M status')" '1'

echo '=== ② 无变化的 apply 不写 network ==='
nm_calls_reset
nm_run_ok '第二次 apply' apply
eq 'uci set network.*'    "$(nm_count 'uci set network\.')"    '0'
eq 'uci commit network'   "$(nm_count 'uci commit network')"  '0'

echo '=== ③ 无变化的 apply 不写 h5000m_netmode ==='
eq 'uci set h5000m_netmode.*'  "$(nm_count 'uci set h5000m_netmode\.')"  '0'
eq 'uci commit h5000m_netmode' "$(nm_count 'uci commit h5000m_netmode')" '0'

echo '=== ④ 策略真的变了就必须落盘 ==='
nm_calls_reset
nm_run_ok 'set modem_only' set modem_only
eq '配置里的 mode' "$(nm_uci_get h5000m_netmode.settings.mode)" 'modem_only'
[ "$(nm_count 'uci commit h5000m_netmode')" -ge 1 ] || nm_fail '策略变了却没有落盘'
[ "$(nm_count 'uci set network\.')" -ge 1 ] || nm_fail '策略变了却没有改网络配置'
echo "  ok  策略变化仍然会落盘"

echo 'cost tests passed'
