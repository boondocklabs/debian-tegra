#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ ${1:-} == --container ]]; then
  [[ $EUID == 0 && $(uname -m) == aarch64 ]] || {
    echo '--container requires the ARM64 Docker builder' >&2; exit 2;
  }
  work=/project/out/cuda-tests
  mkdir -p "$work" /mnt/tegra-image
  cp /project/tests/cuda/probes.cu "$work/probes.cu"
  loop=$(losetup --find --show --read-only -o 1048576 /input/sd.img)
  image_mounted=0 work_mounted=0 dev_mounted=0 proc_mounted=0
  cleanup() {
    if [[ $dev_mounted == 1 ]]; then umount -R /mnt/tegra-image/dev; fi
    if [[ $proc_mounted == 1 ]]; then umount /mnt/tegra-image/proc; fi
    if [[ $work_mounted == 1 ]]; then umount /mnt/tegra-image/tmp; fi
    if [[ $image_mounted == 1 ]]; then umount /mnt/tegra-image; fi
    losetup -d "$loop"
  }
  trap cleanup EXIT
  mount -o ro "$loop" /mnt/tegra-image
  image_mounted=1
  mount --bind "$work" /mnt/tegra-image/tmp
  work_mounted=1
  mount --rbind /dev /mnt/tegra-image/dev
  mount --make-rslave /mnt/tegra-image/dev
  dev_mounted=1
  mount -t proc proc /mnt/tegra-image/proc
  proc_mounted=1
  chroot /mnt/tegra-image /usr/local/bin/nvcc -O2 -std=c++17 \
    -gencode arch=compute_53,code=sm_53 -cudart shared \
    /tmp/probes.cu -o /tmp/cuda-probes \
    -L/usr/local/cuda-12.6/targets/aarch64-linux/lib \
    -L/usr/local/cuda-12.6/targets/aarch64-linux/lib/stubs \
    -lcublas -lcufft -lcurand -lcusolver -lcusparse -lnvrtc -lcuda -ldl
  test -s "$work/cuda-probes"
  echo "Built $work/cuda-probes"
  exit 0
fi

usage() {
  cat <<'EOF'
Usage: scripts/test-cuda.sh [options]

Build ARM64 CUDA probes on this host using a local TX1 SD image, then copy
and run them over SSH on the TX1.

Options:
  --image FILE        SD image with the full CUDA toolkit
                      (default: out/debian-tegra-tx1-sd.img)
  --target USER@HOST  SSH target (default: debian@jetson-tx1.local)
  --known-hosts FILE  Use a specified SSH known_hosts file
  --benchmark         Run the CUDA benchmarks instead of the seven probes
  --seconds N         Minimum seconds per benchmark workload (default: 0)
  --cudnn-lib-dir DIR  Require cuDNN and search this library directory on the TX1
  --build-only        Compile without copying or running
EOF
}

image=out/debian-tegra-tx1-sd.img
target=debian@jetson-tx1.local
known_hosts= build_only=0 benchmark=0 seconds= cudnn_lib_dir=
while (($#)); do
  case $1 in
    --image) image=${2:?missing image}; shift 2 ;;
    --target) target=${2:?missing target}; shift 2 ;;
    --known-hosts) known_hosts=${2:?missing known_hosts file}; shift 2 ;;
    --benchmark) benchmark=1; shift ;;
    --cudnn-lib-dir) cudnn_lib_dir=${2:?missing cuDNN library directory}; shift 2 ;;
    --seconds) seconds=${2:?missing benchmark seconds}; shift 2 ;;
    --build-only) build_only=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done
if [[ -n $seconds ]]; then
  [[ $benchmark == 1 && $seconds =~ ^(0|[1-9][0-9]{0,3})$ ]] &&
    ((seconds <= 3600)) || {
      echo '--seconds requires --benchmark and an integer from 0 to 3600' >&2
      exit 2
    }
fi
if [[ -n $cudnn_lib_dir && ( $benchmark != 1 || $cudnn_lib_dir != /* || $cudnn_lib_dir == *:* ) ]]; then
  echo '--cudnn-lib-dir requires --benchmark and an absolute directory on the TX1' >&2
  exit 2
fi
[[ -s $image ]] || { echo "Missing SD image: $image" >&2; exit 2; }
image=$(realpath "$image")
ssh_options=(-o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=10)
if [[ -n $known_hosts ]]; then
  [[ -s $known_hosts ]] || { echo "Missing known_hosts file: $known_hosts" >&2; exit 2; }
  ssh_options+=(-o "UserKnownHostsFile=$(realpath "$known_hosts")")
fi
mkdir -p out/cuda-tests
docker build --platform linux/arm64 -f Containerfile.sd -t debian-tegra-sd-builder .
docker run --rm --privileged --platform linux/arm64 \
  --mount "type=bind,source=$(pwd),target=/project" \
  --mount "type=bind,source=$image,target=/input/sd.img,readonly" \
  debian-tegra-sd-builder bash /project/scripts/test-cuda.sh --container
if [[ $build_only == 1 ]]; then exit 0; fi

remote_dir=/tmp/debian-tegra-cuda-tests
ssh "${ssh_options[@]}" "$target" "install -d -m 700 $remote_dir"
scp "${ssh_options[@]}" out/cuda-tests/cuda-probes \
  "$target:$remote_dir/cuda-probes"

if [[ $benchmark == 1 ]]; then
  benchmark_command="$remote_dir/cuda-probes benchmark ${seconds:-0}"
  if [[ -n $cudnn_lib_dir ]]; then
    printf -v cudnn_arg '%q' "LD_LIBRARY_PATH=$cudnn_lib_dir"
    benchmark_command="env $cudnn_arg DEBIAN_TEGRA_REQUIRE_CUDNN=1 $benchmark_command"
  fi
  exec ssh "${ssh_options[@]}" "$target" "$benchmark_command"
fi

failed=0
for probe in cuda cublas cufft curand cusolver cusparse nvrtc; do
  printf '\n=== %s ===\n' "$probe"
  if ssh "${ssh_options[@]}" "$target" "$remote_dir/cuda-probes $probe"; then
    :
  else
    printf 'FAIL %s\n' "$probe" >&2
    failed=$((failed + 1))
  fi
done
printf '\nCUDA probes: %d passed, %d failed\n' "$((7 - failed))" "$failed"
((failed == 0))
