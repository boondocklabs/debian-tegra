#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

source_url=https://deb.debian.org/debian-security/pool/updates/main/l/linux/linux-source-6.12_6.12.118-1_all.deb
source_sha256=b75bb2e78a5c7762254e2af7685085c788a67eb342cb4092ad2a05eaf9fc33b7
source_deb=cache/linux-source-6.12_6.12.118-1_all.deb
kernel_abi=6.12.118-tegra-tx1
package_version=6.12.118-1+tegra13
imx477_commit=8f5f2e15840330091c7116b2ef9454108d4bc423
imx477_source=cache/imx477-$imx477_commit.c
imx477_url=https://raw.githubusercontent.com/raspberrypi/linux/$imx477_commit/drivers/media/i2c/imx477.c
imx477_sha256=1e767f1c056791d4dd1040fba26dc757803e2a6a16d86f0dc3e3480c6c39fcaa

if [[ ${1:-} == --container ]]; then
  mkdir -p /build/source-package /build/source /build/obj /project/out
  dpkg-deb -x "/project/$source_deb" /build/source-package
  tar -xJf /build/source-package/usr/src/linux-source-6.12.tar.xz \
    -C /build/source --strip-components=1
  install -m 644 "/project/$imx477_source" /build/source/drivers/media/i2c/imx477.c
  for kernel_patch in /project/kernel/patches/*.patch; do
    patch -d /build/source -p1 < "$kernel_patch"
  done
  cp /project/kernel/tx1-arm64.config /build/obj/.config
  /build/source/scripts/config --file /build/obj/.config \
    --disable MODULE_SIG --disable DEBUG_INFO_DWARF_TOOLCHAIN_DEFAULT \
    --enable DEBUG_INFO_NONE --disable DEBUG_INFO_BTF \
    --disable DEBUG_INFO_BTF_MODULES
  printf 'int x;\n' | gcc -x c -c -mtune=cortex-a57 -o /tmp/tx1-a57-tune.o -
  rm -f /tmp/tx1-a57-tune.o
  export KCFLAGS=-mtune=cortex-a57
  export SOURCE_DATE_EPOCH=1790812800
  export KBUILD_BUILD_TIMESTAMP='2026-10-01 00:00:00 UTC'
  export KBUILD_BUILD_USER=debian-tegra KBUILD_BUILD_HOST=builder
  export KDEB_CHANGELOG_DIST=trixie
  make -C /build/source O=/build/obj LOCALVERSION=-tegra-tx1 olddefconfig
  grep -qx 'CONFIG_DEBUG_INFO_NONE=y' /build/obj/.config
  ! grep -qx 'CONFIG_DEBUG_INFO=y' /build/obj/.config
  for required in CONFIG_KVM=y CONFIG_TEGRA_HOST1X=y CONFIG_TEGRA210_HOST1X_FENCE=y \
    CONFIG_HWMON=y CONFIG_TEGRA_SOCTHERM=y CONFIG_SENSORS_INA3221=m \
    CONFIG_DRM_TEGRA=y \
    CONFIG_DRM_FBDEV_EMULATION=y CONFIG_FRAMEBUFFER_CONSOLE=y \
    CONFIG_I2C_TEGRA=y CONFIG_REGULATOR_MAX77620=y \
    CONFIG_PINCTRL_TEGRA210=y CONFIG_GPIO_CDEV=y CONFIG_I2C_CHARDEV=m \
    CONFIG_SPI_TEGRA114=m CONFIG_SPI_SPIDEV=y CONFIG_SERIAL_TEGRA=y CONFIG_PWM_TEGRA=m \
    CONFIG_MULTIPLEXER=m CONFIG_MUX_GPIO=m CONFIG_I2C_MUX_GPMUX=m CONFIG_SPI_MUX=m \
    CONFIG_TEGRA210_ADMA=y CONFIG_SND_SOC_TEGRA210_ADMAIF=m CONFIG_SND_SOC_TEGRA210_AHUB=m \
    CONFIG_SND_SOC_TEGRA210_I2S=m CONFIG_SND_SOC_TEGRA_AUDIO_GRAPH_CARD=m \
    CONFIG_PCI_TEGRA=y CONFIG_USB_XHCI_TEGRA=m \
    CONFIG_USB_STORAGE=m CONFIG_AHCI_TEGRA=m CONFIG_BLK_DEV_NVME=m \
    CONFIG_BRCMFMAC=m CONFIG_VIDEO_TEGRA=m \
    CONFIG_VIDEO_OV5693=m CONFIG_VIDEO_IMX219=m CONFIG_VIDEO_IMX477=m CONFIG_I2C_MUX_GPIO=m \
    CONFIG_USB_VIDEO_CLASS=m CONFIG_TEGRA210_EMC=y \
    CONFIG_ARM_TEGRA_DEVFREQ=m CONFIG_MAX77620_WATCHDOG=y; do
    grep -qx "$required" /build/obj/.config || {
      echo "Missing required TX1 config: $required" >&2; exit 1;
    }
  done
  grep -qx '# CONFIG_DRM_NOUVEAU is not set' /build/obj/.config
  test "$(make -s -C /build/source O=/build/obj \
    LOCALVERSION=-tegra-tx1 kernelrelease)" = "$kernel_abi"
  make -C /build/source O=/build/obj -j"$(nproc)" \
    LOCALVERSION=-tegra-tx1 KDEB_PKGVERSION="$package_version" bindeb-pkg
  cp /build/linux-*"$kernel_abi"*"$package_version"*.deb /project/out/
  (cd /project/out && sha256sum *.deb > SHA256SUMS)
  exit
fi

mkdir -p cache
if [[ ! -f $source_deb ]]; then
  curl --fail --location --retry 3 --output "$source_deb" "$source_url"
fi
actual=$(openssl dgst -sha256 "$source_deb" | awk '{print $NF}')
if [[ $actual != "$source_sha256" ]]; then
  echo "Kernel source SHA-256 mismatch: $source_deb" >&2
  exit 1
fi

if [[ ! -s $imx477_source ]]; then
  curl --fail --location --retry 3 --output "$imx477_source.partial" "$imx477_url"
  mv -f "$imx477_source.partial" "$imx477_source"
fi
actual=$(openssl dgst -sha256 "$imx477_source" | awk '{print $NF}')
if [[ $actual != "$imx477_sha256" ]]; then
  echo "IMX477 source SHA-256 mismatch: $imx477_source" >&2
  exit 1
fi

docker build --platform linux/arm64 -f Containerfile -t debian-tegra-kernel-builder .
# The Linux source has names that differ only by case, so its build tree lives
# in Docker's case-sensitive volume even when this repository is on macOS.
docker run --rm --platform linux/arm64 \
  --mount "type=bind,source=$(pwd),target=/project" \
  --mount type=volume,target=/build \
  debian-tegra-kernel-builder bash /project/scripts/build-kernel.sh --container
