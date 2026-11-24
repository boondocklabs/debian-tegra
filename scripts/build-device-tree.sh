#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source modules/sources.env

if [[ ${1:-} != --container ]]; then
  test -f "out/linux-image-${DEBIAN_KERNEL_ABI}_${DEBIAN_KERNEL_VERSION}_arm64.deb"
  docker build --platform linux/arm64 -f Containerfile -t debian-tegra-kernel-builder .
  docker run --rm --platform linux/arm64 \
    --mount "type=bind,source=$(pwd),target=/project" \
    debian-tegra-kernel-builder bash /project/scripts/build-device-tree.sh --container
  exit
fi

export SOURCE_DATE_EPOCH=1790812800
name=debian-tegra-tx1-device-tree
stage=/project/out/$name-stage
rm -rf "$stage" /tmp/tx1-kernel-package
mkdir -p "$stage/DEBIAN" \
  "$stage/usr/lib/linux-image-$DEBIAN_KERNEL_ABI/nvidia" \
  "$stage/usr/share/doc/$name" /tmp/tx1-kernel-package
dpkg-deb -x "/project/out/linux-image-${DEBIAN_KERNEL_ABI}_${DEBIAN_KERNEL_VERSION}_arm64.deb" \
  /tmp/tx1-kernel-package
source_dtb=/tmp/tx1-kernel-package/usr/lib/linux-image-$DEBIAN_KERNEL_ABI/nvidia/tegra210-p2371-2180.dtb
test -f "$source_dtb"
dest=$stage/usr/lib/linux-image-$DEBIAN_KERNEL_ABI/nvidia
cp "$source_dtb" "$dest/tegra210-p2371-2180-nvgpu.dtb"
fdtput -t s "$dest/tegra210-p2371-2180-nvgpu.dtb" \
  /gpu@57000000 status okay
dtc -@ -I dts -O dtb -o "$dest/tegra210-p2371-2180-fan.dtbo" \
  /project/device-tree/tx1-fan.dtso
fdtoverlay -i "$dest/tegra210-p2371-2180-nvgpu.dtb" \
  -o "$dest/tegra210-p2371-2180-nvgpu-fan.dtb" \
  "$dest/tegra210-p2371-2180-fan.dtbo"
test "$(fdtget -t x "$dest/tegra210-p2371-2180-nvgpu-fan.dtb" \
  /pwm-fan cooling-levels)" = '0 50 78 a0 ff'
dtc -@ -I dts -O dtb -o "$dest/tegra210-p2371-2180-ov5693.dtbo" \
  /project/device-tree/tx1-ov5693.dtso
fdtoverlay -i "$dest/tegra210-p2371-2180-nvgpu-fan.dtb" \
  -o "$dest/tegra210-p2371-2180-nvgpu-fan-ov5693.dtb" \
  "$dest/tegra210-p2371-2180-ov5693.dtbo"
test "$(fdtget -t s "$dest/tegra210-p2371-2180-nvgpu-fan-ov5693.dtb" \
  /host1x@50000000/i2c@546c0000/camera@36 compatible)" = ovti,ov5693
dtc -@ -I dts -O dtb -o "$dest/tegra210-p2371-2180-emc.dtbo" \
  /project/device-tree/tx1-emc.dtso
fdtoverlay -i "$dest/tegra210-p2371-2180-nvgpu-fan-ov5693.dtb" \
  -o "$dest/tegra210-p2371-2180-nvgpu-fan-ov5693-emc.dtb" \
  "$dest/tegra210-p2371-2180-emc.dtbo"
test "$(fdtget -t x "$dest/tegra210-p2371-2180-nvgpu-fan-ov5693-emc.dtb" \
  /reserved-memory/cboot-fdt@83100000 reg)" = '0 83100000 0 100000'
dtc -@ -I dts -O dtb -o "$dest/tegra210-p2371-2180-emc-1600.dtbo" \
  /project/device-tree/tx1-emc-1600.dtso
low_emc_dtb="$dest/tegra210-p2371-2180-nvgpu-fan-ov5693-emc.dtb"
high_emc_dtb="$dest/tegra210-p2371-2180-nvgpu-fan-ov5693-emc-1600.dtb"
fdtoverlay -i "$low_emc_dtb" -o "$high_emc_dtb" \
  "$dest/tegra210-p2371-2180-emc-1600.dtbo"
for rate in 408000000 665600000 800000000 1065600000 1331200000 1600000000; do
  test "$(fdtget -t u "$high_emc_dtb" "/opp-table-emc/opp-$rate" opp-hz)" = "0 $rate"
done
fdtget "$high_emc_dtb" /external-memory-controller@7001b000 nvidia,enable-emc-1600 >/dev/null
if fdtget "$low_emc_dtb" /external-memory-controller@7001b000 nvidia,enable-emc-1600 >/dev/null 2>&1; then
  echo 'The base EMC device tree unexpectedly enables 1600 MHz' >&2
  exit 1
fi

units="$stage/usr/lib/systemd/system"
install -d "$stage/usr/libexec" "$units/multi-user.target.wants"
install -m 755 /project/device-tree/boot/debian-tegra-emc-watchdog "$stage/usr/libexec/"
install -m 644 /project/device-tree/boot/*.service "$units/"
ln -s ../debian-tegra-emc-actmon.service "$units/multi-user.target.wants/debian-tegra-emc-actmon.service"

install -d "$stage/usr/lib/udev/rules.d"
cat > "$stage/usr/lib/udev/rules.d/70-debian-tegra-host1x-fence.rules" <<'RULE'
SUBSYSTEM=="misc", KERNEL=="host1x-fence", GROUP="video", MODE="0660"
RULE
cat > "$stage/DEBIAN/control" <<EOF
Package: $name
Version: $DEBIAN_KERNEL_VERSION
Architecture: arm64
Maintainer: debian-tegra <maintainers@example.invalid>
Depends: linux-image-$DEBIAN_KERNEL_ABI (= $DEBIAN_KERNEL_VERSION), python3, kmod, systemd, procps
Section: kernel
Priority: optional
Description: TX1 GPU, fan, and OV5693 device trees for Debian 13
 GPU-enabled P2371-2180 tree, P2597 fan, and optional OV5693 CSI and EMC overlays.
EOF
cat > "$stage/usr/share/doc/$name/README" <<EOF
The GPU-enabled and fan-enabled DTBs are installed under
/usr/lib/linux-image-$DEBIAN_KERNEL_ABI/nvidia/.
Select one from the bootloader configuration for a TX1 P2371-2180 module
on the P2597 carrier. The EMC variant requires RAM code 0 and the NVIDIA
CBoot-trained FDT handoff at 0x83100000. The EMC-1600 variant uses the
boot arguments documented in the project README to start ACTMON after the
hardware watchdog is armed. This package does not modify the boot menu.
EOF
dpkg-deb --build --root-owner-group "$stage" \
  "/project/out/${name}_${DEBIAN_KERNEL_VERSION}_arm64.deb"
(cd /project/out && sha256sum *.deb > SHA256SUMS)
