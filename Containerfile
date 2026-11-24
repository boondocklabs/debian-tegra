FROM debian:trixie-slim@sha256:a72b4433de1cf7d6bae0c4cee74d0547f58601a643b3375f070c51600d63b6b2
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y \
    --no-install-recommends ca-certificates curl git xz-utils build-essential \
    bc flex bison libssl-dev libelf-dev dwarves cpio rsync dpkg-dev python3 file \
    fakeroot debhelper kmod zstd device-tree-compiler binutils-aarch64-linux-gnu \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /project
