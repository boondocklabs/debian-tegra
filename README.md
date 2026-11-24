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
automatic boot-failure fallback. The generated image passed an offline build,
filesystem, and partition check; this particular image builder has not yet
been physically boot-tested.

Without TX1 firmware, the image defaults to the safe boot entry that keeps
`nvgpu` unloaded. Pass `--firmware-dir DIR` with a local firmware tree
containing `tegra21x/pmu_sig.bin` to copy GPU firmware and default to the
GPU-enabled entry. If that tree also contains `brcm/fw_bcmdhd.bin` and
`brcm/nvram.txt`, the builder installs the BCM4354 Wi-Fi aliases. Firmware and
CUDA userspace are not downloaded or distributed by this repository. Debian
package updates within the same kernel ABI use APT; a new kernel ABI requires
updating the boot entry or rebuilding the image.

## CUDA userspace

CUDA needs matching NVIDIA userspace libraries and TX1 firmware in addition
to these kernel packages. The tested combination used R36.5.1 `libcuda` from
NVIDIA's `nvidia-l4t-cuda` package and CUDA 12.6.77 `libcudart` from NVIDIA's
`cuda-cudart-12-6` package. Those binaries are fetched from NVIDIA separately;
this repository does not contain or redistribute them.

## APT repository

After a successful build on `main`, the Pages workflow publishes the five
packages as a signed Debian 13 ARM64 APT repository at
<https://boondocklabs.github.io/debian-tegra/>. The repository signing key is
exported alongside the packages. This requires the GitHub Pages source to be
set to **GitHub Actions** and a dedicated, unencrypted ASCII-armored private
key in the `APT_GPG_PRIVATE_KEY` Actions secret. The key is used only to sign
the repository metadata; it is not included in the published files.
The archive key fingerprint is
`0F24 8B4E 0026 1A42 AC3E CC19 C078 7BB2 FD9D 04B6`.

On a Debian 13 TX1 system, add the repository with:

```sh
curl -fsSL https://boondocklabs.github.io/debian-tegra/archive-keyring.gpg \
  | sudo tee /usr/share/keyrings/debian-tegra-archive-keyring.gpg >/dev/null
echo 'deb [arch=arm64 signed-by=/usr/share/keyrings/debian-tegra-archive-keyring.gpg] https://boondocklabs.github.io/debian-tegra/ trixie main' \
  | sudo tee /etc/apt/sources.list.d/debian-tegra.list
sudo apt update
```

The repository contains the kernel image, headers, nvmap, nvgpu, and device
tree packages. It does not distribute CUDA userspace or firmware.
