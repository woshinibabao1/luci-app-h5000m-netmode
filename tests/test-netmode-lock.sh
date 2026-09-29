#!/bin/sh
# 锁行为测试。
#
# 锁是「事件风暴」下唯一的互斥手段，所以除了"能互斥"，还要证明两件容易漏的事：
#   ① 持有者进程已经死了（或 pid 不可读）时必须能抢回来，否则事件会被永久挡住；
#   ② 释放时只删自己的锁 —— 期间锁若已被别人按过期规则抢走，删掉就等于
#      把别人的临界区拆了（两个实例会同时改默认出口）。
set -u
NM_TEST_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
NM_ROOT="$(CDPATH= cd -- "${NM_TEST_DIR}/.." && pwd)"
. "${NM_TEST_DIR}/lib/harness.sh"

nm_sandbox
# 兜底：无论怎么退出都要收走假"持有者"进程和沙箱目录
nm_teardown() {
	# ⑤ 的放行标记：用例失败时也要把还卡在屏障里的 apply 放出来，
	# 否则它会一直挂到屏障自己的上限才退出。
	[ -n "${NM_STATE:-}" ] && : > "${NM_STATE}/reload-go" 2>/dev/null
	[ -n "${holder:-}" ] && kill "${holder}" 2>/dev/null
	nm_cleanup
}
nm_on_exit nm_teardown
LOCK="${NM_STATE}/lock"

echo '=== ① 正常跑完必须释放锁 ==='
nm_run reconcile >/dev/null 2>&1 || nm_fail 'reconcile 执行失败'
[ -d "${LOCK}" ] && nm_fail '锁没有被释放'
echo '  ok  执行结束后锁已释放'

echo '=== ② 被活进程持有时必须拒绝并发执行 ==='
# 用一个活得足够久的进程当"锁的持有者"：用例自身要跑好几个控制器，
# 持有者如果在半路自然退出，后面的用例就会退化成"持有者已死"分支。
sleep 600 &
holder=$!
mkdir -p "${LOCK}"
printf '%s\n' "${holder}" > "${LOCK}/pid"
nm_run --allow-fail reconcile >/dev/null 2>&1 || true
[ "${NM_RC}" = "2" ] || nm_fail "并发实例应 exit 2，实际 ${NM_RC}"
[ -d "${LOCK}" ] || nm_fail '并发实例把别人的锁删掉了'
echo "  ok  并发实例被拒绝（exit 2）且未动别人的锁"
rm -rf "${LOCK}"

echo '=== ③ 持有者已死（pid 不可读）时必须抢回来 ==='
mkdir -p "${LOCK}"
printf 'not-a-pid\n' > "${LOCK}/pid"
nm_run reconcile >/dev/null 2>&1 || nm_fail '残留锁没有被清除，事件会被永久挡住'
[ -d "${LOCK}" ] && nm_fail '僵尸锁没有被清理'
echo '  ok  残留锁被清除且执行成功'

echo '=== ④ 持有者进程还在但锁已过期，必须抢回来 ==='
mkdir -p "${LOCK}"
printf '%s\n' "${holder}" > "${LOCK}/pid"
touch -t 202001010000 "${LOCK}"
nm_calls_reset
nm_run reconcile >/dev/null 2>&1 || nm_fail '过期锁没有被抢占'
grep -q 'breaking a stale lock' "${NM_STATE}/calls.log" \
	|| nm_fail '抢占过期锁时没有留下日志'
[ -d "${LOCK}" ] && nm_fail '执行结束后锁没有释放'
echo '  ok  过期锁被抢占（有日志）且执行成功'

echo '=== ⑤ 释放时不得删除别人的锁 ==='
# 造一个**确定性**的持锁窗口：apply 拿到锁之后、释放之前一定会调用 NETWORK_INIT
# reload，把这个桩换成"报到 + 等放行"。于是"锁正被持有"是事实，而不是 sleep 猜出来的
# 时长 —— 机器一慢，猜的窗口不是"还没持锁"就是"已经放手"，用例就会假红。
cat > "${NM_BIN}/network-init" <<STUB
#!/bin/sh
echo "network-init \$*" >> "\${NM_STATE}/calls.log"
: > "\${NM_STATE}/reload-reached"
_n=0
while [ ! -e "\${NM_STATE}/reload-go" ] && [ "\${_n}" -lt 150 ]; do
	sleep 0.2
	_n=\$((_n + 1))
done
exit 0
STUB
chmod +x "${NM_BIN}/network-init"
( nm_run apply >/dev/null 2>&1 ) &
runner=$!
nm_wait_file "${NM_STATE}/reload-reached" 30 \
	|| nm_fail 'apply 始终没走到 reload 阶段，无法确认它持有锁'
[ -d "${LOCK}" ] || nm_fail '窗口内锁应当存在（apply 已持锁）'
printf '%s\n' "${holder}" > "${LOCK}/pid"
: > "${NM_STATE}/reload-go"
wait "${runner}" 2>/dev/null || true
[ -d "${LOCK}" ] || nm_fail '释放阶段删掉了不属于自己的锁'
echo '  ok  只释放自己的锁（外来的锁被保留）'
rm -rf "${LOCK}"

kill "${holder}" 2>/dev/null || true
echo 'lock tests passed'
