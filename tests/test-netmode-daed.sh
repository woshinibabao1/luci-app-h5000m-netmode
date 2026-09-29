#!/bin/sh
# daed 重载路径测试。
#
# README 承诺「默认出口变化时自动触发已安装代理服务的重载」，而这条路径此前
# 没有任何用例覆盖 —— 状态文件的读写、pgrep 的匹配式、restart 失败后的重试
# 全都只靠人眼看。这里钉五件事：
#   ① 首次收敛只记录状态，不重启（没有"上一个出口"可比，也不该去打扰 daemon）；
#   ② 出口真的变了且 daed 在跑 → 走 procd 的 restart，成功后更新状态文件；
#   ③ daed 没在跑 → 只更新状态（它下次启动会自己发现生效路由）；
#   ④ restart 失败 → 状态文件**不得**更新，否则下一个事件会以为已经同步过而放过；
#   ⑤ 出口没变 → 既不重启也不写状态（热插拔会反复调用，不能每次都动 daemon）。
set -u
NM_TEST_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
NM_ROOT="$(CDPATH= cd -- "${NM_TEST_DIR}/.." && pwd)"
. "${NM_TEST_DIR}/lib/harness.sh"

nm_sandbox
nm_on_exit nm_cleanup
STATE="${NM_STATE}/daed-exit"

eq() { # eq <说明> <实际> <期望>
	[ "$2" = "$3" ] || nm_fail "$1：实际 [$2] 期望 [$3]"
	echo "  ok  $1 = $2"
}

# 让 pgrep 报告"daed 在跑"/"没在跑"：桩读 ${NM_STATE}/pgrep，空文件即未命中。
daed_running() { printf '4242\n' > "${NM_STATE}/pgrep"; }
daed_stopped() { : > "${NM_STATE}/pgrep"; }

daemon_restarts() { nm_count 'daed-init restart'; }

echo '=== ① 首次收敛：只记录状态，不打扰 daemon ==='
nm_route4 'default via 10.0.0.1 dev eth2 proto static metric 50'
nm_calls_reset
nm_run reconcile >/dev/null 2>&1 || nm_fail '首次 reconcile 失败'
eq '首次记录的出口' "$(cat "$STATE" 2>/dev/null || true)" 'modem'
eq '首次不得重启 daed' "$(daemon_restarts)" '0'
grep -qF 'recorded initial daed IPv4 exit=modem' "${NM_STATE}/calls.log" \
	|| nm_fail '首次记录没有留下日志'

echo '=== ② 出口变化 + daed 在跑 → 重启并更新状态 ==='
daed_running
nm_route4 'default via 10.0.0.1 dev eth1 proto static metric 10'
nm_calls_reset
nm_run reconcile >/dev/null 2>&1 || nm_fail '出口切到有线后 reconcile 失败'
eq '状态文件已更新' "$(cat "$STATE")" 'wan'
eq '重启 daed 的次数' "$(daemon_restarts)" '1'
grep -qF 'restarted daed after IPv4 exit changed modem->wan' "${NM_STATE}/calls.log" \
	|| nm_fail '重启之后没有留下日志'
# 匹配式必须指向 daed 的 run 子命令；写错正则时 pgrep 永远不命中，
# 于是"重载 daed"这条功能会静默失效（本机没装 daed，只有这里能钉住）。
grep -qF 'pgrep -f ^/usr/bin/daed run([[:space:]]|$)' "${NM_STATE}/calls.log" \
	|| nm_fail "pgrep 的匹配式不对：$(grep '^pgrep' "${NM_STATE}/calls.log" | head -n 1)"

echo '=== ③ 出口变化但 daed 没在跑 → 只更新状态 ==='
daed_stopped
nm_route4 'default via 10.0.0.1 dev eth2 proto static metric 50'
nm_calls_reset
nm_run reconcile >/dev/null 2>&1 || nm_fail '出口切回模组后 reconcile 失败'
eq '状态文件已更新' "$(cat "$STATE")" 'modem'
eq '不得重启（daemon 没在跑）' "$(daemon_restarts)" '0'
grep -qF 'daemon is not running' "${NM_STATE}/calls.log" \
	|| nm_fail 'daemon 没在跑时没有留下日志'

echo '=== ④ restart 失败 → 状态不得更新，下一个事件必须重试 ==='
cat > "${NM_BIN}/daed-init" <<'STUB'
#!/bin/sh
echo "daed-init $*" >> "${NM_STATE}/calls.log"
exit 1
STUB
chmod +x "${NM_BIN}/daed-init"
daed_running
nm_route4 'default via 10.0.0.1 dev eth1 proto static metric 10'
nm_run --allow-fail reconcile >/dev/null 2>&1 || true
[ "${NM_RC}" = "1" ] || nm_fail "restart 失败时控制器应报错退出（实际 ${NM_RC}）"
eq '失败后状态文件保持原值' "$(cat "$STATE")" 'modem'
grep -qF 'failed to restart daed after IPv4 exit changed modem->wan' "${NM_STATE}/calls.log" \
	|| nm_fail '重启失败没有留下日志'

# 恢复 daed-init 后重试必须成功 —— 这就是"状态没更新"换来的重试能力。
cat > "${NM_BIN}/daed-init" <<'STUB'
#!/bin/sh
echo "daed-init $*" >> "${NM_STATE}/calls.log"
exit 0
STUB
chmod +x "${NM_BIN}/daed-init"
nm_calls_reset
nm_run reconcile >/dev/null 2>&1 || nm_fail '恢复后重试 reconcile 失败'
eq '重试后状态更新' "$(cat "$STATE")" 'wan'
[ "$(daemon_restarts)" -ge 1 ] || nm_fail '重试时没有重新拉起 daed'

echo '=== ⑤ 出口没变 → 不重启、不写状态 ==='
nm_calls_reset
nm_run reconcile >/dev/null 2>&1 || nm_fail '无变化 reconcile 失败'
eq '不得重启' "$(daemon_restarts)" '0'
eq '状态保持' "$(cat "$STATE")" 'wan'
if grep -q 'restarted daed\|recorded initial daed' "${NM_STATE}/calls.log"; then
	nm_fail '出口没变却写了状态或重启了 daed'
fi
echo '  ok  无变化时完全静默'

echo 'daed reload tests passed'
