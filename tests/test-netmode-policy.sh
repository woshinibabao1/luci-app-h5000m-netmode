#!/bin/sh
# 出口策略与幂等性测试。
#
# 覆盖五件事：
#   ① 四种模式 + IPv6 对齐后的最终配置组合
#      （注意：apply_policy 写入的原始表会被 align_ipv6_to_active4 再按"当前生效出口"
#        收敛一次，所以期望值必须取"对齐之后"的，不能只抄 apply_policy 的字面值）
#   ② 非法配置值的处理（UCI 里是垃圾值、命令行传垃圾模式、wan6 段缺失）
#   ③ 幂等：同一策略重复应用不得反复改写网络配置（否则每次热插拔都在写 flash）
#   ④ IPv6 归属必须跟随生效的 IPv4 出口
#   ⑤ 多路径默认路由下的出口判定（^route_device 的取向）
set -u
NM_TEST_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
NM_ROOT="$(CDPATH= cd -- "${NM_TEST_DIR}/.." && pwd)"
. "${NM_TEST_DIR}/lib/harness.sh"

nm_sandbox
nm_on_exit nm_cleanup

# IPv6 别名接口，用来覆盖 modem6 那几个选项
nm_uci_raw network.MT5700Mv6=interface
nm_uci_raw network.MT5700Mv6.device=@MT5700M

eq() { # eq <说明> <实际> <期望>
	[ "$2" = "$3" ] || nm_fail "$1：实际 [$2] 期望 [$3]"
	echo "  ok  $1 = $2"
}

echo '=== ① 四种模式（IPv6 对齐后的最终状态）==='
# check_mode <mode> <生效出口所在网卡> <wan_metric> <modem_metric>
#            <wan_dr> <wan6_dr> <wan6_auto> <modem4_dr> <modem6_dr> <modem6_auto>
check_mode() {
	_route_dev="$2"
	if [ "${_route_dev}" = "-" ]; then
		nm_route4 ''
	else
		nm_route4 "default via 10.0.0.1 dev ${_route_dev} proto static metric 10"
	fi
	nm_run set "$1" >/dev/null 2>&1 || nm_fail "set $1 执行失败"
	eq "$1: wan.metric"            "$(nm_uci_get network.wan.metric)"            "$3"
	eq "$1: MT5700M.metric"        "$(nm_uci_get network.MT5700M.metric)"        "$4"
	eq "$1: wan.defaultroute"      "$(nm_uci_get network.wan.defaultroute)"      "$5"
	eq "$1: wan6.defaultroute"     "$(nm_uci_get network.wan6.defaultroute)"     "$6"
	eq "$1: wan6.auto"             "$(nm_uci_get network.wan6.auto)"             "$7"
	eq "$1: MT5700M.defaultroute"  "$(nm_uci_get network.MT5700M.defaultroute)"  "$8"
	eq "$1: MT5700Mv6.defaultroute" "$(nm_uci_get network.MT5700Mv6.defaultroute)" "$9"
	eq "$1: MT5700Mv6.auto"        "$(nm_uci_get network.MT5700Mv6.auto)"        "${10}"
	eq "$1: 配置里的 mode"         "$(nm_uci_get h5000m_netmode.settings.mode)" "$1"
	eq "$1: wan.norelease"         "$(nm_uci_get network.wan.norelease)"         '1'
}

#                     mode        出口   wan  modem wan4 wan6 w6auto m4dr m6dr m6auto
check_mode wan_first   eth1   10  50   1  1  1   1  0  0
check_mode modem_first eth2   50  10   1  0  0   1  1  1
check_mode wan_only    eth1   10  50   1  1  1   0  0  0
check_mode modem_only  eth2   50  10   0  0  0   1  1  1

echo '=== ② 非法配置值 ==='
nm_run --allow-fail set bogus > "${NM_STATE}/bogus.out" 2>&1 || true
[ "${NM_RC}" = "64" ] || nm_fail "非法模式应 exit 64，实际 ${NM_RC}"
grep -q 'invalid exit policy' "${NM_STATE}/bogus.out" \
	|| nm_fail "非法模式的报错文案不对：$(cat "${NM_STATE}/bogus.out")"
echo "  ok  非法模式被拒绝（exit 64）"

nm_uci_raw h5000m_netmode.settings.mode=bogus
nm_run --allow-fail status > "${NM_STATE}/junk.out" 2>&1 || true
grep -q '^mode=wan_first$' "${NM_STATE}/junk.out" \
	|| nm_fail "UCI 垃圾值没有被归一：$(grep '^mode=' "${NM_STATE}/junk.out")"
echo "  ok  UCI 垃圾值被归一成 wan_first"
nm_run --allow-fail set wan_first >/dev/null 2>&1 || true
eq '垃圾值已被写回合法值' "$(nm_uci_get h5000m_netmode.settings.mode)" 'wan_first'

# wan6 段真的不存在时不得报错（interface_exists 兜底要把整节跳过）。
# 必须**真的删掉**这一节：只把节类型改掉是测不出来的 —— 桩把节记成 `@wan6=`，
# 读 `network.wan6` 照样命中，用例会以为自己覆盖了"缺失"场景，其实什么都没验证。
nm_uci_del network.wan6
[ -z "$(nm_uci_get network.wan6)" ] \
	|| nm_fail 'wan6 段没有被真的删掉，这条用例就失去意义了'
nm_run --allow-fail set wan_first >/dev/null 2>&1 || nm_fail 'wan6 段缺失时不应失败'
echo "  ok  wan6 段真的缺失时仍能完成"

# 恢复沙箱的 network 配置
nm_uci_raw network.wan6=interface
nm_uci_raw network.wan6.device=eth1
[ "$(nm_uci_get network.wan6)" = "interface" ] || nm_fail 'wan6 段没有被恢复'
echo "  ok  wan6 段已恢复"

echo '=== ③ 幂等：重复应用不得反复改写网络配置 ==='
nm_route4 'default via 10.0.0.1 dev eth2 proto static metric 50'
nm_run set wan_first >/dev/null 2>&1 || nm_fail '首次 set 失败'
# 故意把策略值改坏，制造"确有变化"的第一次 apply —— 否则幂等结论无法证伪
nm_uci_raw network.wan.metric=99
nm_calls_reset
nm_run apply >/dev/null 2>&1 || nm_fail '第一次 apply 失败'
first=$(nm_count 'uci set network\.')
eq '被改坏的 metric 已纠正' "$(nm_uci_get network.wan.metric)" '10'
nm_calls_reset
nm_run apply >/dev/null 2>&1 || nm_fail '第二次 apply 失败'
second=$(nm_count 'uci set network\.')
echo "  第一次 apply 写 network 次数=${first}；第二次=${second}"
[ "${first}" -ge 1 ] || nm_fail '第一次 apply 竟然没有写任何网络配置'
[ "${second}" = "0" ] || nm_fail "第二次 apply 又写了 ${second} 次网络配置（幂等性不成立）"
echo "  ok  重复 apply 不再改写 network"

# IPv6 侧同理：把 auto 改坏，第一次对齐全写回，第二次一笔不写
nm_uci_raw network.wan6.auto=1
nm_calls_reset
nm_run reconcile >/dev/null 2>&1 || nm_fail '第一次 reconcile 失败'
r1=$(nm_count 'uci set network\.')
own1=$(nm_uci_get h5000m_netmode.settings.ipv6_owner)
nm_calls_reset
nm_run reconcile >/dev/null 2>&1 || nm_fail '第二次 reconcile 失败'
r2=$(nm_count 'uci set network\.')
echo "  第一次 reconcile 写 network 次数=${r1}；第二次=${r2}"
[ "${r1}" -ge 1 ] || nm_fail '第一次 reconcile 没有做任何对齐'
[ "${r2}" = "0" ] || nm_fail "重复 reconcile 又写了 ${r2} 次网络配置"
echo "  ok  重复 reconcile 不再改写 network"

echo '=== ④ IPv6 归属跟随生效的 IPv4 出口 ==='
# 沙箱里默认路由走 eth2（模组）⇒ 生效出口是模组 ⇒ IPv6 应归模组
eq 'ipv6_owner 跟随生效出口' "${own1}" 'modem'
eq 'wan6 默认路由已让位' "$(nm_uci_get network.wan6.defaultroute)" '0'
eq 'wan6 不再自动拉起' "$(nm_uci_get network.wan6.auto)" '0'
[ "${r1}" -ge 1 ] || nm_fail '首次 reconcile 没有做任何对齐'

# 把默认出口换成有线 WAN，再 reconcile ⇒ IPv6 应改归 WAN
nm_route4 'default via 10.0.0.1 dev eth1 proto static metric 10'
nm_run reconcile >/dev/null 2>&1 || nm_fail '切换出口后 reconcile 失败'
eq '出口换到有线后 ipv6_owner' "$(nm_uci_get h5000m_netmode.settings.ipv6_owner)" 'wan'
eq 'wan6 默认路由恢复' "$(nm_uci_get network.wan6.defaultroute)" '1'
eq 'MT5700Mv6 默认路由让位' "$(nm_uci_get network.MT5700Mv6.defaultroute)" '0'

echo '=== ⑤ 多路径默认路由要取最后一个 dev ==='
# 多路径默认路由形如
#   default nexthop via A dev eth1 weight 1 nexthop via B dev eth2 weight 1
# 原先用 `sed 's/.* dev \([^ ]*\).*/\1/p'`，贪婪的 `.* dev ` 取的是**最后一个** dev。
# route_device 改成 shell 参数展开之后必须保持同一取向（`##` = 最长前缀），
# 换成 `#` 就会静默取成第一个，把出口判反。
nm_route4 'default nexthop via 10.0.0.1 dev eth1 weight 1 nexthop via 10.0.0.2 dev eth2 weight 1'
nm_run reconcile >/dev/null 2>&1 || nm_fail '多路径（最后一个 dev 是模组）reconcile 失败'
eq '多路径：末位 dev eth2 ⇒ 模组' "$(nm_uci_get h5000m_netmode.settings.ipv6_owner)" 'modem'

nm_route4 'default nexthop via 10.0.0.1 dev eth2 weight 1 nexthop via 10.0.0.2 dev eth1 weight 1'
nm_run reconcile >/dev/null 2>&1 || nm_fail '多路径（最后一个 dev 是有线）reconcile 失败'
eq '多路径：末位 dev eth1 ⇒ 有线' "$(nm_uci_get h5000m_netmode.settings.ipv6_owner)" 'wan'

echo '=== ⑥ 无参路径（uci-defaults）：落策略 + 对齐 IPv6，但不 reload ==='
# 旧版是 apply_policy 顺手写那四个 v6 开关，现在它们归对齐步骤管，无参路径必须
# 自己补一次。先把 v6 侧故意改坏，再看它是否按"退回策略首选"写回来。
nm_route4 ''
nm_uci_raw network.wan6.defaultroute=0
nm_uci_raw network.wan6.auto=0
nm_uci_raw network.MT5700Mv6.defaultroute=1
nm_uci_raw network.MT5700Mv6.auto=1
nm_calls_reset
nm_run >/dev/null 2>&1 || nm_fail '无参调用失败'
eq '无参：mode 保持不变' "$(nm_uci_get h5000m_netmode.settings.mode)" 'wan_first'
eq '无参：wan6.defaultroute' "$(nm_uci_get network.wan6.defaultroute)" '1'
eq '无参：wan6.auto' "$(nm_uci_get network.wan6.auto)" '1'
eq '无参：MT5700Mv6.defaultroute' "$(nm_uci_get network.MT5700Mv6.defaultroute)" '0'
eq '无参：MT5700Mv6.auto' "$(nm_uci_get network.MT5700Mv6.auto)" '0'
eq '无参：不得 reload network' "$(nm_count 'network-init')" '0'

echo '=== ⑦ reload 之后必须重探：新增的接口段不能漏 ==='
nm_cleanup
nm_sandbox
# 让"专用管理器"在 sync 里新增一个 v6 别名段 —— 这正是 reload 之后才出现的段。
# 若对齐步骤还拿着 reload 之前的清单，新段在 interface_exists 处会被判"不存在"，
# 它的选项一个都不会落盘，而且一声不响（改了记忆化就必须盯住这一点）。
cat > "${NM_BIN}/mt5700m-manager" <<STUB
#!/bin/sh
echo "mt5700m-manager \$*" >> "\${NM_STATE}/calls.log"
if [ "\${1:-}" = "sync" ]; then
	"\${NM_BIN}/uci" set network.USBv6=interface
	"\${NM_BIN}/uci" set network.USBv6.device=@MT5700M
fi
exit 0
STUB
chmod +x "${NM_BIN}/mt5700m-manager"
nm_route4 'default via 10.0.0.1 dev eth2 proto static metric 10'
nm_run apply >/dev/null 2>&1 || nm_fail 'apply 失败'
eq '新增别名的 defaultroute 已落盘' "$(nm_uci_get network.USBv6.defaultroute)" '1'
eq '新增别名的 auto 已落盘' "$(nm_uci_get network.USBv6.auto)" '1'

echo 'policy tests passed'
