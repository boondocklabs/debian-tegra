#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

bash scripts/build-kernel.sh
bash scripts/build-modules.sh nvmap
bash scripts/build-modules.sh nvgpu
bash scripts/build-device-tree.sh
