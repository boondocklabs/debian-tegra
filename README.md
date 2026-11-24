# debian-tegra

Build Debian 13 ARM64 packages for the NVIDIA Jetson TX1 Developer Kit
(P2371-2180 module on the P2597 carrier). GitHub Actions builds and uploads
five `.deb` files: a patched kernel, matching headers, the nvmap and nvgpu
modules, and GPU/fan device trees.

The kernel is based on Debian's `6.12.118-1` source package. Its URL and
SHA-256 are pinned in [build-kernel.sh](scripts/build-kernel.sh); NVIDIA module
repositories and commits are pinned in [sources.env](modules/sources.env).
The checked-in [kernel config](kernel/tx1-arm64.config), [kernel patch](kernel/patches/0001-tegra210-gpu-dma-domain.patch),
[module patches](modules), and [fan overlay](device-tree/tx1-fan.dtso) are the
complete target-specific source changes. The kernel ABI is
`6.12.118-tegra-tx1`.

## Build

Run with Docker and ARM64 support:

```sh
bash scripts/build-all.sh
```

The resulting `.deb` files and `SHA256SUMS` are in `out/`. The same command
runs in [GitHub Actions](.github/workflows/build.yml) on an ARM64 runner.
The packages are versioned and have exact kernel ABI dependencies so a future
kernel revision can be published with matching module and device tree
packages. The kernel build uses a temporary case-sensitive Docker volume to
support macOS hosts.

The device tree package installs GPU-enabled and fan-enabled DTBs under
`/usr/lib/linux-image-6.12.118-tegra-tx1/nvidia/`. Select the appropriate
DTB in the board's bootloader configuration. The packages do not change the
bootloader or create an SD image.

The nvgpu port is experimental. This repository does not include NVIDIA
firmware, CUDA userspace, graphics libraries, board provisioning, or
application scripts. The workflow uploads build artifacts only; it does not
publish an APT repository or push to another repository.
