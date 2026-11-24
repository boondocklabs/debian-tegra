#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source modules/sources.env
module=${1:-all}
if [[ $module == --container ]]; then module=${2:-all}; container=1; fi
case $module in nvmap|nvgpu|all) ;; *) echo "Usage: $0 [nvmap|nvgpu|all]" >&2; exit 2 ;; esac

if [[ ${container:-0} != 1 ]]; then
  mkdir -p cache
  fetch_checkout() {
    local name=$1 repo=$2 commit=$3
    if [[ ! -d cache/$name/.git ]]; then
      if [[ $name == nvmap ]]; then
        git clone --filter=blob:none --sparse "$repo" "cache/$name"
        git -C "cache/$name" sparse-checkout set drivers/video/tegra/nvmap include
      else
        git clone --filter=blob:none "$repo" "cache/$name"
      fi
    fi
    test "$(git -C "cache/$name" remote get-url origin)" = "$repo"
    if ! git -C "cache/$name" cat-file -e "$commit^{commit}" 2>/dev/null; then
      git -C "cache/$name" fetch origin "$commit"
    fi
    git -C "cache/$name" checkout --detach -f "$commit"
    git -C "cache/$name" reset --hard "$commit"
    git -C "cache/$name" clean -fdx
    for patch_file in "$(pwd)"/modules/"$name"/patches/*.patch; do
      git -C "cache/$name" apply --check "$patch_file"
      git -C "cache/$name" apply "$patch_file"
    done
  }
  if [[ $module == nvmap || $module == all ]]; then
    fetch_checkout nvmap "$NVMAP_REPO" "$NVMAP_COMMIT"
    mkdir -p cache/nvmap/include/nvidia
    : > cache/nvmap/include/nvidia/conftest.h
  fi
  if [[ $module == nvgpu || $module == all ]]; then
    fetch_checkout nvgpu "$NVGPU_REPO" "$NVGPU_COMMIT"
  fi
  test -f "out/linux-headers-${DEBIAN_KERNEL_ABI}_${DEBIAN_KERNEL_VERSION}_arm64.deb"
  docker build --platform linux/arm64 -f Containerfile -t debian-tegra-kernel-builder .
  docker run --rm --platform linux/arm64 \
    --mount "type=bind,source=$(pwd),target=/project" \
    debian-tegra-kernel-builder bash /project/scripts/build-modules.sh --container "$module"
  exit
fi

export SOURCE_DATE_EPOCH=1790812800
dpkg -i "/project/out/linux-headers-${DEBIAN_KERNEL_ABI}_${DEBIAN_KERNEL_VERSION}_arm64.deb"
headers=/usr/src/linux-headers-$DEBIAN_KERNEL_ABI
test -d "$headers"

if [[ $module == nvmap || $module == all ]]; then
nvmap_source=/project/cache/nvmap
nvmap_dir=$nvmap_source/drivers/video/tegra/nvmap
make -C "$headers" M="$nvmap_dir" \
  srctree.nvidia-oot="$nvmap_source" \
  NVMAP_CONFIG_PAGE_POOLS=n NVMAP_CONFIG_SCIIPC=n clean
make -C "$headers" -j"$(nproc)" M="$nvmap_dir" \
  srctree.nvidia-oot="$nvmap_source" \
  NVMAP_CONFIG_PAGE_POOLS=n NVMAP_CONFIG_SCIIPC=n \
  KCFLAGS="-I$nvmap_source/include \
    -DNV_GET_USER_PAGES_HAS_ARGS_FLAGS \
    -DNV_FOLIO_ENTIRE_MAPCOUNT_PRESENT \
    -DNV___ASSIGN_STR_HAS_NO_SRC_ARG \
    -DNV_VM_AREA_STRUCT_HAS_CONST_VM_FLAGS \
    -DNV_LINUX_IOSYS_MAP_H_PRESENT \
    -DNV_GET_FILE_RCU_HAS_DOUBLE_PTR_FILE_ARG \
    -DNV_MM_STRUCT_STRUCT_HAS_PERCPU_COUNTER_RSS_STAT \
    -DNV_MODULE_IMPORT_NS_CALLS_STRINGIFY \
    -DNV_PLATFORM_DRIVER_STRUCT_REMOVE_RETURNS_VOID \
    -Wno-error=unused-label -Wno-error=missing-prototypes" modules
fi

if [[ $module == nvgpu || $module == all ]]; then
nvgpu_source=/project/cache/nvgpu
nvgpu_dir=$nvgpu_source/drivers/gpu/nvgpu
make -C "$headers" M="$nvgpu_dir" \
  NVGPU_TX1_PORT=1 CONFIG_NVGPU_IVM_BUILD=n \
  srctree.nvgpu="$nvgpu_source" clean
make -C "$headers" -j"$(nproc)" M="$nvgpu_dir" \
  NVGPU_TX1_PORT=1 CONFIG_NVGPU_IVM_BUILD=n \
  srctree.nvgpu="$nvgpu_source" modules
fi

build_package() {
  local name=$1 version=$2 module=$3 source_path=$4 depends=$5
  local stage=/project/out/$name-stage
  rm -rf "$stage"
  mkdir -p "$stage/DEBIAN" "$stage/usr/lib/modules/$DEBIAN_KERNEL_ABI/updates"
  install -m 644 "$source_path" \
    "$stage/usr/lib/modules/$DEBIAN_KERNEL_ABI/updates/$module.ko"
  aarch64-linux-gnu-strip --strip-debug \
    "$stage/usr/lib/modules/$DEBIAN_KERNEL_ABI/updates/$module.ko"
  cat > "$stage/DEBIAN/control" <<EOF
Package: $name
Version: $version
Architecture: arm64
Maintainer: debian-tegra <maintainers@example.invalid>
Depends: linux-image-$DEBIAN_KERNEL_ABI (= $DEBIAN_KERNEL_VERSION), kmod$depends
Section: kernel
Priority: optional
Description: TX1 $module kernel module for Debian 13
 Built from a pinned NVIDIA source commit with the included patch series.
EOF
  cat > "$stage/DEBIAN/postinst" <<EOF
#!/bin/sh
set -e
case "\$1" in configure|triggered) depmod -a '$DEBIAN_KERNEL_ABI' ;; esac
EOF
  cat > "$stage/DEBIAN/postrm" <<EOF
#!/bin/sh
set -e
case "\$1" in remove|purge) depmod -a '$DEBIAN_KERNEL_ABI' ;; esac
EOF
  chmod 755 "$stage/DEBIAN/postinst" "$stage/DEBIAN/postrm"
  dpkg-deb --build --root-owner-group "$stage" \
    "/project/out/${name}_${version}_arm64.deb"
}

if [[ $module == nvmap || $module == all ]]; then
  build_package "$NVMAP_PACKAGE_NAME" "$NVMAP_PACKAGE_VERSION" nvmap \
    "$nvmap_dir/nvmap.ko" ''
fi
if [[ $module == nvgpu || $module == all ]]; then
  build_package "$NVGPU_PACKAGE_NAME" "$NVGPU_PACKAGE_VERSION" nvgpu \
    "$nvgpu_dir/nvgpu.ko" \
    ", $NVMAP_PACKAGE_NAME (>= $NVMAP_PACKAGE_VERSION)"
fi
(cd /project/out && sha256sum *.deb > SHA256SUMS)
