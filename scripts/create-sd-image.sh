#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

usage() {
  cat <<'EOF'
Usage: scripts/create-sd-image.sh --authorized-keys FILE [options]

Build a Debian 13 Jetson TX1 SD image from the signed debian-tegra APT repo.

Options:
  --authorized-keys FILE  Public SSH key(s) for the debian user (required)
  --wifi-ssid SSID         Wi-Fi network name; prompts for WPA/WPA2 password
  --wifi-password-file FILE  Read password from a file instead of prompting
  --wifi-hidden            Connect to an SSID that does not broadcast
  --root-password          Prompt for a local root password
  --firmware-dir DIR      Use a local TX1 firmware tree instead of downloading
  --no-firmware           Skip firmware and default to the safe boot entry
  --no-cuda               Skip R36.5.1 CUDA driver and CUDA 12.6 toolkit
  --output NAME           Image filename under out/ (default: debian-tegra-tx1-sd.img)
  --size-mib N            Image size in MiB (default: 8192; 2048 with --no-cuda)
  --hostname NAME         Device hostname (default: jetson-tx1)
  --force                 Replace an existing output image
EOF
}

if [[ ${1:-} != --container ]]; then
  authorized_keys= firmware_dir= wifi_ssid= wifi_password_file=
  output=debian-tegra-tx1-sd.img size_mib=8192 hostname=jetson-tx1
  force=0 no_firmware=0 no_cuda=0 wifi_hidden=0 root_password_enabled=0
  wifi_temp_file= root_temp_file=
  cleanup_secret_files() {
    if [[ -n $wifi_temp_file ]]; then rm -f "$wifi_temp_file"; fi
    if [[ -n $root_temp_file ]]; then rm -f "$root_temp_file"; fi
  }
  prompt_secret_to_file() {
    local prompt=$1 destination=$2 confirm=${3:-0} secret confirmation
    if ! (: > /dev/tty) 2>/dev/null; then
      echo 'A terminal is required for the password prompt' >&2
      return 2
    fi
    printf '%s' "$prompt" > /dev/tty
    if ! IFS= read -r -s secret < /dev/tty; then
      echo 'Could not read password from terminal' >&2
      return 2
    fi
    printf '\n' > /dev/tty
    if [[ $confirm == 1 ]]; then
      printf 'Confirm root password: ' > /dev/tty
      if ! IFS= read -r -s confirmation < /dev/tty; then
        echo 'Could not read password confirmation from terminal' >&2
        return 2
      fi
      printf '\n' > /dev/tty
      [[ $secret == "$confirmation" ]] || {
        echo 'Root passwords did not match' >&2; return 2;
      }
    fi
    printf '%s' "$secret" > "$destination"
  }
  while (($#)); do
    case $1 in
      --authorized-keys) authorized_keys=${2:?missing key file}; shift 2 ;;
      --wifi-ssid) wifi_ssid=${2:?missing Wi-Fi SSID}; shift 2 ;;
      --wifi-password-file) wifi_password_file=${2:?missing Wi-Fi password file}; shift 2 ;;
      --wifi-hidden) wifi_hidden=1; shift ;;
      --root-password) root_password_enabled=1; shift ;;
      --firmware-dir) firmware_dir=${2:?missing firmware directory}; shift 2 ;;
      --no-firmware) no_firmware=1; shift ;;
      --no-cuda) no_cuda=1; shift ;;
      --output) output=${2:?missing image name}; shift 2 ;;
      --size-mib) size_mib=${2:?missing size}; shift 2 ;;
      --hostname) hostname=${2:?missing hostname}; shift 2 ;;
      --force) force=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) usage >&2; exit 2 ;;
    esac
  done
  [[ -s $authorized_keys ]] || { echo 'A nonempty --authorized-keys file is required' >&2; exit 2; }
  [[ $output =~ ^[A-Za-z0-9][A-Za-z0-9._-]*\.img$ ]] || {
    echo '--output must be a simple .img filename' >&2; exit 2;
  }
  min_size_mib=2048
  [[ $no_cuda == 0 ]] && min_size_mib=8192
  [[ $size_mib =~ ^[0-9]+$ ]] && ((size_mib >= min_size_mib)) || {
    echo "--size-mib must be at least $min_size_mib" >&2; exit 2;
  }
  [[ $hostname =~ ^[a-zA-Z0-9][a-zA-Z0-9-]*$ ]] || {
    echo 'Invalid hostname' >&2; exit 2;
  }
  if [[ -n $firmware_dir && $no_firmware == 1 ]]; then
    echo '--firmware-dir and --no-firmware cannot be combined' >&2; exit 2
  fi
  if [[ -n $firmware_dir ]]; then
    [[ -s $firmware_dir/tegra21x/pmu_sig.bin ]] || {
      echo '--firmware-dir must contain tegra21x/pmu_sig.bin' >&2; exit 2;
    }
  fi
  mkdir -p out
  if [[ -e out/$output && $force != 1 ]]; then
    echo "out/$output exists; use --force to replace it" >&2
    exit 2
  fi
  trap cleanup_secret_files EXIT
  if [[ -n $wifi_ssid || -n $wifi_password_file || $wifi_hidden == 1 ]]; then
    [[ -n $wifi_ssid ]] || {
      echo '--wifi-password-file and --wifi-hidden require --wifi-ssid' >&2; exit 2;
    }
    [[ $no_firmware == 0 ]] || {
      echo 'Wi-Fi options cannot be combined with --no-firmware' >&2; exit 2;
    }
    LC_ALL=C
    [[ ${#wifi_ssid} -le 32 && $wifi_ssid != ' '* && $wifi_ssid != *' ' ]] || {
      echo 'Wi-Fi SSID must be at most 32 bytes with no edge spaces' >&2; exit 2;
    }
    if printf %s "$wifi_ssid" | LC_ALL=C grep -q '[[:cntrl:]]'; then
      echo 'Wi-Fi SSID cannot contain control characters' >&2; exit 2
    fi
    if [[ -z $wifi_password_file ]]; then
      wifi_temp_file=$(mktemp "${TMPDIR:-/tmp}/debian-tegra-wifi.XXXXXXXX")
      chmod 600 "$wifi_temp_file"
      prompt_secret_to_file "Wi-Fi password for $wifi_ssid: " "$wifi_temp_file"
      wifi_password_file=$wifi_temp_file
    fi
    [[ -s $wifi_password_file ]] || {
      echo 'Wi-Fi password file is empty or missing' >&2; exit 2;
    }
    wifi_password_file=$(realpath "$wifi_password_file")
  fi
  if [[ $root_password_enabled == 1 ]]; then
    root_temp_file=$(mktemp "${TMPDIR:-/tmp}/debian-tegra-root.XXXXXXXX")
    chmod 600 "$root_temp_file"
    prompt_secret_to_file 'Root password: ' "$root_temp_file" 1
    [[ -s $root_temp_file ]] || {
      echo 'Root password cannot be empty' >&2; exit 2;
    }
  fi
  authorized_keys=$(realpath "$authorized_keys")
  mounts=(--mount "type=bind,source=$(pwd),target=/project"
          --mount "type=bind,source=$authorized_keys,target=/input/authorized_keys,readonly"
          --mount type=volume,target=/build)
  if [[ -n $wifi_ssid ]]; then
    mounts+=(--mount "type=bind,source=$wifi_password_file,target=/input/wifi_password,readonly")
  fi
  if [[ $root_password_enabled == 1 ]]; then
    mounts+=(--mount "type=bind,source=$root_temp_file,target=/input/root_password,readonly")
  fi
  if [[ -n $firmware_dir ]]; then
    firmware_dir=$(realpath "$firmware_dir")
    mounts+=(--mount "type=bind,source=$firmware_dir,target=/input/firmware,readonly")
  elif [[ $no_firmware == 0 ]]; then
    bsp=cache/jetson-210_linux_r32.7.6_aarch64.tbz2
    bsp_url=https://developer.nvidia.com/downloads/embedded/l4t/r32_release_v7.6/t210/jetson-210_linux_r32.7.6_aarch64.tbz2
    bsp_sha256=865717eed7076babd3c193fc39bc7df41cc457b554059d374c624c42bcde0212
    mkdir -p cache
    if [[ ! -s $bsp ]]; then
      curl --fail --location --retry 3 --output "$bsp.partial" "$bsp_url"
      mv -f "$bsp.partial" "$bsp"
    fi
    actual_sha256=$(openssl dgst -sha256 "$bsp" | awk '{print $NF}')
    [[ $actual_sha256 == "$bsp_sha256" ]] || {
      echo "NVIDIA BSP SHA-256 mismatch: $bsp" >&2; exit 1
    }
    mounts+=(--mount "type=bind,source=$(pwd)/$bsp,target=/input/bsp.tbz2,readonly")
    brcm_package=cache/firmware-brcm80211_20250410-2_all.deb
    brcm_url=https://deb.debian.org/debian/pool/non-free-firmware/f/firmware-nonfree/firmware-brcm80211_20250410-2_all.deb
    brcm_sha256=266cc703e2299f5253fd1ff9a1fd625d85a2c8e5a88b1a65fcc190ac384ce3d7
    if [[ ! -s $brcm_package ]]; then
      curl --fail --location --retry 3 --output "$brcm_package.partial" "$brcm_url"
      mv -f "$brcm_package.partial" "$brcm_package"
    fi
    actual_sha256=$(openssl dgst -sha256 "$brcm_package" | awk '{print $NF}')
    [[ $actual_sha256 == "$brcm_sha256" ]] || {
      echo "Debian BCM4354 firmware SHA-256 mismatch: $brcm_package" >&2; exit 1
    }
    mounts+=(--mount "type=bind,source=$(pwd)/$brcm_package,target=/input/brcm-firmware.deb,readonly")
  fi
  if [[ $no_cuda == 0 ]]; then
    mkdir -p cache
    cuda_driver=cache/nvidia-l4t-cuda_36.5.1-20260427132545_arm64.deb
    cuda_driver_url=https://repo.download.nvidia.com/jetson/t234/pool/main/n/nvidia-l4t-cuda/$(basename "$cuda_driver")
    cuda_driver_sha256=e2cba2ecb98de3cc4f3386acd93c9b66a6ce4c2894cab65367c743ece309c482
    cuda_keyring=cache/cuda-ubuntu2204-keyring.gpg
    cuda_keyring_url=https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2204/arm64/cuda-ubuntu2204-keyring.gpg
    cuda_keyring_sha256=25100d6f2eccaee7d6719a70e3c0c6145064aa9edc2c32148f693ac4c524a376
    for package in cuda_driver cuda_keyring; do
      path=${!package}
      url_var=${package}_url
      hash_var=${package}_sha256
      if [[ ! -s $path ]]; then
        curl --fail --location --retry 3 --output "$path.partial" "${!url_var}"
        mv -f "$path.partial" "$path"
      fi
      actual_sha256=$(openssl dgst -sha256 "$path" | awk '{print $NF}')
      [[ $actual_sha256 == "${!hash_var}" ]] || {
        echo "NVIDIA CUDA SHA-256 mismatch: $path" >&2; exit 1;
      }
    done
    mounts+=(--mount "type=bind,source=$(pwd)/$cuda_driver,target=/input/cuda-driver.deb,readonly"
             --mount "type=bind,source=$(pwd)/$cuda_keyring,target=/input/cuda-keyring.gpg,readonly")
  fi
  docker build --platform linux/arm64 -f Containerfile.sd -t debian-tegra-sd-builder .
  docker run --rm --privileged --platform linux/arm64 \
    -e IMAGE_NAME="$output" -e IMAGE_SIZE_MIB="$size_mib" \
    -e IMAGE_HOSTNAME="$hostname" -e IMAGE_FORCE="$force" \
    -e IMAGE_WIFI_SSID="$wifi_ssid" -e IMAGE_WIFI_HIDDEN="$wifi_hidden" \
    "${mounts[@]}" debian-tegra-sd-builder \
    bash /project/scripts/create-sd-image.sh --container
  exit
fi

[[ $EUID == 0 && $(uname -m) == aarch64 && -d /build ]] || {
  echo '--container requires the ARM64 Docker builder' >&2; exit 2;
}
source modules/sources.env
repo_url=https://boondocklabs.github.io/debian-tegra
key_fingerprint=0F248B4E00261A42AC3ECC19C0787BB2FD9D04B6
root=/build/root
part=/build/root.ext4
image=/project/out/$IMAGE_NAME
part_size_mib=$((IMAGE_SIZE_MIB - 2))

mkdir -p "$root" /project/out
debootstrap --arch=arm64 --variant=minbase \
  --include=systemd-sysv,systemd-timesyncd,udev,dbus,avahi-daemon,openssh-server,sudo,network-manager,wpasupplicant,iproute2,iputils-ping,ca-certificates,kmod,initramfs-tools,busybox-static,e2fsprogs,zstd,gzip \
  trixie "$root" https://deb.debian.org/debian

install -d "$root/usr/share/keyrings" "$root/etc/apt/sources.list.d"
curl --fail --silent --show-error --location --retry 3 \
  "$repo_url/archive-keyring.gpg" -o "$root/usr/share/keyrings/debian-tegra-archive-keyring.gpg"
actual_fingerprint=$(gpg --batch --show-keys --with-colons \
  "$root/usr/share/keyrings/debian-tegra-archive-keyring.gpg" \
  | awk -F: '$1 == "fpr" { print $10; exit }')
[[ $actual_fingerprint == "$key_fingerprint" ]] || {
  echo "APT signing key fingerprint mismatch: $actual_fingerprint" >&2; exit 1;
}
cat > "$root/etc/apt/sources.list.d/debian-tegra.list" <<EOF
deb [arch=arm64 signed-by=/usr/share/keyrings/debian-tegra-archive-keyring.gpg] $repo_url/ trixie main
EOF
cat > "$root/etc/initramfs-tools/conf.d/tegra-tx1" <<'EOF'
MODULES=list
COMPRESS=zstd
BUSYBOX=y
EOF
cat >> "$root/etc/initramfs-tools/modules" <<'EOF'
i2c-tegra
fixed
gpio-regulator
max77620-regulator
sdhci-tegra
sdhci
mmc_block
ext4
EOF
cat > "$root/usr/sbin/policy-rc.d" <<'EOF'
#!/bin/sh
exit 101
EOF
chmod 755 "$root/usr/sbin/policy-rc.d"
rm -f "$root/etc/resolv.conf"
cp /etc/resolv.conf "$root/etc/resolv.conf"
mount -t proc proc "$root/proc"
mount --rbind /dev "$root/dev"
mount --make-rslave "$root/dev"
cleanup_mounts() {
  umount -R "$root/dev" || true
  umount "$root/proc" || true
}
trap cleanup_mounts EXIT

chroot "$root" apt-get update -o APT::Update::Error-Mode=any
chroot "$root" env DEBIAN_FRONTEND=noninteractive apt-get install -y \
  --no-install-recommends \
  "linux-image-$DEBIAN_KERNEL_ABI=$DEBIAN_KERNEL_VERSION" \
  "linux-headers-$DEBIAN_KERNEL_ABI=$DEBIAN_KERNEL_VERSION" \
  "$NVMAP_PACKAGE_NAME=$NVMAP_PACKAGE_VERSION" \
  "$NVGPU_PACKAGE_NAME=$NVGPU_PACKAGE_VERSION" \
  "debian-tegra-tx1-device-tree=$DEBIAN_KERNEL_VERSION"

if [[ -f /input/cuda-driver.deb && -f /input/cuda-keyring.gpg ]]; then
  cuda_driver_dir=$root/opt/debian-tegra/nvidia-r36.5.1
  mkdir -p "$cuda_driver_dir"
  dpkg-deb -x /input/cuda-driver.deb "$cuda_driver_dir"
  test -s "$cuda_driver_dir/usr/lib/aarch64-linux-gnu/nvidia/libcuda.so.1.1"
  install -m 644 /input/cuda-keyring.gpg \
    "$root/usr/share/keyrings/debian-tegra-cuda-build-keyring.gpg"
  cat > "$root/etc/apt/sources.list.d/debian-tegra-cuda-build.list" <<'EOF'
deb [arch=arm64 signed-by=/usr/share/keyrings/debian-tegra-cuda-build-keyring.gpg] https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2204/arm64/ /
EOF
  # Debian 13's sqv rejects a SHA-1 binding in NVIDIA's current key. gpgv
  # still verifies the signed repository using the pinned NVIDIA key.
  chroot "$root" env DEBIAN_FRONTEND=noninteractive apt-get install -y \
    --no-install-recommends gpgv gcc-13 g++-13 make
  chroot "$root" apt-get update -o APT::Key::GPGVCommand=/usr/bin/gpgv \
    -o APT::Update::Error-Mode=any
  chroot "$root" env DEBIAN_FRONTEND=noninteractive apt-get install -y \
    --no-install-recommends cuda-toolkit-12-6=12.6.3-1
  test -x "$root/usr/local/cuda-12.6/bin/nvcc"
  test -s "$root/usr/local/cuda-12.6/targets/aarch64-linux/lib/libcudart.so.12"
  cat > "$root/usr/local/bin/nvcc" <<'EOF'
#!/bin/sh
NVCC_CCBIN=${NVCC_CCBIN:-/usr/bin/g++-13}
export NVCC_CCBIN
exec /usr/local/cuda-12.6/bin/nvcc "$@"
EOF
  chmod 755 "$root/usr/local/bin/nvcc"
  cat > "$root/etc/profile.d/debian-tegra-cuda.sh" <<'EOF'
export CUDA_HOME=/usr/local/cuda-12.6
export NVCC_CCBIN=${NVCC_CCBIN:-/usr/bin/g++-13}
export PATH="$PATH:$CUDA_HOME/bin"
EOF
  # glibc 2.41 marks these four functions noexcept; CUDA 12.6 predates that
  # declaration and otherwise fails while compiling even a minimal .cu file.
  cuda_math_header=$root/usr/local/cuda-12.6/targets/aarch64-linux/include/crt/math_functions.h
  [[ $(grep -Ec '^extern .* (sinpi|cospi)\(double x\);$|^extern .* (sinpif|cospif)\(float x\);$' "$cuda_math_header") == 4 ]] || {
    echo 'Unexpected CUDA math_functions.h; refusing to patch declarations' >&2; exit 1;
  }
  sed -i -E 's/((sinpi|cospi)\(double x\)|(sinpif|cospif)\(float x\));/\1 noexcept;/' \
    "$cuda_math_header"
  cat > "$root/tmp/debian-tegra-cuda-smoke.cu" <<'EOF'
__global__ void probe(int *value) { *value = 7; }
int main() { return 0; }
EOF
  chroot "$root" /usr/local/bin/nvcc -gencode arch=compute_53,code=sm_53 \
    /tmp/debian-tegra-cuda-smoke.cu -o /tmp/debian-tegra-cuda-smoke
  rm -f "$root/tmp/debian-tegra-cuda-smoke.cu" \
    "$root/tmp/debian-tegra-cuda-smoke"
  cat > "$root/etc/ld.so.conf.d/debian-tegra-cuda.conf" <<'EOF'
/opt/debian-tegra/nvidia-r36.5.1/usr/lib/aarch64-linux-gnu/nvidia
/usr/local/cuda-12.6/targets/aarch64-linux/lib
EOF
  chroot "$root" ldconfig
  rm -f "$root/etc/apt/sources.list.d/debian-tegra-cuda-build.list" \
    "$root/usr/share/keyrings/debian-tegra-cuda-build-keyring.gpg"
  rm -f "$root"/var/lib/apt/lists/*developer.download.nvidia.com*
fi

gpu_default=debian-tegra-safe
firmware_source=
if [[ -f /input/bsp.tbz2 ]]; then
  # The downloaded BSP is local build input. Extract only the TX1 firmware,
  # not NVIDIA's kernel, userspace libraries, or flashing tools.
  tar -xOf /input/bsp.tbz2 \
    Linux_for_Tegra/nv_tegra/nvidia_drivers.tbz2 \
    > /build/nvidia_drivers.tbz2
  mkdir -p /build/nvidia-firmware
  tar -xjf /build/nvidia_drivers.tbz2 -C /build/nvidia-firmware \
    lib/firmware/tegra21x lib/firmware/brcm \
    lib/firmware/tegra21x_xusb_firmware
  firmware_source=/build/nvidia-firmware/lib/firmware
  install -d "$root/usr/share/doc/debian-tegra-tx1-firmware"
  tar -xOf /input/bsp.tbz2 Linux_for_Tegra/nv_tegra/LICENSE \
    > "$root/usr/share/doc/debian-tegra-tx1-firmware/LICENSE"
elif [[ -d /input/firmware ]]; then
  firmware_source=/input/firmware
fi
if [[ -n $firmware_source ]]; then
  [[ -s $firmware_source/tegra21x/pmu_sig.bin ]] || {
    echo 'NVIDIA BSP is missing TX1 GPU firmware' >&2; exit 1
  }
  install -d "$root/usr/lib/firmware/tegra21x" \
    "$root/usr/lib/firmware/nvidia/gm20b"
  cp -aL "$firmware_source/tegra21x/." "$root/usr/lib/firmware/tegra21x/"
  cp -aL "$firmware_source/tegra21x/." "$root/usr/lib/firmware/nvidia/gm20b/"
  if [[ -s $firmware_source/tegra21x_xusb_firmware ]]; then
    install -m 644 "$firmware_source/tegra21x_xusb_firmware" \
      "$root/usr/lib/firmware/tegra21x_xusb_firmware"
    install -d "$root/etc/initramfs-tools/hooks"
    cat > "$root/etc/initramfs-tools/hooks/tegra-xusb" <<'EOF'
#!/bin/sh
case "$1" in prereqs) exit 0;; esac
. /usr/share/initramfs-tools/hook-functions
copy_file firmware /lib/firmware/tegra21x_xusb_firmware
EOF
    chmod 755 "$root/etc/initramfs-tools/hooks/tegra-xusb"
  fi
  if [[ -s $firmware_source/brcm/fw_bcmdhd.bin && -s $firmware_source/brcm/nvram.txt ]]; then
    install -d "$root/usr/lib/firmware/brcm"
    install -m 644 "$firmware_source/brcm/fw_bcmdhd.bin" \
      "$root/usr/lib/firmware/brcm/brcmfmac4354-sdio.bin"
    install -m 644 "$firmware_source/brcm/nvram.txt" \
      "$root/usr/lib/firmware/brcm/brcmfmac4354-sdio.txt"
    cp "$root/usr/lib/firmware/brcm/brcmfmac4354-sdio.txt" \
      "$root/usr/lib/firmware/brcm/brcmfmac4354-sdio.nvidia,p2371-2180.txt"
  fi
  if [[ -s $firmware_source/brcm/brcmfmac4354-sdio.clm_blob ]]; then
    install -m 644 "$firmware_source/brcm/brcmfmac4354-sdio.clm_blob" \
      "$root/usr/lib/firmware/brcm/brcmfmac4354-sdio.clm_blob"
  fi
  gpu_default=debian-tegra-gpu
fi
if [[ -f /input/brcm-firmware.deb ]]; then
  dpkg-deb -x /input/brcm-firmware.deb /build/debian-brcm-firmware
  install -m 644 \
    /build/debian-brcm-firmware/usr/lib/firmware/brcm/brcmfmac4354-sdio.clm_blob \
    "$root/usr/lib/firmware/brcm/brcmfmac4354-sdio.clm_blob"
  install -d "$root/usr/share/doc/firmware-brcm80211"
  install -m 644 /build/debian-brcm-firmware/usr/share/doc/firmware-brcm80211/copyright \
    "$root/usr/share/doc/firmware-brcm80211/copyright"
fi

chroot "$root" update-initramfs -u -k "$DEBIAN_KERNEL_ABI"
initrd=$root/boot/initrd.img-$DEBIAN_KERNEL_ABI
[[ -s $initrd ]] && (( $(stat -c %s "$initrd") < 14000000 )) || {
  echo 'TX1 initramfs exceeds the verified U-Boot size limit' >&2; exit 1;
}
gzip -dc "$root/boot/vmlinuz-$DEBIAN_KERNEL_ABI" \
  > "$root/boot/Image-$DEBIAN_KERNEL_ABI"
[[ $(od -An -tx4 -j 56 -N 4 "$root/boot/Image-$DEBIAN_KERNEL_ABI" | tr -d ' ') == 644d5241 ]] || {
  echo 'Decompressed kernel lacks the ARM64 Image magic' >&2; exit 1;
}
install -m 644 \
  "$root/usr/lib/linux-image-$DEBIAN_KERNEL_ABI/nvidia/tegra210-p2371-2180-nvgpu-fan.dtb" \
  "$root/boot/tegra210-p2371-2180-nvgpu-fan.dtb"

# Keep U-Boot's boot files synchronized when APT upgrades packages within
# this ABI. A new ABI still needs a new extlinux entry.
cat > "$root/usr/local/sbin/debian-tegra-refresh-sd-boot" <<EOF
#!/bin/sh
set -eu
abi=$DEBIAN_KERNEL_ABI
test -f "/boot/vmlinuz-\$abi" || exit 0
tmp=\$(mktemp "/boot/.Image-\$abi.XXXXXXXX")
trap 'rm -f "\$tmp"' EXIT
gzip -dc "/boot/vmlinuz-\$abi" > "\$tmp"
test "\$(od -An -tx4 -j 56 -N 4 "\$tmp" | tr -d ' ')" = 644d5241
chmod 644 "\$tmp"
mv -f "\$tmp" "/boot/Image-\$abi"
trap - EXIT
dtb="/usr/lib/linux-image-\$abi/nvidia/tegra210-p2371-2180-nvgpu-fan.dtb"
test -f "\$dtb" || exit 0
cp -f "\$dtb" /boot/tegra210-p2371-2180-nvgpu-fan.dtb
EOF
chmod 755 "$root/usr/local/sbin/debian-tegra-refresh-sd-boot"
cat > "$root/etc/apt/apt.conf.d/99debian-tegra-sd-boot" <<'EOF'
DPkg::Post-Invoke {"/usr/local/sbin/debian-tegra-refresh-sd-boot";};
EOF

cat > "$root/etc/hostname" <<< "$IMAGE_HOSTNAME"
cat > "$root/etc/hosts" <<EOF
127.0.0.1 localhost
127.0.1.1 $IMAGE_HOSTNAME
::1 localhost ip6-localhost ip6-loopback
EOF
partuuid=$(cat /proc/sys/kernel/random/uuid)
fsuuid=$(cat /proc/sys/kernel/random/uuid)
diskuuid=$(cat /proc/sys/kernel/random/uuid)
cat > "$root/etc/fstab" <<EOF
PARTUUID=$partuuid / ext4 defaults,noatime,errors=remount-ro 0 1
EOF
chroot "$root" groupadd -f render
chroot "$root" useradd -m -s /bin/bash -G sudo,adm,dialout,video,render debian
if [[ -f /input/root_password ]]; then
  [[ -s /input/root_password ]] || { echo 'Root password is empty' >&2; exit 2; }
  { printf 'root:'; cat /input/root_password; printf '\n'; } | chroot "$root" chpasswd
  [[ $(chroot "$root" passwd -S root | awk '{print $2}') == P ]] || {
    echo 'Could not set the root password' >&2; exit 1;
  }
else
  chroot "$root" passwd -l root
fi
chroot "$root" passwd -l debian
uid=$(chroot "$root" id -u debian)
gid=$(chroot "$root" id -g debian)
install -d -m 700 -o "$uid" -g "$gid" "$root/home/debian/.ssh"
install -m 600 -o "$uid" -g "$gid" /input/authorized_keys \
  "$root/home/debian/.ssh/authorized_keys"
echo 'debian ALL=(ALL:ALL) NOPASSWD: ALL' > "$root/etc/sudoers.d/debian"
chmod 440 "$root/etc/sudoers.d/debian"
mkdir -p "$root/etc/ssh/sshd_config.d" "$root/etc/NetworkManager/system-connections"
cat > "$root/etc/ssh/sshd_config.d/10-debian-tegra.conf" <<'EOF'
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
AllowUsers debian
EOF
cat > "$root/etc/NetworkManager/system-connections/wired.nmconnection" <<'EOF'
[connection]
id=Wired Ethernet
type=ethernet
interface-name=eth0
autoconnect=true
[ipv4]
method=auto
[ipv6]
method=auto
EOF
chmod 600 "$root/etc/NetworkManager/system-connections/wired.nmconnection"
if [[ -n ${IMAGE_WIFI_SSID:-} ]]; then
  LC_ALL=C
  wifi_password=$(cat /input/wifi_password)
  password_bytes=$(wc -c < /input/wifi_password)
  password_chars=${#wifi_password}
  if (( password_bytes == password_chars + 1 )); then
    [[ $(tail -c 1 /input/wifi_password | od -An -tu1 | tr -d ' ') == 10 ]] || {
      echo 'Wi-Fi password file contains unsupported bytes' >&2; exit 2;
    }
  elif (( password_bytes != password_chars )); then
    echo 'Wi-Fi password file must contain one line' >&2; exit 2
  fi
  if [[ ! $wifi_password =~ ^[[:print:]]+$ || $wifi_password == ' '* || $wifi_password == *' ' ]]; then
    echo 'Wi-Fi password must be printable ASCII with no edge spaces' >&2; exit 2
  fi
  if [[ $wifi_password =~ ^[0-9A-Fa-f]{64}$ ]]; then
    :
  elif (( password_chars < 8 || password_chars > 63 )); then
    echo 'Wi-Fi password must be 8-63 characters or a 64-digit hex PSK' >&2; exit 2
  fi
  wifi_ssid_escaped=${IMAGE_WIFI_SSID//\\/\\\\}
  wifi_password_escaped=${wifi_password//\\/\\\\}
  wifi_hidden_value=false
  [[ $IMAGE_WIFI_HIDDEN == 1 ]] && wifi_hidden_value=true
  wifi_profile=$root/etc/NetworkManager/system-connections/tx1-wifi.nmconnection
  install -m 600 /dev/null "$wifi_profile"
  cat > "$wifi_profile" <<EOF
[connection]
id=TX1 Wi-Fi
type=wifi
interface-name=wlan0
autoconnect=true

[wifi]
mode=infrastructure
ssid=$wifi_ssid_escaped
hidden=$wifi_hidden_value
security=802-11-wireless-security

[wifi-security]
key-mgmt=wpa-psk
psk=$wifi_password_escaped

[ipv4]
method=auto
[ipv6]
method=auto
EOF
  unset wifi_password wifi_password_escaped
fi
cat > "$root/etc/systemd/system/ssh-host-keys.service" <<'EOF'
[Unit]
Description=Generate unique SSH host keys on first boot
Before=ssh.service
ConditionPathExists=!/etc/ssh/ssh_host_ed25519_key
[Service]
Type=oneshot
ExecStart=/usr/bin/ssh-keygen -A
[Install]
WantedBy=multi-user.target
EOF
mkdir -p "$root/etc/systemd/system/ssh.service.d"
cat > "$root/etc/systemd/system/ssh.service.d/host-keys.conf" <<'EOF'
[Unit]
Requires=ssh-host-keys.service
After=ssh-host-keys.service
EOF
cat > "$root/etc/udev/rules.d/70-debian-tegra-gpu.rules" <<'EOF'
SUBSYSTEM=="misc", KERNEL=="nvmap", GROUP="video", MODE="0660"
SUBSYSTEM=="nvidia-gpu", KERNEL=="nvhost-*", GROUP="video", MODE="0660"
SUBSYSTEM=="nvidia-gpu-v2", GROUP="video", MODE="0660"
EOF
chroot "$root" systemctl enable NetworkManager wpa_supplicant avahi-daemon ssh ssh-host-keys \
  systemd-timesyncd serial-getty@ttyS0
chroot "$root" systemctl set-default multi-user.target
rm -f "$root/etc/ssh/ssh_host_"* "$root/usr/sbin/policy-rc.d"
: > "$root/etc/machine-id"
rm -f "$root/var/lib/dbus/machine-id"
ln -s /etc/machine-id "$root/var/lib/dbus/machine-id"
rm -f "$root/var/lib/systemd/random-seed"
chroot "$root" apt-get clean

mkdir -p "$root/boot/extlinux"
cat > "$root/boot/extlinux/extlinux.conf" <<EOF
TIMEOUT 30
DEFAULT $gpu_default
MENU TITLE Debian 13 - Jetson TX1 SD

LABEL debian-tegra-gpu
    MENU LABEL Debian 13 $DEBIAN_KERNEL_ABI (GPU enabled)
    LINUX /boot/Image-$DEBIAN_KERNEL_ABI
    INITRD /boot/initrd.img-$DEBIAN_KERNEL_ABI
    FDT /boot/tegra210-p2371-2180-nvgpu-fan.dtb
    APPEND \${cbootargs} root=PARTUUID=$partuuid rootfstype=ext4 rw rootwait net.ifnames=0 modprobe.blacklist=nouveau oops=panic panic=10 console=ttyS0,115200n8

LABEL debian-tegra-safe
    MENU LABEL Debian 13 $DEBIAN_KERNEL_ABI (manual GPU load)
    LINUX /boot/Image-$DEBIAN_KERNEL_ABI
    INITRD /boot/initrd.img-$DEBIAN_KERNEL_ABI
    FDT /boot/tegra210-p2371-2180-nvgpu-fan.dtb
    APPEND \${cbootargs} root=PARTUUID=$partuuid rootfstype=ext4 rw rootwait net.ifnames=0 modprobe.blacklist=nvgpu,nouveau oops=panic panic=10 console=ttyS0,115200n8
EOF

umount -R "$root/dev"
umount "$root/proc"
trap - EXIT
used_mib=$(du -sm "$root" | awk '{print $1}')
(( used_mib + 256 < part_size_mib )) || {
  echo "Root filesystem ($used_mib MiB) needs a larger --size-mib" >&2; exit 1;
}
truncate -s "${part_size_mib}M" "$part"
mkfs.ext4 -F -q -b 4096 -L TEGRA-TX1-SD -m 1 -U "$fsuuid" \
  -O '^metadata_csum_seed,^orphan_file,^64bit' \
  -E lazy_itable_init=0,lazy_journal_init=0 -d "$root" "$part"
e2fsck -fn "$part" > /project/out/$IMAGE_NAME.fsck.txt
if [[ -e $image && $IMAGE_FORCE != 1 ]]; then
  echo "$image exists; refusing to replace it" >&2; exit 2
fi
temp_image=$(mktemp "/project/out/.${IMAGE_NAME}.XXXXXXXX")
trap 'rm -f "$temp_image" "$temp_image.sha256"' EXIT
truncate -s "${IMAGE_SIZE_MIB}M" "$temp_image"
sgdisk -o -U "$diskuuid" "$temp_image"
sgdisk -n 1:2048:0 -t 1:8300 -c 1:debian-tegra-tx1 \
  -u 1:"$partuuid" -A 1:set:2 "$temp_image"
dd if="$part" of="$temp_image" bs=1M seek=1 conv=notrunc,sparse status=none
sgdisk -v "$temp_image"
digest=$(sha256sum "$temp_image" | awk '{print $1}')
printf '%s  %s\n' "$digest" "$IMAGE_NAME" > "$temp_image.sha256"
mv -f "$temp_image" "$image"
mv -f "$temp_image.sha256" "$image.sha256"
trap - EXIT
printf 'Image: %s\nRoot PARTUUID: %s\n' "$image" "$partuuid"
