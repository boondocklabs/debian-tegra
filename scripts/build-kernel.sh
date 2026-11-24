#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

source_url=https://deb.debian.org/debian-security/pool/updates/main/l/linux/linux-source-6.12_6.12.118-1_all.deb
source_sha256=b75bb2e78a5c7762254e2af7685085c788a67eb342cb4092ad2a05eaf9fc33b7
source_deb=cache/linux-source-6.12_6.12.118-1_all.deb
kernel_abi=6.12.118-tegra-tx1
package_version=6.12.118-1+tegra1

if [[ ${1:-} == --container ]]; then
  mkdir -p /build/source-package /build/source /build/obj /project/out
  dpkg-deb -x "/project/$source_deb" /build/source-package
  tar -xJf /build/source-package/usr/src/linux-source-6.12.tar.xz \
    -C /build/source --strip-components=1
  patch -d /build/source -p1 < \
    /project/kernel/patches/0001-tegra210-gpu-dma-domain.patch
  cp /project/kernel/tx1-arm64.config /build/obj/.config
  /build/source/scripts/config --file /build/obj/.config \
    --disable MODULE_SIG --disable DEBUG_INFO_BTF \
    --disable DEBUG_INFO_BTF_MODULES
  export SOURCE_DATE_EPOCH=1790812800
  export KBUILD_BUILD_TIMESTAMP='2026-10-01 00:00:00 UTC'
  export KBUILD_BUILD_USER=debian-tegra KBUILD_BUILD_HOST=builder
  export KDEB_CHANGELOG_DIST=trixie
  make -C /build/source O=/build/obj LOCALVERSION=-tegra-tx1 olddefconfig
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

docker build --platform linux/arm64 -f Containerfile -t debian-tegra-kernel-builder .
# The Linux source has names that differ only by case, so its build tree lives
# in Docker's case-sensitive volume even when this repository is on macOS.
docker run --rm --platform linux/arm64 \
  --mount "type=bind,source=$(pwd),target=/project" \
  --mount type=volume,target=/build \
  debian-tegra-kernel-builder bash /project/scripts/build-kernel.sh --container
