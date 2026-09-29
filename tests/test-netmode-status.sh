#!/bin/sh
# status 动作的契约测试。
#
# status 是唯一对外只读的接口（LuCI 每 5 秒查一次，ACL 也只放开了这一个），
# 它的输出被当成"key=value 协议"消费。这里钉四件事：
#   ① 段缺失时不得报出 netifd 的默认值 —— 真机上没有模组 v6 别名段时，
#      usbv6_defaultroute / usbv6_auto 曾被报成 1，等于谎报"备用线路 v6 已启用"；
#      "段在、选项缺"才轮到 netifd 默认值，这两种情形必须分开；
#   ② 物理设备的取值链（l3_device 优先 → device 兜底 → 配置里的 device → ifname）
#      必须在真机同形的 JSON 上成立；
#   ③ 发现结果（主段名/设备）跟随实际配置，而不是写死 MT5700M；
#   ④ status 必须无锁、只读：LuCI 轮询撞上一次正在跑的 reconcile 时不能失败，
#      更不能写配置或拆掉别人的锁。
set -u
NM_TEST_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
NM_ROOT="$(CDPATH= cd -- "${NM_TEST_DIR}/.." && pwd)"
. "${NM_TEST_DIR}/lib/harness.sh"

nm_sandbox
holder=""
nm_teardown() {
	[ -n "${holder}" ] && kill "${holder}" 2>/dev/null
	nm_cleanup
}
nm_on_exit nm_teardown

# 一次调用取一份快照，后面所有断言都从它里面读（status 每次要跑十来个进程，
# 每个断言各跑一次就太贵了）。注意在函数里赋值：nm_fail 必须在外层 shell 里
# 生效，放进 $( ) 里只会退出那个子 shell。
snapshot() {
	SNAPSHOT="$(nm_run status)" || nm_fail 'status 执行失败'
}
field() { # field <键名>
	printf '%s\n' "${SNAPSHOT}" | sed -n "s/^$1=//p"
}
eq() { # eq <说明> <实际> <期望>
	[ "$2" = "$3" ] || nm_fail "$1：实际 [$2] 期望 [$3]"
	echo "  ok  $1 = $2"
}

echo '=== ① 段缺失不得报 netifd 默认值；选项缺省才给默认值 ==='
# 装置里没有模组 v6 别名段：三个 usbv6_* 都必须是空（"读不到"），
# 而不是报成 netifd 的默认值 1。
SNAPSHOT="$(nm_run status)" || nm_fail 'status 执行失败'
eq 'usbv6_defaultroute（段缺失）' "$(field usbv6_defaultroute)" ''
eq 'usbv6_auto（段缺失）'        "$(field usbv6_auto)" ''
eq 'usbv6_metric（段缺失）'      "$(field usbv6_metric)" ''
eq 'modem6_interface（段缺失）'  "$(field modem6_interface)" ''
# 反向对照：wan6 段在、没写 defaultroute/auto，这才是"取 netifd 默认值"的场合。
eq 'wan6_defaultroute（选项缺省）' "$(field wan6_defaultroute)" '1'
eq 'wan6_auto（选项缺省）'         "$(field wan6_auto)" '1'
# 真的写成 0 时必须如实报出来，不能被默认值盖掉。
nm_uci_raw network.wan6.defaultroute=0
snapshot
eq 'wan6_defaultroute（显式 0）' "$(field wan6_defaultroute)" '0'
nm_uci_del network.wan6.defaultroute

echo '=== ② 别名的 v6 开关被如实报出 ==='
nm_uci_raw network.MT5700Mv6=interface
nm_uci_raw network.MT5700Mv6.device=@MT5700M
nm_uci_raw network.MT5700Mv6.defaultroute=1
nm_uci_raw network.MT5700Mv6.auto=1
snapshot
eq 'modem6_interface' "$(field modem6_interface)" 'MT5700Mv6'
eq 'usbv6_defaultroute' "$(field usbv6_defaultroute)" '1'
eq 'usbv6_auto' "$(field usbv6_auto)" '1'

echo '=== ③ 设备取值链：l3_device 优先、device 兜底、配置兜底、ifname 最后 ==='
# l3_device 与 device 不同时必须取 l3_device（默认路由的 dev 是 L3 设备）。
nm_iface wan '{"up":true,"available":true,"l3_device":"eth7","device":"eth1"}'
snapshot
eq 'l3_device 优先' "$(field wan_device)" 'eth7'
# 真机下线接口的形态：只有 device，没有 l3_device。
nm_iface wan '{"up":false,"available":true,"device":"eth8"}'
snapshot
eq 'device 兜底' "$(field wan_device)" 'eth8'
# netifd 里没有这个接口（刚写进配置还没 reload）→ 退回配置里的 device。
rm -f "${NM_STATE}/iface/wan.json"
snapshot
eq '配置 device 兜底' "$(field wan_device)" 'eth1'
# 配置里只有 ifname（老写法）→ 用 ifname。
nm_uci_del network.wan.device
nm_uci_raw network.wan.ifname=eth9
snapshot
eq 'ifname 兜底' "$(field wan_device)" 'eth9'
# 两者都在时 device 必须赢。
nm_uci_raw network.wan.device=eth6
snapshot
eq 'device 优先于 ifname' "$(field wan_device)" 'eth6'
nm_uci_raw network.wan.device=eth1
nm_uci_del network.wan.ifname

echo '=== ④ 主段名是发现出来的，不是写死的 ==='
# 把模组主段改成厂商旧命名 USB（device 仍是 eth2）→ 报出来的主段名必须跟着变。
nm_uci_del network.MT5700M
nm_uci_raw network.USB=interface
nm_uci_raw network.USB.device=eth2
nm_iface USB '{"up":true,"available":true,"l3_device":"eth2"}'
snapshot
eq '主段名跟随配置' "$(field modem_interface)" 'USB'
eq '主段设备' "$(field modem_device)" 'eth2'
eq '主段在场' "$(field modem_present)" '1'
eq '出口判定仍为模组' "$(field active4)" 'modem'

echo '=== ⑤ status 无锁、只读 ==='
# 造一个"别人正持锁"的状态：status 若去抢锁就会失败（或把别人的锁拆掉）。
sleep 600 &
holder=$!
mkdir -p "${NM_STATE}/lock"
printf '%s\n' "${holder}" > "${NM_STATE}/lock/pid"
nm_calls_reset
nm_run status >/dev/null 2>&1 || nm_fail 'status 被锁挡住了 —— 它是只读动作，不该取锁'
[ -d "${NM_STATE}/lock" ] || nm_fail 'status 动过别人的锁'
eq '别人的锁未被改写' "$(cat "${NM_STATE}/lock/pid")" "${holder}"
eq 'status 不得写配置' "$(nm_count 'uci (set|commit|delete)')" '0'
kill "${holder}" 2>/dev/null || true
holder=""
rm -rf "${NM_STATE}/lock"

echo 'status contract tests passed'
