#!/bin/sh
# 链路事件入口（hotplug）测试。
#
# 判据：**只要接口的 ifup/ifdown 会改变默认出口，就必须触发 reconcile**。
# 最容易漏的是模组数据口本身 —— 它通常没有 modem_config / managed_by 标记，
# 只认那两个标记会让 5G 侧完全失去事件来源（而 5G 正是本机的主出口）。
set -u
NM_TEST_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
NM_ROOT="$(CDPATH= cd -- "${NM_TEST_DIR}/.." && pwd)"
. "${NM_TEST_DIR}/lib/harness.sh"

nm_sandbox
nm_on_exit nm_cleanup

# lan 是「无关接口」，用来说明钩子不是无差别触发
nm_uci_raw network.lan=interface
nm_uci_raw network.lan.device=br-lan
# v6 别名形态：device='@<主接口>'
nm_uci_raw network.MT5700Mv6=interface
nm_uci_raw network.MT5700Mv6.device=@MT5700M
# 主段被命名为 USB 的形态（厂商旧命名）：别名是 '@USB'。钩子必须按 device
# 反查段名，写死 '@MT5700M' 会把这一形态整个漏掉。
nm_uci_raw network.USB=interface
nm_uci_raw network.USB.device=eth2
nm_uci_raw network.USBv6=interface
nm_uci_raw network.USBv6.device=@USB

expect_trigger() { # expect_trigger <说明> <INTERFACE> <ACTION>
	nm_calls_reset
	nm_hotplug "$2" "$3" >/dev/null 2>&1 || true
	if nm_wait_call netmode-bin 8; then
		echo "  ok  触发 reconcile：$1"
	else
		nm_fail "未触发 reconcile：$1（$2 $3）"
	fi
}

expect_silent() { # expect_silent <说明> <INTERFACE> <ACTION>
	nm_calls_reset
	nm_hotplug "$2" "$3" >/dev/null 2>&1 || true
	nm_wait_quiet_window 3
	n=$(nm_count netmode-bin)
	[ "${n}" = "0" ] || nm_fail "不该触发却触发了：$1（$2 $3，调用 ${n} 次）"
	echo "  ok  正确跳过：$1"
}

echo '=== 必须触发 ==='
expect_trigger '有线 WAN 上线'        wan       ifup
expect_trigger '有线 WAN 下线'        wan       ifdown
expect_trigger 'WAN IPv6 上线'        wan6      ifup
expect_trigger '5G 模组数据口上线'    MT5700M   ifup
expect_trigger '5G 模组数据口下线'    MT5700M   ifdown
expect_trigger '5G 的 IPv6 别名上线'  MT5700Mv6 ifup
expect_trigger '主段名为 USB 的模组口上线' USB   ifup
expect_trigger 'USB 形态的 IPv6 别名上线' USBv6 ifup

echo '=== 必须跳过 ==='
expect_silent '无关接口 lan'          lan       ifup
expect_silent '非 ifup/ifdown 动作'   wan       ifupdate
expect_silent '空动作'                wan       ''
expect_silent '空接口'                ''        ifup

echo 'hotplug event tests passed'
