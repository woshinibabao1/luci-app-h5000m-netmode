#!/bin/sh
# 翻译一致性守卫：po 与源码必须一一对应，双向都不许剩。
#
# 这个仓库没有翻译扫描器，po 是手写的，所以两个方向都可能烂掉：
#   方向 A：视图里 _() 用了、po 里没有  -> 该处回落英文（可见回退）
#   方向 B：po 里有、源码里已经不用的旧文案 -> 纯冗余，且会掩盖"某处已改口径"
# 语料取**全部受版本控制的文件**（排除 po 自身），而不是只看视图 ——
# 菜单标题之类的 msgid 只出现在 menu.d 里，只看视图会误判成孤儿。
set -u
NM_TEST_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
NM_ROOT="$(CDPATH= cd -- "${NM_TEST_DIR}/.." && pwd)"
cd "${NM_ROOT}" || exit 1

PO="po/zh_Hans/h5000m-netmode.po"
JS="htdocs/luci-static/resources/view/h5000m/netmode.js"

fail() { echo "FAIL: $*" >&2; exit 1; }

git rev-parse --git-dir >/dev/null 2>&1 || fail '需要在 git 仓库里运行（用 git grep 取语料）'

echo '=== ① 视图用到的文案必须都在 po 里 ==='
used="$(grep -o "_('[^']*')" "${JS}" | sed "s/^_('//; s/')$//" | sort -u)"
[ -n "${used}" ] || fail '没有从视图里解析出任何 _() 文案'
missing=0
old_ifs="${IFS}"; IFS='
'
for s in ${used}; do
	IFS="${old_ifs}"
	grep -qF "msgid \"${s}\"" "${PO}" || { echo "  缺失：${s}" >&2; missing=$((missing + 1)); }
	IFS='
'
done
IFS="${old_ifs}"
[ "${missing}" = "0" ] || fail "有 ${missing} 条视图文案在 po 里缺失（会回落英文）"
echo "  ok  $(printf '%s\n' "${used}" | grep -c .) 条文案全部有翻译"

echo '=== ② po 里的每条 msgid 都必须仍被源码引用 ==='
ids="$(awk '/^msgid "/{ v=$0; sub(/^msgid "/, "", v); sub(/"$/, "", v); if (v != "") print v }' "${PO}" | sort -u)"
[ -n "${ids}" ] || fail '没有从 po 里解析出任何 msgid'
orphan=0
IFS='
'
for s in ${ids}; do
	IFS="${old_ifs}"
	git grep -qF -e "'${s}'" -e "\"${s}\"" -- ':!po' \
		|| { echo "  孤儿：${s}" >&2; orphan=$((orphan + 1)); }
	IFS='
'
done
IFS="${old_ifs}"
[ "${orphan}" = "0" ] || fail "有 ${orphan} 条孤儿 msgid（源码里已无人引用）"
echo "  ok  $(printf '%s\n' "${ids}" | grep -c .) 条 msgid 全部仍被引用"

echo '=== ③ msgstr 不许为空 ==='
# 方向 A 只证明 msgid 存在。msgstr 为空的条目是合法 po，msgfmt 也照样放行，
# 但界面上会静默回落英文 —— 手写的 po 最容易这样悄悄退化成半成品。
empty="$(awk -v hdr='msgid ""' -v blank='msgstr ""' '
	/^msgid /  { id = ($0 == hdr) ? "" : $0; next }
	/^msgstr / { if ($0 == blank && id != "") print id; id = "" }
' "${PO}")"
[ -z "${empty}" ] || fail "有 msgstr 为空的条目（界面会回落英文）：${empty}"
echo '  ok  没有空 msgstr 的条目'

echo '=== ④ 头部版本号必须与 Makefile 的 PKG_VERSION 一致 ==='
pkg_version="$(sed -n 's/^PKG_VERSION:=//p' Makefile)"
[ -n "${pkg_version}" ] || fail '读不到 Makefile 的 PKG_VERSION'
grep -qF "Project-Id-Version: luci-app-h5000m-netmode ${pkg_version}" "${PO}" \
	|| fail "po 头部版本与 Makefile 不一致（Makefile=${pkg_version}）"
echo "  ok  头部版本 = ${pkg_version}"

echo 'i18n tests passed'
