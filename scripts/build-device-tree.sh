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
kernel_dtbs=/tmp/tx1-kernel-package/usr/lib/linux-image-$DEBIAN_KERNEL_ABI/nvidia
source_dtb=$kernel_dtbs/tegra210-p2371-2180.dtb
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
install -m 644 /project/device-tree/boot/debian-tegra-emc-{actmon,watchdog}.service "$units/"
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
tx1_stage=$stage
name=debian-tegra-nano-device-tree
stage=/project/out/$name-stage
dest=$stage/usr/lib/linux-image-$DEBIAN_KERNEL_ABI/nvidia
rm -rf "$stage"
install -d "$stage/DEBIAN" "$dest" "$stage/usr/lib/udev/rules.d"
source_dtb=$kernel_dtbs/tegra210-p3450-0000.dtb
nano_dtb=$dest/tegra210-p3450-0000-nvgpu.dtb
test "$(fdtget -t s "$source_dtb" / compatible)" = 'nvidia,p3450-0000 nvidia,tegra210'
dtc -@ -I dts -O dtb -o /tmp/nano-hdmi.dtbo /project/device-tree/nano-hdmi.dtso
dtc -@ -I dts -O dtb -o /tmp/nano-power-monitor.dtbo /project/device-tree/nano-power-monitor.dtso
fdtoverlay -i "$source_dtb" -o "$nano_dtb" /tmp/nano-hdmi.dtbo /tmp/nano-power-monitor.dtbo
nano_sensor=/host1x@50000000/i2c@546c0000/power-sensor@40
test "$(fdtget -t s "$nano_dtb" "$nano_sensor" compatible)" = ti,ina3221
test "$(fdtget -t s "$nano_dtb" "$nano_sensor/input@0" label)" = POM_5V_IN
test "$(fdtget -t s "$nano_dtb" "$nano_sensor/input@1" label)" = POM_5V_GPU
test "$(fdtget -t s "$nano_dtb" "$nano_sensor/input@2" label)" = POM_5V_CPU
for channel in 0 1 2; do
  test "$(fdtget -t u "$nano_dtb" "$nano_sensor/input@$channel" shunt-resistor-micro-ohms)" = 5000
done
for property in regulator-boot-on regulator-always-on; do
  fdtget "$nano_dtb" /regulator-vdd-hub-3v3 "$property" >/dev/null
done
fdtput -t s "$nano_dtb" /gpu@57000000 status okay
test "$(fdtget -t s "$nano_dtb" /gpu@57000000 compatible)" = nvidia,gm20b
fdtget -t x "$nano_dtb" /gpu@57000000 vdd-supply >/dev/null
nano_emc_dtb=$dest/tegra210-p3450-0000-nvgpu-emc.dtb
dtc -@ -I dts -O dtb -o /tmp/nano-emc.dtbo /project/device-tree/nano-emc.dtso
fdtoverlay -i "$nano_dtb" -o "$nano_emc_dtb" /tmp/nano-emc.dtbo
test "$(fdtget -t x "$nano_emc_dtb" /reserved-memory/cboot-fdt@83100000 reg)" = '0 83100000 0 100000'
test "$(fdtget -t s "$nano_emc_dtb" /actmon@6000c800 compatible)" = nvidia,tegra210-nano-actmon
for rate in 204000000 1600000000; do
  test "$(fdtget -t u "$nano_emc_dtb" "/opp-table-emc/opp-$rate" opp-hz)" = "0 $rate"
done
nano_camera_dtb=$dest/tegra210-p3450-0000-nvgpu-emc-cam0-imx477.dtb
dtc -@ -Wno-graph_child_address -I dts -O dtb -o /tmp/nano-cam0-imx477.dtbo \
  /project/device-tree/nano-cam0-imx477.dtso
fdtoverlay -i "$nano_emc_dtb" -o "$nano_camera_dtb" /tmp/nano-cam0-imx477.dtbo
test "$(fdtget -t s "$nano_camera_dtb" /i2c-mux-camera/i2c@0/camera@1a compatible)" = sony,imx477
test "$(fdtget -t u "$nano_camera_dtb" /host1x@50000000/vi@54080000/ports/port@0 reg)" = 0
units="$stage/usr/lib/systemd/system"
install -d "$stage/usr/libexec" "$units/multi-user.target.wants"
install -m 755 /project/device-tree/boot/debian-tegra-emc-watchdog \
  "$stage/usr/libexec/debian-tegra-nano-emc-watchdog"
install -m 644 /project/device-tree/boot/debian-tegra-nano-emc-{actmon,watchdog}.service "$units/"
ln -s ../debian-tegra-nano-emc-actmon.service "$units/multi-user.target.wants/debian-tegra-nano-emc-actmon.service"
install -m 644 "$tx1_stage/usr/lib/udev/rules.d/70-debian-tegra-host1x-fence.rules" \
  "$stage/usr/lib/udev/rules.d/70-debian-tegra-nano-host1x-fence.rules"
cat > "$stage/DEBIAN/control" <<EOF
Package: $name
Version: $NANO_DEVICE_TREE_VERSION
Architecture: arm64
Maintainer: debian-tegra <maintainers@example.invalid>
Depends: linux-image-$DEBIAN_KERNEL_ABI (= $DEBIAN_KERNEL_VERSION), $NVGPU_PACKAGE_NAME (>= $NVGPU_PACKAGE_VERSION), python3, kmod, systemd, procps
Section: kernel
Priority: optional
Description: Jetson Nano 4 GB developer kit device tree for Debian 13
 GPU-enabled P3450-0000 tree for the P3448-0000 module and P3449 carrier.
 Includes RAM-code-0 EMC trees, watchdog-guarded ACTMON, and optional IMX477 CAM0.
EOF
dpkg-deb --build --root-owner-group "$stage" \
  "/project/out/${name}_${NANO_DEVICE_TREE_VERSION}_arm64.deb"
(cd /project/out && sha256sum *.deb > SHA256SUMS)
