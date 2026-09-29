#!/bin/sh
# 权限面守卫：ACL 只授予页面真正用到的东西。
#
# 依据：LuCI 视图只通过 fs.exec 调两个已授权的可执行文件，脚本以 root 身份运行
# （rpcd 只校验"能不能执行"，不替子进程做 uci 鉴权），所以 ACL 里的 uci 读写
# 对这个页面毫无用处 —— 多授予一分就是多一分的越权面。
# 这里钉三件事：双向覆盖（用到的都有授权）、不多授（没有多余的 uci 权限）、
# 菜单依赖的键仍在读取范围内。
set -u
NM_TEST_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
NM_ROOT="$(CDPATH= cd -- "${NM_TEST_DIR}/.." && pwd)"
cd "${NM_ROOT}" || exit 1

ACL="root/usr/share/rpcd/acl.d/luci-app-h5000m-netmode.json"
MENU="root/usr/share/luci/menu.d/luci-app-h5000m-netmode.json"
JS="htdocs/luci-static/resources/view/h5000m/netmode.js"

fail() { echo "FAIL: $*" >&2; exit 1; }

[ -f "${ACL}" ] || fail "找不到 ACL：${ACL}"
# 去掉空白，后面按固定形态比对
acl_flat="$(tr -d ' \t' < "${ACL}")"

echo '=== ① 视图用到的每个可执行文件都必须有 exec 授权 ==='
targets="$(grep -o "fs\.exec('[^']*'" "${JS}" | sed "s/^fs\.exec('//; s/'$//" | sort -u)"
[ -n "${targets}" ] || fail '没有从视图里解析出任何 fs.exec 目标（正则或代码结构变了？）'
for p in ${targets}; do
	printf '%s' "${acl_flat}" | grep -qF "\"${p}\":[\"exec\"]" \
		|| fail "视图调用了未授权的路径：${p}"
	echo "  ok  已授权 ${p}"
done

echo '=== ② 不许多授予 uci 权限 ==='
n="$(printf '%s' "${acl_flat}" | grep -o '"uci":\[[^]]*\]' | wc -l | tr -d ' ')"
[ "${n}" = "1" ] || fail "ACL 里的 uci 授权应只有读取组一处，实际 ${n} 处（写入组不该有）"
printf '%s' "${acl_flat}" | grep -qF '"uci":["h5000m_netmode"]' \
	|| fail "ACL 的 uci 读取范围必须只有 h5000m_netmode（实际：$(printf '%s' "${acl_flat}" | grep -o '"uci":\[[^]]*\]'))"
echo '  ok  uci 仅读取 h5000m_netmode'

echo '=== ③ 菜单依赖的 uci 键必须在读取范围内 ==='
for key in $(grep -o '"uci"[^}]*}' "${MENU}" | grep -o '"[a-z0-9_]*"[[:space:]]*:[[:space:]]*true' | grep -o '"[a-z0-9_]*"' | tr -d '"'); do
	printf '%s' "${acl_flat}" | grep -qF "\"${key}\"" \
		|| fail "菜单依赖 uci.${key}，但 ACL 没有授予它的读取权限"
	echo "  ok  菜单依赖 ${key} 已授权"
done

echo '=== ④ 视图不得直接操作 uci ==='
if grep -qE "require 'uci'|L\.uci" "${JS}"; then
	fail '视图直接使用了 uci —— 那 ACL 的 uci 授权就不再是多余的，这个守卫的前提失效'
fi
echo '  ok  视图只用 fs.exec，不碰 uci'

echo 'acl tests passed'
