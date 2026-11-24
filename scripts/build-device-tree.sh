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
  /pwm-fan cooling-levels)" = 'ff af 87 5f 1'
cat > "$stage/DEBIAN/control" <<EOF
Package: $name
Version: $DEBIAN_KERNEL_VERSION
Architecture: arm64
Maintainer: debian-tegra <maintainers@example.invalid>
Depends: linux-image-$DEBIAN_KERNEL_ABI (= $DEBIAN_KERNEL_VERSION)
Section: kernel
Priority: optional
Description: TX1 GPU and fan device trees for Debian 13
 GPU-enabled P2371-2180 device tree and P2597 fan overlay for the pinned kernel.
EOF
cat > "$stage/usr/share/doc/$name/README" <<EOF
The GPU-enabled and fan-enabled DTBs are installed under
/usr/lib/linux-image-$DEBIAN_KERNEL_ABI/nvidia/.
Select one from the bootloader configuration for a TX1 P2371-2180 module
on the P2597 carrier. This package does not modify the boot menu.
EOF
dpkg-deb --build --root-owner-group "$stage" \
  "/project/out/${name}_${DEBIAN_KERNEL_VERSION}_arm64.deb"
(cd /project/out && sha256sum *.deb > SHA256SUMS)
