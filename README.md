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
every CUDA 12 release works. The hardware results below were measured on a
physical TX1 Developer Kit. GitHub Actions verifies the package builds.

## What it builds

| Package | Contents |
| --- | --- |
| `linux-image-6.12.118-tegra-tx1` | Debian 13 kernel with the TX1 SMMU DMA patch |
| `linux-headers-6.12.118-tegra-tx1` | Matching headers for external modules |
| `debian-tegra-nvmap-tx1` | Patched NVIDIA nvmap module |
| `debian-tegra-nvgpu-tx1` | Patched NVIDIA nvgpu module for GM20B |
| `debian-tegra-tx1-device-tree` | GPU-enabled DTB, P2597 fan, and optional OV5693 CSI and EMC overlays |

The kernel comes from Debian's `6.12.118-1` source package. Its URL and
SHA-256 are pinned in [build-kernel.sh](scripts/build-kernel.sh). The
[module source commits](modules/sources.env), [kernel config](kernel/tx1-arm64.config),
[kernel patches](kernel/patches), [module patches](modules),
[fan overlay](device-tree/tx1-fan.dtso), [OV5693 overlay](device-tree/tx1-ov5693.dtso),
and [EMC overlay](device-tree/tx1-emc.dtso) are checked in. The kernel ABI
is `6.12.118-tegra-tx1`; the module and device tree packages depend on that
exact kernel version.

The compact TX1 config removes Nouveau, other unused SoC families, DVB/radio, and legacy
network and USB serial drivers while retaining KVM/virtio and common USB and
PCIe storage, network, audio, and input support as modules. USB UVC, Tegra
VI, and OV5693/IMX219 camera sensor drivers remain modules. The device tree
package includes an optional OV5693 overlay for the P2597 front camera; its
boot menu entry selects that DTB while the default keeps camera probing off.
Tegra `host1x`, DRM display, I2C, and display regulators are built in so the HDMI
framebuffer console can appear during kernel initialization. NVIDIA `nvgpu`
and `nvmap` remain separate upgradeable module packages; early display does
not require the compute GPU driver. The build uses `-mtune=cortex-a57` and
package revision `6.12.118-1+tegra4`. The kernel, HDMI DRM connector,
GPU modules, XUSB, Wi-Fi, and Bluetooth have booted on the TX1 developer kit.
The OV5693 boot entry exposes the E3326 sensor through V4L2 as 10-bit
Bayer (`BG10`). The two tested capture sizes are 2592×1944 and 1296×972.

The Jetson Linux R32.7.6 driver enables the analog and I/O supplies, drives
PS7 high, waits about 2 ms, drives PS4 high to release reset, and waits about
2 ms again. Linux 6.12 uses logical GPIO assertion and deassertion. Both
signals are active low in the TX1 overlay so the sensor runs with both pins
high. The overlay also selects the CSI-C calibration pad and VI input 2.
The kernel patches initialize the V4L2 format negotiation crop from the
active sensor crop and program the selected sensor mode on each stream start.

The Tegra210 kernel exposes the NVIDIA BSP fence and event polling ioctls
through `/dev/host1x-fence`. The device tree package grants access to members
of the `video` group, matching the GPU device permissions.

The P2597 fan driver inverts the active-low PWM output. The DTB, thermal
controller, and hwmon retain a 0–255 duty scale so jtop reports 0% for off
and 100% for full speed. Zero duty turns off the fan supply by default.
On the test board, the fan started from the off state and sped up when the
cooling state was raised.

## TX1 EMC and ACTMON

The optional `tegra210-p2371-2180-nvgpu-fan-ov5693-emc.dtb` enables ACTMON
scaling for RAM code 0 at 408, 665.6, and 800 MHz. It reads the nominal and
derated LPDDR4 timings that NVIDIA CBoot trains on each boot. The DTB
requires the P2371-2180 CBoot handoff at `0x83100000`.

On one TX1 with RAM code 0, the packaged 408–800 MHz range passed all eight
workloads in the 15-second suite and a 128 MiB RAM integrity test. A separate
opt-in test kernel and DTB used six trained rates from 408 to 1,600 MHz.
The higher rates of 1,065.6, 1,331.2, and 1,600 MHz each passed a 32 MiB RAM
integrity test. All 1,314 EMC samples from the fixed-rate CUDA run measured
1,600 MHz.

With automatic scaling on the higher-rate test entry, EMC reached 1,600 MHz
in 150 of 153 samples during a 15-second CUDA copy and returned to 408 MHz
about 1.5 seconds after the load ended. The 64-second MAX77620 hardware
watchdog armed before ACTMON loaded, and the known-good OV5693 entry stayed
the default throughout testing.

Copy the packaged EMC DTB from `/usr/lib/linux-image-6.12.118-tegra-tx1/nvidia/` to
`/boot/`. Add a copy of the OV5693 entry in `/boot/extlinux/extlinux.conf`
with a unique label and point its `FDT` line to the EMC DTB. Keep the original
entry as the default while testing. After boot, use these commands to read
the current EMC clock and ACTMON’s transition counters.

```sh
sudo cat /sys/kernel/debug/clk/emc/clk_rate
cat /sys/class/devfreq/6000c800.actmon/trans_stat
```

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

With Docker on an ARM64 host, build an 8 GiB Debian 13 SD image using the five
version-pinned packages from the signed APT repository:

```sh
bash scripts/create-sd-image.sh --authorized-keys ~/.ssh/id_ed25519.pub
```

To test newly built packages before repository publication, run
`bash scripts/build-all.sh` and pass `--local-packages out` to the image
builder. The image still gets Debian base packages from Debian's mirror.

The output is `out/debian-tegra-tx1-sd.img` with a SHA-256 file beside it. Use
`--size-mib` for a larger card, `--output` for another filename, and `--force`
to replace an existing output. Use a 16 GB or larger SD card for the default
8 GiB image. The builder uses privileged Docker for its debootstrap chroot
mounts and verifies the APT signing key fingerprint before installing the
packages. It creates a `debian` account with the supplied SSH key and
passwordless sudo, verifies that `debian` can run `sudo -n true`, installs
`curl`, Python pip and setuptools, and jtop 7.3.0 from a pinned
jetson_stats Git commit. It enables wired DHCP, Avahi mDNS, serial login,
and the jtop service, generates the `en_CA.UTF-8` locale, and creates unique
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

Add `--root-password` to prompt twice for a root password. This enables root
login on the local console; root SSH login remains disabled. Without the
option, the root account stays locked. With a network connection, Avahi
advertises the configured hostname as `jetson-tx1.local` by default.

On macOS, identify the SD card with `diskutil list`, then replace `diskN`
below with that card's disk number:

```sh
diskutil unmountDisk /dev/diskN
sudo dd if=out/debian-tegra-tx1-sd.img of=/dev/rdiskN bs=4m status=progress
diskutil eject /dev/diskN
```

The image has one GPT ext4 partition containing `/boot/extlinux/extlinux.conf`,
the packaged kernel and modules, an initramfs with TX1 SD/PMIC drivers, and
the GPU/fan device tree plus an optional OV5693 camera boot entry. On first boot, a service expands the root partition
and ext4 filesystem to fill the SD card. It has **no bootloader**: the TX1's
eMMC U-Boot must
try SD (`mmc1`) before eMMC (`mmc0`). The tested developer kit does this. If
the SD kernel cannot boot, remove the card and reboot to use eMMC; there is no
automatic boot-failure fallback. On a TX1 Developer Kit, U-Boot selected this
SD image, started Linux 6.12, and reached Debian's multi-user serial login.
The builder also checks the filesystem and partition table. SSH requires a
working network connection; wired DHCP is always configured, while Wi-Fi
requires the options above.

By default, the builder downloads NVIDIA's Jetson Linux R32.7.6 TX1 BSP and
Debian's `firmware-brcm80211` package, checks their pinned SHA-256 hashes,
and extracts the GM20B GPU, BCM4354 Wi-Fi and Bluetooth, and Tegra210
XUSB/VIC/NVDEC/NVENC/NVJPG firmware into the image. The image includes
`lsusb`, BlueZ (`bluetoothctl`), and `rfkill`. The multimedia and XUSB files
are installed under the filenames requested by the mainline kernel. The
GPU-enabled boot entry is the default;
the menu also offers a safe entry that keeps `nvgpu` unloaded. Use
`--firmware-dir DIR` to supply a local firmware tree instead, or
`--no-firmware` to skip firmware and default to the safe entry. Downloads stay
under the ignored `cache/` directory. Firmware stays in your local cache and
image; it is not committed, built in CI, or published in the APT repository.
Debian package updates within the same kernel ABI use APT; a new kernel ABI requires
updating the boot entry or rebuilding the image.

## CUDA userspace

By default, the SD image builder installs NVIDIA's full ARM64 Jetson
`cuda-toolkit-12-6` package set from NVIDIA's CUDA repository. This includes
`nvcc`, headers, development tools, and the cuBLAS, cuFFT, cuRAND, cuSOLVER,
cuSPARSE, and NVRTC libraries. It also downloads the R36.5.1
`nvidia-l4t-cuda`, `nvidia-l4t-core`, and `nvidia-l4t-3d-core` packages,
verifies their pinned SHA-256 hashes, and places their driver and PTX JIT
libraries under `/opt/debian-tegra/`. The toolkit packages are tracked by
Debian's package database; the R36 libraries are extracted separately.
The builder also selects a verified cuBLAS 12.6.0.22 runtime from a local
compatibility directory: the toolkit's newer cuBLAS 12.6.4.1 returned an
architecture mismatch on the TX1. `nvmap` loads automatically at boot.
The dynamic linker can find both `libcuda.so.1` and `libcudart.so.12`.
`nvcc` is available on the default PATH. The builder installs GCC 13 for
CUDA 12.6 and applies a four-declaration `noexcept` compatibility adjustment
to NVIDIA's CUDA header for Debian 13's glibc 2.41. It compiles a small
SM 5.3 program during the build to verify that toolchain.

The default image is 8192 MiB to fit the toolkit. Use `--no-cuda` for a
smaller image (minimum 2048 MiB). The builder uses NVIDIA's signed repository
only while building and removes its source and key from the finished image.
NVIDIA's current key uses a SHA-1 binding rejected by Debian 13's default
verifier, so the builder uses `gpgv` with the SHA-256-pinned key for that
build-time APT update. NVIDIA binaries stay in the ignored local cache or
image; this repository, CI, and the debian-tegra APT repository do not
redistribute them.

The R36.5.1 driver, CUDA 12.6 toolkit, and selected cuBLAS runtime passed
CUDA, cuBLAS, cuFFT, cuRAND, cuSOLVER, cuSPARSE, and NVRTC probes on a
physical TX1. cuDNN is a separate package and is not included.

## CUDA hardware tests

The test script uses the local SD image as a read-only ARM64 build root inside
Docker, compiles an SM 5.3 probe on the host, copies it to the TX1, and runs
the seven tests separately over SSH:

```sh
bash scripts/test-cuda.sh --target debian@jetson-tx1.local
```

Use `--image FILE` for another image, `--build-only` to compile without SSH,
or `--known-hosts FILE` to select a verified SSH host-key file. Rebuilt images
generate new SSH host keys on first boot, so verify a changed key on the serial
console before updating your known-hosts entry. The probe results are printed
individually and the script fails if any test fails. All seven probes passed
on a TX1 with the ported Host1x fence interface.

## CUDA benchmarks

```sh
bash scripts/test-cuda.sh --benchmark --seconds 15 --target debian@jetson-tx1.local
```

The table compares three runs on the same TX1 (GM20B, SM 5.3) with CUDA 12.6,
cuBLAS 12.6.0.22, and cuDNN 9.3. The first two runs used at least 15 seconds
per workload. The last used at least 5 seconds per workload and included
FP16 HGEMM. Both 1,600 MHz runs used the separate higher-rate test build
described above.

| Workload | ACTMON up to 800 MHz | Fixed 1,600 MHz | ACTMON up to 1,600 MHz |
| --- | ---: | ---: | ---: |
| CUDA 32 MiB device-to-device copy | 4.33 GB/s | 9.17 GB/s | 9.10 GB/s |
| cuBLAS 1024 × 1024 FP32 SGEMM | 302.18 GFLOP/s | 386.72 GFLOP/s | 384.66 GFLOP/s |
| cuBLAS 1024 × 1024 FP16 HGEMM | — | — | **869.52 GFLOP/s** |
| cuFFT FP32 C2C, length 4096, batch 64 | 125,650 transforms/s | 253,327 transforms/s | 251,232 transforms/s |
| cuRAND 1,048,576 uniform FP32 values | 1.84 Gvalues/s | 3.78 Gvalues/s | 3.83 Gvalues/s |
| cuSOLVER 512 × 512 FP32 Cholesky | 16.00 GFLOP/s | 22.00 GFLOP/s | 22.00 GFLOP/s |
| cuSPARSE FP32 CSR SpMV, 1,835,008 nonzeros | 0.81 Gnonzeros/s | 1.56 Gnonzeros/s | 1.56 Gnonzeros/s |
| cuDNN FP32 3 × 3 convolution, 32 input and output channels | 164.32 GFLOP/s | 166.78 GFLOP/s | 166.75 GFLOP/s |
| NVRTC SM 5.3 SAXPY compilation | 104.23 ms | 95.03 ms | 94.58 ms |

D2D throughput counts payload bytes copied. Each copy reads the payload and
writes it, so 9.17 GB/s of payload corresponds to 18.34 GB/s of effective
read-plus-write bandwidth. In the same automatic-scaling run, FP16 HGEMM
took 2.470 ms versus 5.583 ms for FP32 SGEMM, a 2.26× throughput gain.

The GPU workloads warm up and use CUDA events to time at least five batches
of 20 operations. The reported latency is the median of the per-batch
averages. NVRTC reports median host time for at least five compilations after
a warmup compile. `--seconds` repeats each workload to meet the minimum wall
time after warmup. Setup and validation are outside the reported timings.

cuDNN is optional. The benchmark uses the installed cuDNN 8 or 9 runtime
when it can load one, and skips convolution when neither is available.
The [cuDNN 9.3.0 Jetson ARM64 package][cudnn-tx1] passed the TX1 benchmark.
To try it without installing a system package, extract it on the TX1 with
`dpkg-deb -x libcudnn9-cuda-12_9.3.0.75-1_arm64.deb ~/cudnn-9.3`.
Then add `--cudnn-lib-dir /home/debian/cudnn-9.3/usr/lib/aarch64-linux-gnu`
to the benchmark command. That option makes a missing runtime an error.

[cudnn-tx1]: https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2204/arm64/libcudnn9-cuda-12_9.3.0.75-1_arm64.deb

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
