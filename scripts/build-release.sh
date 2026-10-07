#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work_dir="${RUNNER_TEMP:-/tmp}/h5000m-netmode-sdk"
output_dir="${repo_dir}/dist-release"

# 包格式：默认 apk，PKG_FORMAT=ipk 时产出 opkg 能装的 .ipk。
#
# ★ 实现方式是「换 SDK」，不是「关CONFIG_USE_APK」。
#   24.10-SNAPSHOT 的 SDK 里config USE_APK（config/Config-build.in:71）
#   默认 y，且 defconfig 会把它强制拉回 —— 实测往 .config 写
#   "# CONFIG_USE_APK is not set" 后 defconfig 结束仍是 CONFIG_USE_APK=y，
#   该符号不是普通的可选开关，没有干净的关法。
#   而 23.05 的 SDK 里根本不存在这个符号，opkg 就是默认，包格式天然 ipk。
#   本项目的 MT5700 Console 参照工程也是这么分的（main→apk、23.05→ipk）。
#   两条线共用同一份包内容，只换 SDK 版本，产物版本号不变。
pkg_format="${PKG_FORMAT:-apk}"
case "${pkg_format}" in
	apk) sdk_ver='snapshots'; ext='apk' ;;
	ipk) sdk_ver='23.05.5';   ext='ipk' ;;
	*) echo "不支持的 PKG_FORMAT=${pkg_format}（只支持 apk / ipk）" >&2; exit 2 ;;
esac

case "${sdk_ver}" in
	snapshots) base_url="https://downloads.openwrt.org/snapshots/targets/mediatek/filogic" ;;
	*)         base_url="https://downloads.openwrt.org/releases/${sdk_ver}/targets/mediatek/filogic" ;;
esac

mkdir -p "${work_dir}" "${output_dir}"
find "${output_dir}" -mindepth 1 -maxdepth 1 -delete
cd "${work_dir}"
curl -fsSLO "${base_url}/sha256sums"
archive="$(awk '/openwrt-sdk-.*Linux-x86_64\.tar\.(xz|zst)$/ { print $2; exit }' sha256sums | sed 's/^\*//')"
test -n "${archive}"
curl -fL --retry 5 "${base_url}/${archive}" -o "${archive}"
grep "[ *]${archive}$" sha256sums | sha256sum -c -
# 两代SDK 的压缩格式不同：23.05 多为 .tar.xz，snapshot 为 .tar.zst。
# tar 的 --zstd 不是所有 runner 都稳定支持，按后缀选解压器。
case "${archive}" in
	*.tar.zst) tar --zstd -xf "${archive}" ;;
	*.tar.xz)  tar -xJf "${archive}" ;;
	*) echo "未知的 SDK 压缩格式：${archive}" >&2; exit 2 ;;
esac
sdk_dir="$(find "${work_dir}" -maxdepth 1 -type d -name 'openwrt-sdk-*' | head -n 1)"
test -n "${sdk_dir}"

cd "${sdk_dir}"
./scripts/feeds update -a
./scripts/feeds install luci-base

perl -0pi -e 's/(config ALL\n\s+bool "Select all userspace packages by default"\n\s+default )y/${1}n/' Config.in
perl -0pi -e 's/(config TARGET_MULTI_PROFILE\n\s+bool\n\s+default )y/${1}n/; s/(config TARGET_ALL_PROFILES\n\s+bool\n\s+default )y/${1}n/; s/(config TARGET_DEVICE_mediatek_filogic_DEVICE_[^\n]+\n\s+bool\n\s+default )y/${1}n/g' Config-build.in
sed -i 's/^[[:space:]]*default m$/\tdefault n/' Config-build.in

mkdir -p package/h5000m-custom
rsync -a --exclude '.git/' --exclude '.github/' --exclude 'scripts/' --exclude 'dist-release/' "${repo_dir}/" package/h5000m-custom/luci-app-h5000m-netmode/

# 上面已按 PKG_FORMAT 定好sdk_ver 与 ext；这里只负责「选中这个包」。
# 不再往 .config 写 USE_APK —— 格式已由 SDK 版本决定（见文件头说明）。
{
	echo 'CONFIG_TARGET_mediatek=y'
	echo 'CONFIG_TARGET_mediatek_filogic=y'
	echo '# CONFIG_ALL is not set'
	echo '# CONFIG_ALL_KMODS is not set'
	echo '# CONFIG_ALL_NONSHARED is not set'
	echo 'CONFIG_PACKAGE_luci-app-h5000m-netmode=m'
	echo 'CONFIG_LUCI_LANG_zh_Hans=y'
} > .config
make defconfig

make package/h5000m-custom/luci-app-h5000m-netmode/compile -j"$(nproc)" V=s

# ★ 必须钉住扩展名：以前这里只数「apk 或 ipk 至少 2 个」，于是格式没生效时
# 拿到的仍是另一种扩展名，而校验照样通过 —— 需求(ipk)与产物(apk)对不上，
# 却报绿灯。现在按请求的格式精确匹配，对不上就失败。
found="$(find bin -type f \( -name "luci-app-h5000m-netmode-*.*${ext}" \
	-o -name "luci-i18n-h5000m-netmode-zh-cn-*.*${ext}" \) | wc -l)"
if [ "${found}" -lt 2 ]; then
	echo "错误：请求格式 ${ext}，但 bin 下只找到 ${found} 个 .${ext} 包" >&2
	find bin -type f \( -name '*h5000m-netmode*' \) | sed 's/^/  实际产物: /' >&2
	exit 1
fi

find bin -type f \( -name "luci-app-h5000m-netmode-*.${ext}" \
	-o -name "luci-i18n-h5000m-netmode-zh-cn-*.${ext}" \) -exec cp -f {} "${output_dir}/" \;
test "$(find "${output_dir}" -type f -name "*.*${ext}" | wc -l)" -ge 2
cp public-key.pem "${output_dir}/openwrt-sdk-build.pem"
(cd "${output_dir}" && find . -maxdepth 1 -type f \( -name "*.*${ext}" -o -name 'openwrt-sdk-build.pem' \) -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS)
