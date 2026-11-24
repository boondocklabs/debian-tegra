# debian-tegra

This project brings the NVIDIA Jetson TX1 Developer Kit (P2371-2180 module on
the P2597 carrier) to a **Debian 13, Linux 6.12 kernel** while retaining its
GM20B GPU through a port of NVIDIA's `nvgpu` driver. It builds an nvmap module
for GPU memory sharing and device trees that enable the GPU and the carrier's
fan. The aim is to run a current Debian userspace and kernel with the TX1 GPU,
including a path to CUDA 12 applications.

The port has been exercised on a TX1 with NVIDIA R36.5.1 `libcuda` and CUDA
12.6.77 `libcudart`: the CUDA driver API enumerated the GM20B GPU, copied
memory, JIT-loaded SM 5.3 PTX, launched a kernel, and read back its result.
The CUDA runtime also completed a memory round trip. This is an experimental
compatibility result, not NVIDIA support for TX1 on R36.5 or a claim that
every CUDA 12 release works. GitHub Actions compiles packages; it cannot run
these hardware tests.

## What it builds

| Package | Contents |
| --- | --- |
| `linux-image-6.12.118-tegra-tx1` | Debian 13 kernel with the TX1 SMMU DMA patch |
| `linux-headers-6.12.118-tegra-tx1` | Matching headers for external modules |
| `debian-tegra-nvmap-tx1` | Patched NVIDIA nvmap module |
| `debian-tegra-nvgpu-tx1` | Patched NVIDIA nvgpu module for GM20B |
| `debian-tegra-tx1-device-tree` | GPU-enabled DTB and P2597 fan overlay/DTB |

The kernel comes from Debian's `6.12.118-1` source package. Its URL and
SHA-256 are pinned in [build-kernel.sh](scripts/build-kernel.sh). The
[module source commits](modules/sources.env), [kernel config](kernel/tx1-arm64.config),
[kernel patch](kernel/patches/0001-tegra210-gpu-dma-domain.patch),
[module patches](modules), and [fan overlay](device-tree/tx1-fan.dtso) are
checked in. The kernel ABI is `6.12.118-tegra-tx1`; the module and device tree
packages depend on that exact kernel version.

## Build

With Docker and ARM64 support, run:

```sh
bash scripts/build-all.sh
```

The `.deb` files and `SHA256SUMS` appear in `out/`. The
[GitHub Actions workflow](.github/workflows/build.yml) builds the kernel image
and headers together, then runs nvmap, nvgpu, and device tree jobs separately.
It uploads both individual job artifacts and a combined five-package artifact.
The kernel source is compiled in a case-sensitive Docker volume so the local
build also works from a macOS checkout.
Pushes and pull requests run this build only when build inputs or the build
workflow change. README and APT publishing changes do not rebuild packages;
the build can still be started manually from GitHub Actions.

The device tree package installs files under
`/usr/lib/linux-image-6.12.118-tegra-tx1/nvidia/`. Select the GPU or GPU/fan
DTB in the board's bootloader configuration. Installing these packages does
not change the bootloader.

## Bootable TX1 SD image

With Docker on an ARM64 host, build a 4 GiB Debian 13 SD image using the five
version-pinned packages from the signed APT repository:

```sh
bash scripts/create-sd-image.sh --authorized-keys ~/.ssh/id_ed25519.pub
```

The output is `out/debian-tegra-tx1-sd.img` with a SHA-256 file beside it. Use
`--size-mib` for a larger card, `--output` for another filename, and `--force`
to replace an existing output. Use an 8 GB or larger SD card for the default
4 GiB image. The builder uses privileged Docker for its debootstrap chroot
mounts and verifies the APT signing key fingerprint before installing the
packages. It creates a `debian` account with the supplied SSH key and
passwordless sudo, enables wired DHCP and serial login, and generates unique
SSH host keys on first boot.

To connect over WPA/WPA2 Wi-Fi, pass the SSID and enter the password at the
terminal prompt:

```sh
bash scripts/create-sd-image.sh --authorized-keys ~/.ssh/id_ed25519.pub \
  --wifi-ssid 'Your network' --force
```

The password must be 8–63 printable ASCII characters or a 64-digit hex PSK.
The SSID and password cannot begin or end with a space. Use
`--wifi-password-file FILE` for a noninteractive build, or add `--wifi-hidden`
for a network that does not broadcast its SSID. The image stores the password
in a root-only NetworkManager profile so Wi-Fi can connect at boot; keep the
resulting image private. Without these options, the image uses wired DHCP and
has no Wi-Fi connection profile.

On macOS, identify the SD card with `diskutil list`, then replace `diskN`
below with that card's disk number:

```sh
diskutil unmountDisk /dev/diskN
sudo dd if=out/debian-tegra-tx1-sd.img of=/dev/rdiskN bs=4m status=progress
diskutil eject /dev/diskN
```

The image has one GPT ext4 partition containing `/boot/extlinux/extlinux.conf`,
the packaged kernel and modules, an initramfs with TX1 SD/PMIC drivers, and
the GPU/fan device tree. It has **no bootloader**: the TX1's eMMC U-Boot must
try SD (`mmc1`) before eMMC (`mmc0`). The tested developer kit does this. If
the SD kernel cannot boot, remove the card and reboot to use eMMC; there is no
automatic boot-failure fallback. On a TX1 Developer Kit, U-Boot selected this
SD image, started Linux 6.12, and reached Debian's multi-user serial login.
The builder also checks the filesystem and partition table. SSH requires a
working network connection; wired DHCP is always configured, while Wi-Fi
requires the options above.

By default, the builder downloads NVIDIA's Jetson Linux R32.7.6 TX1 BSP and
Debian's `firmware-brcm80211` package, checks their pinned SHA-256 hashes,
and extracts the GM20B GPU, BCM4354 Wi-Fi, XUSB, and BCM4354 channel firmware
into the image. The GPU-enabled boot entry is the default;
the menu also offers a safe entry that keeps `nvgpu` unloaded. Use
`--firmware-dir DIR` to supply a local firmware tree instead, or
`--no-firmware` to skip firmware and default to the safe entry. Downloads stay
under the ignored `cache/` directory. Firmware stays in your local cache and
image; it is not committed, built in CI, or published in the APT repository.
CUDA userspace is separate. Debian package
updates within the same kernel ABI use APT; a new kernel ABI requires
updating the boot entry or rebuilding the image.

## CUDA userspace

CUDA needs matching NVIDIA userspace libraries and TX1 firmware in addition
to these kernel packages. The tested combination used R36.5.1 `libcuda` from
NVIDIA's `nvidia-l4t-cuda` package and CUDA 12.6.77 `libcudart` from NVIDIA's
`cuda-cudart-12-6` package. Those binaries are fetched from NVIDIA separately;
this repository does not contain or redistribute them.

## APT repository

The signed Debian 13 ARM64 repository at
<https://boondocklabs.github.io/debian-tegra/> provides the TX1 kernel image,
headers, nvmap, nvgpu, and device tree packages. The SD image builder adds
this source and installs the pinned package versions for you.

The archive key fingerprint is
`0F24 8B4E 0026 1A42 AC3E CC19 C078 7BB2 FD9D 04B6`.
On a Debian 13 TX1 system, add the repository and packages with:

```sh
curl -fsSL https://boondocklabs.github.io/debian-tegra/archive-keyring.gpg \
  | sudo tee /usr/share/keyrings/debian-tegra-archive-keyring.gpg >/dev/null
echo 'deb [arch=arm64 signed-by=/usr/share/keyrings/debian-tegra-archive-keyring.gpg] https://boondocklabs.github.io/debian-tegra/ trixie main' \
  | sudo tee /etc/apt/sources.list.d/debian-tegra.list
sudo apt update
sudo apt install linux-image-6.12.118-tegra-tx1 \
  linux-headers-6.12.118-tegra-tx1 debian-tegra-nvmap-tx1 \
  debian-tegra-nvgpu-tx1 debian-tegra-tx1-device-tree
```

After setup, use `sudo apt update && sudo apt upgrade` for package updates.
The repository does not include CUDA userspace or firmware.
