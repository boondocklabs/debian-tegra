# debian-tegra

Run **Debian 13 with Linux 6.12** on the NVIDIA Jetson TX1 Developer Kit or
Jetson Nano 4 GB Developer Kit. Both targets share the Tegra210 kernel and
the port of NVIDIA's `nvgpu` and `nvmap` drivers for the GM20B GPU. Each board
has a separate device-tree package and bootable SD image. CUDA 12.6 has
been tested on both boards. The Nano boots from microSD and displays the
Debian console over HDMI.

## Supported hardware and software

| Component | Supported or tested version |
| --- | --- |
| TX1 | P2371-2180 on the P2597 carrier. Boot, display, and GPU tested on hardware. |
| Jetson Nano 4 GB | P3448-0000 on the P3449 carrier (P3450-0000 board tree). MicroSD boot and HDMI console verified on hardware. |
| CPU and GPU | ARM64 Cortex-A57 and Tegra210 GM20B (Maxwell, CUDA SM 5.3) |
| Power monitoring | INA3221 hwmon. Nano monitors 5 V input, CPU, and GPU. TX1 lists the module monitor and two P2597 carrier monitors. |
| Overcurrent telemetry | jtop reads Tegra210 OC1–OC4 hardware counters through `soctherm_oc` hwmon. |
| Operating system | Debian 13 (Trixie), arm64 |
| Kernel | Linux 6.12.118, Debian package revision `6.12.118-1+tegra13` |
| Boot firmware | Jetson Linux R32.7.6 CBoot and U-Boot 2020.04, with SD boot via extlinux. TX1 boots from eMMC firmware and Nano from QSPI-NOR firmware. |
| TX1 display and peripherals | HDMI DRM, P2597 PWM fan, BCM4354 Wi-Fi and Bluetooth, optional OV5693 CSI camera |
| TX1 memory scaling | RAM code 0, ACTMON at 408–800 MHz or up to 1,600 MHz on the watchdog-guarded entry |
| Nano memory scaling | RAM code 0, watchdog-guarded ACTMON at 204 and 1,600 MHz on the default entry |
| GPU userspace tested on both boards | Experimental R36.5.1 `libcuda`, CUDA 12.6 toolkit, CUDA Runtime 12.6.77, cuBLAS 12.6.0.22 |
| Libraries and monitoring | cuDNN 9.3.0 included in CUDA-enabled SD images and tested on TX1; jtop 7.3.0 included in the SD image |

The port has been exercised on a TX1 with NVIDIA R36.5.1 `libcuda` and CUDA
12.6.77 `libcudart`: the CUDA driver API enumerated the GM20B GPU, copied
memory, JIT-loaded SM 5.3 PTX, launched a kernel, and read back its result.
The CUDA runtime also completed a memory round trip. This is an experimental
compatibility result, not NVIDIA support for TX1 on R36.5 or a claim that
every CUDA 12 release works. The CUDA results below were measured on a
physical TX1 Developer Kit. GitHub Actions verifies the package builds.

## What it builds

| Package | Contents |
| --- | --- |
| `linux-image-6.12.118-tegra-tx1` | Shared Debian 13 kernel with the Tegra210 GPU SMMU DMA patch |
| `linux-headers-6.12.118-tegra-tx1` | Matching headers for external modules |
| `debian-tegra-nvmap-tx1` | Patched NVIDIA nvmap module |
| `debian-tegra-nvgpu-tx1` | Patched NVIDIA nvgpu module for GM20B. Nano support starts with revision `6.12.118-1+tegra6`. |
| `debian-tegra-tx1-device-tree` | GPU-enabled DTB, P2597 fan, and optional OV5693 CSI and EMC overlays |
| `debian-tegra-nano-device-tree` | GPU-enabled P3450-0000 DTBs with HDMI DDC, INA3221 power monitoring, watchdog-guarded EMC, and optional IMX477 CAM0 |

The kernel comes from Debian's `6.12.118-1` source package. Its URL and
SHA-256 are pinned in [build-kernel.sh](scripts/build-kernel.sh). The
[module source commits](modules/sources.env), [kernel config](kernel/tx1-arm64.config),
[kernel patches](kernel/patches), [module patches](modules),
[fan overlay](device-tree/tx1-fan.dtso), [OV5693 overlay](device-tree/tx1-ov5693.dtso),
and [EMC overlay](device-tree/tx1-emc.dtso) are checked in. The kernel ABI
is `6.12.118-tegra-tx1`; the module and device tree packages depend on that
exact kernel version. The kernel ABI and shared package names retain their
original `tx1` suffix on both boards.

The compact TX1 config removes Nouveau, other unused SoC families, DVB/radio, and legacy
network and USB serial drivers while retaining KVM/virtio and common USB and
PCIe storage, network, audio, and input support as modules. USB UVC, Tegra
VI, and OV5693/IMX219 camera sensor drivers remain modules. The device tree
package includes an optional OV5693 overlay for the P2597 front camera; its
boot menu entry selects that DTB while the default keeps camera probing off.
Tegra `host1x`, DRM display, I2C, and display regulators are built in so the HDMI
framebuffer console can appear during kernel initialization. NVIDIA `nvgpu`
and `nvmap` remain separate upgradeable module packages; early display does
not require the compute GPU driver. The build uses `-mtune=cortex-a57`. The kernel, HDMI DRM connector,
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

The SD boot menu includes **ACTMON up to 1600 MHz** as an opt-in entry.
It uses the MAX77620 hardware watchdog with a 64-second timeout and loads
ACTMON only after the watchdog arms and the 1,600 MHz timing is available.
The existing GPU entry remains the image default when firmware is included.

Both EMC device trees require RAM code 0 and the P2371-2180 CBoot handoff
at `0x83100000`. ACTMON uses LPDDR4 timings that CBoot trains on each boot.
The `-emc.dtb` covers 408, 665.6, and 800 MHz. The `-emc-1600.dtb` adds
1,065.6, 1,331.2, and 1,600 MHz.

The 408–800 MHz range passed the 15-second CUDA suite and a 128 MiB RAM
integrity test on one TX1. Each higher rate passed a 32 MiB RAM test.
All 1,314 samples during the fixed-rate benchmark measured 1,600 MHz.
With automatic scaling, EMC reached 1,600 MHz in 150 of 153 samples during
a 15-second CUDA copy and returned to 408 MHz about 1.5 seconds after load
ended. The known-good OV5693 entry was the default on the test board.

For an existing installation, copy
`tegra210-p2371-2180-nvgpu-fan-ov5693-emc-1600.dtb` from
`/usr/lib/linux-image-6.12.118-tegra-tx1/nvidia/` to `/boot/`.
Duplicate the known-good entry in `/boot/extlinux/extlinux.conf` with a
unique label, point its `FDT` line to the new DTB, and append
`debian_tegra.emc_1600=1 modprobe.blacklist=tegra30_devfreq` to that
entry's `APPEND` line. If the line already has a module blacklist, add
`tegra30_devfreq` to its comma-separated list. Keep the existing `DEFAULT`.

After boot, use these commands to read
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
It uploads individual job artifacts and a combined six-package artifact.
The kernel source is compiled in a case-sensitive Docker volume so the local
build also works from a macOS checkout.
Pushes and pull requests run this build only when build inputs or the build
workflow change. README and APT publishing changes do not rebuild packages;
the build can still be started manually from GitHub Actions.

The device-tree packages install their DTBs under
`/usr/lib/linux-image-6.12.118-tegra-tx1/nvidia/`. Select the matching board
DTB in the bootloader configuration.

## Expansion header interfaces

The shared kernel includes Tegra210 pinctrl and the GPIO character-device
interface (`/dev/gpiochip*`), plus Tegra SPI, I²C, UART, and PWM support.
The Tegra210 I²S modules include the audio hub, DMA interface, and graph-card
driver. The Nano 4 GB expansion header exposes SPI1 (`spi@7000d400`),
SPI2 (`spi@7000d600`), and I²S4 (`i2s@702d1300`). Set the pin functions
and describe the SPI device or I²S codec in a device tree for your carrier
and peripheral. For raw SPI access, bind `spidev` to the configured SPI
device using its device ID or the kernel's `driver_override` interface.

External GPIO-controlled switches can use the Linux `gpio-mux` binding with
the generic SPI or I²C mux driver. The Nano camera’s I²C mux uses its own
`i2c-mux-gpio` binding.

## Bootable SD images

Choose the board with `--target` when you build the image. Use the generated
image for that board when writing the SD card.

| Board | Builder option | Output image |
| --- | --- | --- |
| Jetson TX1 Developer Kit | `--target tx1` (default) | `out/debian-tegra-tx1-sd.img` |
| Jetson Nano 4 GB Developer Kit (P3448-0000) | `--target nano` | `out/debian-tegra-nano-sd.img` |

The Nano option is for the 4 GB microSD developer kit. Follow the boot
firmware and writing instructions for the selected board below.

### Jetson TX1

With Docker on an ARM64 host, build a 10 GiB Debian 13 SD image using the five
version-pinned packages from the signed APT repository:

```sh
bash scripts/create-sd-image.sh --target tx1 --authorized-keys ~/.ssh/id_ed25519.pub
```

To test newly built packages before repository publication, run
`bash scripts/build-all.sh` and pass `--local-packages out` to the image
builder. The image still gets Debian base packages from Debian's mirror.

The output is `out/debian-tegra-tx1-sd.img` with a SHA-256 file beside it. Use
`--size-mib` for a larger card, `--output` for another filename, and `--force`
to replace an existing output. Use a 16 GB or larger SD card for the default
10 GiB image. The builder uses privileged Docker for its debootstrap chroot
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

### Jetson Nano 4 GB

Build a microSD image for the Jetson Nano 4 GB Developer Kit (P3448-0000
module, P3449 carrier). The board needs the [Jetson Linux R32.7.6 QSPI boot
firmware][nano-bsp] in place. NVIDIA moved the boot chain to QSPI starting in
R32.5. For boards on older firmware, use NVIDIA's
[`jetson-nano-qspi` flashing configuration][nano-qspi] before trying this
image. The Debian image contains one GPT ext4 partition and the U-Boot
extlinux menu.

```sh
bash scripts/create-sd-image.sh --target nano --authorized-keys ~/.ssh/id_ed25519.pub
```

This writes `out/debian-tegra-nano-sd.img` and its SHA-256 file. Use the
same macOS write commands above with the Nano filename. The builder
installs the shared kernel, nvmap, and nvgpu packages along with the Nano
DTB. It adds NVIDIA GM20B and Tegra210 firmware from the R32.7.6 BSP and
Debian's `firmware-realtek` for wired Ethernet and `firmware-iwlwifi` with
`wireless-regdb` for Intel Wi-Fi and Bluetooth cards such as the 8265. With
an Ethernet connection, use `ssh debian@jetson-nano.local`.

The Nano device-tree package keeps GPIO PA6
asserted to power the HDMI DDC level shifter after CBoot hands off to Linux.
When updating an existing SD image, reboot after the package refreshes
the DTB in `/boot`.

The default Nano EMC entry leaves GPU loading manual.
With firmware installed, select **GPU enabled** in the U-Boot menu, or
run `sudo modprobe nvgpu` after Debian starts. The shared nvgpu module caps
the Nano GPU at 921.6 MHz. The image includes CUDA 12.6, R36.5.1 GPU
userspace, and cuDNN 9.3.0 by default. On the Nano, an on-device SM 5.3
compilation and all seven CUDA library probes passed. The Nano benchmark
results are included [below](#cuda-benchmarks). For a smaller initial boot
image, add `--no-cuda --size-mib 2048`. To use unpublished packages from a
local build, add `--local-packages out`.

#### Nano CAM0 with Arducam UC-698

Connect the UC-698 IMX477 to CAM0 on the P3449 B01 carrier with the
appropriate 15-pin-to-22-pin CSI cable while the Nano is powered down.
Select **Nano EMC + CAM0 IMX477** in the U-Boot menu. The entry uses CSI-A
and the first channel of the carrier's camera I²C mux. Debian exposes raw
Bayer capture through V4L2.
The camera entry reserves 192 MiB of contiguous DMA memory for capture.

On an existing image, the matching DTB is
`tegra210-p3450-0000-nvgpu-emc-cam0-imx477.dtb` under the kernel DTB
directory. Copy it to `/boot` and use it as the `FDT` in a copy of the
Nano EMC boot entry. Add `cma=192M` to that entry’s `APPEND` line.
Use `media-ctl -p` from `v4l-utils` to inspect the camera pipeline. On the
test Nano, the UC-698 captured 2028×1080 RAW10 and 4056×3040 RAW12 through
`/dev/video0`. To test full-resolution capture:

```sh
v4l2-ctl -d /dev/video0 --set-fmt-video=width=4056,height=3040,pixelformat=RG12 \
  --stream-mmap=4 --stream-count=6 --stream-to=/dev/null
```

For 30 or 60 fps on the tested Nano, use 8-bit Bayer (`RGGB`). Apply
the `vertical_blanking` control after selecting the capture format.

| Capture mode | `vertical_blanking` for 30 fps | `vertical_blanking` for 60 fps |
| --- | ---: | ---: |
| 2028×1080 RAW8 | 2389 | 655 |
| 2028×1520 RAW8 | 1949 | 215 |

Both rates passed frame capture in these modes. RAW10 reached 30 and
60 fps at 2028×1080 in short tests, with intermittent frame errors in
longer runs. Full-resolution RAW12 captured at about 10 fps.

#### Nano power and overcurrent monitoring

The onboard INA3221 exposes voltage and current for the 5 V input, GPU,
and CPU through `hwmon`. The device tree uses the rail order for the
P3448-0000 production revision used on the test board. The shared kernel
also exposes the Tegra210 OC1–OC4 hardware event counts through
`soctherm_oc`. jtop 7.3.0 found all four counters on the Nano in its
**SYSFS** page. All four read zero during the check.

#### Nano EMC and ACTMON

The **Nano EMC up to 1600 MHz** entry is the default on the Nano SD image.
It uses the RAM-code-0 Jetson Linux R32.7.6 CBoot handoff for the 4 GB kit. The kernel uses
the Nano's 204 MHz and trained 1,600 MHz timings from its own CBoot DTB. The
boot service arms the 64-second MAX77620 watchdog and checks both rates
before loading ACTMON. **Manual GPU load** provides a recovery entry with
the standard device tree.

On a P3448-0000/P3449 B01 kit, a 20-second, four-thread memory test reached
1,600 MHz in 198 of 199 samples and first returned to 204 MHz 1.91 seconds
after load ended. All 1,243 32 MiB copies passed comparison.

For an existing installation, use the updated kernel and Nano DTB packages.
Copy `tegra210-p3450-0000-nvgpu-emc.dtb` from the packaged kernel DTB directory
to `/boot` and duplicate the standard extlinux entry with a unique label.
Set the new entry's `FDT` to that file, add `tegra30_devfreq` to its existing
`modprobe.blacklist` list, and append `debian_tegra.nano_emc=1`. Select the new
entry at boot, or set the extlinux `DEFAULT` to its label.

[nano-bsp]: https://developer.nvidia.com/embedded/linux-tegra-r3276
[nano-qspi]: https://docs.nvidia.com/jetson/archives/l4t-archived/l4t-3275/Tegra%20Linux%20Driver%20Package%20Development%20Guide/adaptation_and_bringup_nano.html

## CUDA userspace

By default, the SD image builder installs NVIDIA's full ARM64 Jetson
`cuda-toolkit-12-6` package set from NVIDIA's CUDA repository. This includes
`nvcc`, headers, development tools, and the cuBLAS, cuFFT, cuRAND, cuSOLVER,
cuSPARSE, and NVRTC libraries. The builder also installs the cuDNN 9.3.0
runtime (`libcudnn9-cuda-12=9.3.0.75-1`), the version tested on both boards.
It downloads the R36.5.1
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

The default image is 10240 MiB to fit the toolkit and cuDNN. With
`--no-cuda`, the builder skips both and defaults to 8192 MiB, with a
minimum of 2048 MiB. The builder uses NVIDIA's signed repository
only while building and removes its source and key from the finished image.
NVIDIA's current key uses a SHA-1 binding rejected by Debian 13's default
verifier, so the builder uses `gpgv` with the SHA-256-pinned key for that
build-time APT update. NVIDIA binaries stay in the ignored local cache or
image; this repository, CI, and the debian-tegra APT repository do not
redistribute them.

The R36.5.1 driver, CUDA 12.6 toolkit, and selected cuBLAS runtime passed
CUDA, cuBLAS, cuFFT, cuRAND, cuSOLVER, cuSPARSE, and NVRTC probes on
both development kits.

## CUDA hardware tests

The test script uses the local SD image as a read-only ARM64 build root inside
Docker, compiles an SM 5.3 probe on the host, copies it to the board, and
runs the seven tests separately over SSH.

```sh
bash scripts/test-cuda.sh --target debian@jetson-tx1.local
bash scripts/test-cuda.sh --image out/debian-tegra-nano-sd.img --target debian@jetson-nano.local
```

Use `--image FILE` for another image, `--build-only` to compile without SSH,
or `--known-hosts FILE` to select a verified SSH host-key file. Rebuilt images
generate new SSH host keys on first boot, so verify a changed key on the serial
console before updating your known-hosts entry. The probe results are printed
individually and the script fails if any test fails.

## CUDA benchmarks

```sh
bash scripts/test-cuda.sh --benchmark --seconds 15 --target debian@jetson-tx1.local
```

The benchmarks used CUDA 12.6, cuBLAS 12.6.0.22, and cuDNN 9.3. The
first two TX1 runs used at least 15 seconds per workload. The final TX1
run used at least 5 seconds per workload and included FP16 HGEMM. Both
TX1 runs at 1,600 MHz used the development build that validated the opt-in
configuration. The Nano run used at least 15 seconds per workload with
its default ACTMON entry and the GPU scaling up to 921.6 MHz. EMC stayed
at 1,600 MHz during the sustained run and was back at 204 MHz after three
seconds idle.

| Workload | TX1 ACTMON up to 800 MHz | TX1 fixed 1,600 MHz | TX1 ACTMON up to 1,600 MHz | Nano ACTMON up to 1,600 MHz | TX1 cuDNN rerun at 1,600 MHz EMC |
| --- | ---: | ---: | ---: | ---: | ---: |
| CUDA 32 MiB device-to-device copy | 4.33 GB/s | 9.17 GB/s | 9.10 GB/s | 8.62 GB/s | — |
| cuBLAS 1024 × 1024 FP32 SGEMM | 302.18 GFLOP/s | 386.72 GFLOP/s | 384.66 GFLOP/s | 180.04 GFLOP/s | — |
| cuBLAS 1024 × 1024 FP16 HGEMM | — | — | **869.52 GFLOP/s** | 407.93 GFLOP/s | — |
| cuFFT FP32 C2C, length 4096, batch 64 | 125,650 transforms/s | 253,327 transforms/s | 251,232 transforms/s | 174,866 transforms/s | — |
| cuRAND 1,048,576 uniform FP32 values | 1.84 Gvalues/s | 3.78 Gvalues/s | 3.83 Gvalues/s | 3.94 Gvalues/s | — |
| cuSOLVER 512 × 512 FP32 Cholesky | 16.00 GFLOP/s | 22.00 GFLOP/s | 22.00 GFLOP/s | 17.90 GFLOP/s | — |
| cuSPARSE FP32 CSR SpMV, 1,835,008 nonzeros | 0.81 Gnonzeros/s | 1.56 Gnonzeros/s | 1.56 Gnonzeros/s | 1.18 Gnonzeros/s | — |
| cuDNN FP32 3 × 3 convolution, 32 input and output channels | 164.32 GFLOP/s | 166.78 GFLOP/s | 166.75 GFLOP/s | 80.22 GFLOP/s | 60.85 GFLOP/s |
| cuDNN FP16 3 × 3 convolution, 32 input and output channels | — | — | — | 50.30 GFLOP/s | 29.07 GFLOP/s |
| NVRTC SM 5.3 SAXPY compilation | 104.23 ms | 95.03 ms | 94.58 ms | 99.27 ms | — |

D2D throughput counts payload bytes copied. Each copy reads the payload and
writes it, so 9.17 GB/s of payload corresponds to 18.34 GB/s of effective
read-plus-write bandwidth. In the same automatic-scaling run, FP16 HGEMM
took 2.470 ms versus 5.583 ms for FP32 SGEMM, a 2.26× throughput gain.

The Nano FP16 result comes from a five-second run that measured 0.883 ms
for FP32 and 1.409 ms for FP16. The TX1 rerun used 15 seconds per workload
with ACTMON and measured 1.164 ms for FP32 and 2.437 ms for FP16. All 75
clock samples in each TX1 convolution pass showed a 998.4 MHz GPU clock
and 1,600 MHz EMC. Both boards used the same NCHW input (1 × 32 × 64 × 64),
32 filters of size 3 × 3, and implicit GEMM. The benchmark checks every
output element and uses FP16 tensors and accumulation for the FP16 case.

The GPU workloads warm up and use CUDA events to time at least five batches
of 20 operations. The reported latency is the median of the per-batch
averages. NVRTC reports median host time for at least five compilations after
a warmup compile. `--seconds` repeats each workload to meet the minimum wall
time after warmup. Setup and validation are outside the reported timings.

The benchmark uses the installed cuDNN 8 or 9 runtime and skips convolution
when neither is available. The default SD image provides the
[cuDNN 9.3.0 Jetson ARM64 package][cudnn-tx1] that passed the TX1 benchmark.
On an older CUDA-enabled image, you can extract the runtime locally with
`dpkg-deb -x libcudnn9-cuda-12_9.3.0.75-1_arm64.deb ~/cudnn-9.3`.
Then add `--cudnn-lib-dir /home/debian/cudnn-9.3/usr/lib/aarch64-linux-gnu`
to the benchmark command. That option makes a missing runtime an error.

[cudnn-tx1]: https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2204/arm64/libcudnn9-cuda-12_9.3.0.75-1_arm64.deb

## APT repository

The signed Debian 13 ARM64 repository at
<https://boondocklabs.github.io/debian-tegra/> provides the shared Tegra210 kernel image,
headers, nvmap, and nvgpu, plus separate TX1 and Nano device-tree packages. The SD image builder adds
this source and installs the pinned package versions for you.

The archive key fingerprint is
`0F24 8B4E 0026 1A42 AC3E CC19 C078 7BB2 FD9D 04B6`.
On a Debian 13 Jetson system, add the repository and packages. The example
uses `debian-tegra-tx1-device-tree`. For the Nano, use
`debian-tegra-nano-device-tree` in the install command.

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
