#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work_dir="${RUNNER_TEMP:-/tmp}/h5000m-netmode-sdk"
output_dir="${repo_dir}/dist-release"
base_url="https://downloads.openwrt.org/snapshots/targets/mediatek/filogic"

mkdir -p "${work_dir}" "${output_dir}"
find "${output_dir}" -mindepth 1 -maxdepth 1 -delete
cd "${work_dir}"
curl -fsSLO "${base_url}/sha256sums"
archive="$(awk '/openwrt-sdk-.*Linux-x86_64\.tar\.zst$/ { print $2; exit }' sha256sums | sed 's/^\*//')"
test -n "${archive}"
curl -fL --retry 5 "${base_url}/${archive}" -o "${archive}"
grep "[ *]${archive}$" sha256sums | sha256sum -c -
tar --zstd -xf "${archive}"
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

# 包格式：默认 apk（OpenWrt 24.10-SNAPSHOT 起SDK 默认 CONFIG_USE_APK=y），
# PKG_FORMAT=ipk 时产出 opkg 能装的 .ipk。
#
# 为什么要可切：24.10-SNAPSHOT 的 SDK 默认 apk，但**大量在跑的固件仍是 opkg**
# （实测 MWRT r33382：apk 命令不存在、只有 /bin/opkg，且 opkg install 直接拒收
# .apk —— "Unknown package"）。这类设备上 apk 包完全装不上。
# 格式开关在 package/Makefile：PACKAGE_EXT:=$(if $(CONFIG_USE_APK),apk,ipk)。
# 方向对着 config/Config-build.in 第 71 行的定义核过：
#     config USE_APK
#         imply PACKAGE_apk-mbedtls
#         bool "Use APK instead of OPKG to build distribution"
#         default y
# 即 USE_APK=y 表示「用 apk」，要出 ipk 必须是 not set。
# ★ 这里曾把两个分支写反（ipk 分支写 CONFIG_USE_APK=y），而当时的复核
# 也按同一错误方向写，于是自洽地判成「通过」，直到最后按扩展名核对
# 才暴露：请求 ipk 却产出 apk，白跑一轮 CI。所以 expect 与 use_apk 必须
# 成对改，且方向照 Kconfig 定义核，不靠记忆。
pkg_format="${PKG_FORMAT:-apk}"
case "${pkg_format}" in
	apk) use_apk='CONFIG_USE_APK=y';     expect='^CONFIG_USE_APK=y$';        ext='apk' ;;
	ipk) use_apk='# CONFIG_USE_APK is not set'; expect='^# CONFIG_USE_APK is not set$'; ext='ipk' ;;
	*) echo "不支持的 PKG_FORMAT=${pkg_format}（只支持 apk / ipk）" >&2; exit 2 ;;
esac

{
	echo 'CONFIG_TARGET_mediatek=y'
	echo 'CONFIG_TARGET_mediatek_filogic=y'
	echo '# CONFIG_ALL is not set'
	echo '# CONFIG_ALL_KMODS is not set'
	echo '# CONFIG_ALL_NONSHARED is not set'
	echo 'CONFIG_PACKAGE_luci-app-h5000m-netmode=m'
	echo 'CONFIG_LUCI_LANG_zh_Hans=y'
	echo "${use_apk}"
} > .config
make defconfig

# defconfig 可能被 SDK 默认值把USE_APK 又拉回来，必须复核并强改一次。
# 判据：grep 出来的实际值必须与请求的格式一致，不一致就当场失败 ——
# 静默产出另一种格式的包，等于白跑一轮 CI。
grep -qE "${expect}" .config || {
	echo "${use_apk}" >> .config
	make defconfig
}
grep -qE "${expect}" .config || {
	echo "错误：无法把 CONFIG_USE_APK 设成能产出 .${ext} 的值（期望 ${expect}）" >&2
	grep -nE 'USE_APK' .config | sed 's/^/  当前 .config: /' >&2 || true
	exit 1
}

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
