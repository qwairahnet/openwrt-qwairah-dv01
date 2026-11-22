#!/usr/bin/env bash
set -e
ROOT_DIR="$(pwd)"

rm -rf openwrt
git clone --branch openwrt-23.05 --depth 1 https://github.com/openwrt/openwrt.git openwrt
cd openwrt

mkdir -p package/kernel/mac80211/patches/subsys
sed -i 's/20)/40)/g' package/firmware/wireless-regdb/Makefile 2>/dev/null || true

./scripts/feeds update -a
./scripts/feeds install -a

find feeds/luci package -type f \( -name "*.htm" -o -name "*.ut" -o -name "*.js" -o -name "*.lua" -o -name "*.po" \) \
  -exec sed -i 's|AL-MALAKI|QWAIRAH قويره|gi; s|OpenWrt 23.05|QWAIRAH قويره OpenWrt 23.05|g; s|https://github.com/openwrt/luci|#|g; s|Powered by LuCI.*|QWAIRAH قويره|g' {} + 2>/dev/null || true

if ! grep -q "define Device/davolink_dv01-901h" target/linux/ipq40xx/image/generic.mk; then
    BASE_DTS=$(ls target/linux/ipq40xx/files/arch/arm/boot/dts/qcom-ipq4019-*.dts 2>/dev/null | head -n 1)
    if [ -n "$BASE_DTS" ]; then
        cp "$BASE_DTS" target/linux/ipq40xx/files/arch/arm/boot/dts/qcom-ipq4019-dv01-901h.dts
        python3 -c '
p = "target/linux/ipq40xx/files/arch/arm/boot/dts/qcom-ipq4019-dv01-901h.dts"
s = open(p).read()
s = s.replace("compatible =", "compatible = \"davolink,dv01-901h\",", 1)
open(p, "w").write(s)
' || true
    fi

    python3 - << 'PYEOF'
mk_path = "target/linux/ipq40xx/image/generic.mk"
with open(mk_path, "r") as f:
    content = f.read()

block = """
define Device/davolink_dv01-901h
  $(call Device/FitImage)
  DEVICE_VENDOR := DAVOLINK
  DEVICE_MODEL := DV01-901H
  SOC := qcom-ipq4019
  DEVICE_DTS := qcom-ipq4019-dv01-901h
  SUPPORTED_DEVICES += davolink,dv01-901h
  DEVICE_PACKAGES := ath10k-firmware-qca4019-ct kmod-ath10k-ct
  IMAGES := sysupgrade.bin
  IMAGE/sysupgrade.bin := append-kernel | pad-to 128k | append-rootfs | pad-rootfs | append-metadata
endef
TARGET_DEVICES += davolink_dv01-901h
"""

with open(mk_path, "w") as f:
    f.write(content + block)
PYEOF
fi

cat << 'CONF' > .config
CONFIG_TARGET_ipq40xx=y
CONFIG_TARGET_ipq40xx_generic=y
CONFIG_TARGET_ipq40xx_generic_DEVICE_davolink_dv01-901h=y
CONFIG_TARGET_MULTI_PROFILE=n
CONFIG_PACKAGE_kmod-ath10k-ct=y
CONFIG_PACKAGE_ath10k-firmware-qca4019-ct=y
CONFIG_PACKAGE_kmod-mt76x2=y
CONFIG_PACKAGE_luci=y
CONFIG_PACKAGE_luci-base=y
CONFIG_PACKAGE_luci-mod-admin-full=y
CONFIG_PACKAGE_luci-i18n-base-ar=y
CONFIG_PACKAGE_luci-i18n-base-en=y
CONFIG_PACKAGE_luci-i18n-opkg-ar=y
CONFIG_PACKAGE_luci-theme-bootstrap=y
CONFIG_PACKAGE_luci-app-sqm=y
CONFIG_PACKAGE_luci-i18n-sqm-ar=y
CONFIG_PACKAGE_luci-app-nlbwmon=y
CONFIG_PACKAGE_luci-app-commands=y
CONFIG_PACKAGE_luci-app-ttyd=y
CONFIG_PACKAGE_luci-app-watchcat=y
CONFIG_PACKAGE_luci-app-lldpd=y
CONFIG_PACKAGE_lldpd=y
CONFIG_PACKAGE_nodogsplash=y
CONFIG_PACKAGE_vnstat2=y
CONFIG_PACKAGE_wpad-mesh-openssl=y
CONFIG_PACKAGE_kmod-batman-adv=y
CONFIG_PACKAGE_openssh-sftp-server=y
CONFIG_PACKAGE_dropbear=y
CONFIG_PACKAGE_curl=y
CONFIG_PACKAGE_jq=y
CONFIG_PACKAGE_ca-bundle=y
CONFIG_PACKAGE_iw=y
CONFIG_PACKAGE_iwinfo=y
CONFIG_PACKAGE_ethtool=y
CONFIG_PACKAGE_ip-full=y
CONFIG_PACKAGE_iptables-mod-extra=y
CONF

make defconfig
make toolchain/install -j"$(nproc)"

TOOLCHAIN_GCC=$(find staging_dir/toolchain-* -name "arm-openwrt-linux*-gcc" 2>/dev/null | head -n 1)
mkdir -p "$ROOT_DIR/files/usr/bin"
if [ -n "$TOOLCHAIN_GCC" ]; then
    "$TOOLCHAIN_GCC" -O2 -s "$ROOT_DIR/src/qwairah_mndp.c" -o "$ROOT_DIR/files/usr/bin/qwairah_mndp"
    chmod +x "$ROOT_DIR/files/usr/bin/qwairah_mndp"
fi

cp -rf "$ROOT_DIR/files/." files/

make -j"$(nproc)" || { make -j1 target/linux/install V=sc; exit 1; }

mkdir -p "$ROOT_DIR/artifacts_out"
cp -f bin/targets/ipq40xx/generic/*dv01-901h*initramfs* bin/targets/ipq40xx/generic/*dv01-901h*sysupgrade.bin bin/targets/ipq40xx/generic/*dv01-901h*kernel.bin "$ROOT_DIR/artifacts_out/" 2>/dev/null || true
ls -lh "$ROOT_DIR/artifacts_out/"
