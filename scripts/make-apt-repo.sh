#!/usr/bin/env bash
set -euo pipefail

if [[ $# != 2 ]]; then
  echo "Usage: $0 PACKAGE_DIRECTORY REPOSITORY_DIRECTORY" >&2
  exit 2
fi
packages=$(realpath "$1")
repo=$(realpath -m "$2")
test -d "$packages"
test -n "${APT_SIGNING_KEY:-}" || {
  echo 'APT_SIGNING_KEY must name an imported GPG private key' >&2
  exit 2
}
mkdir -p "$repo/pool/main" "$repo/dists/trixie/main/binary-arm64"
find "$packages" -maxdepth 1 -type f -name '*.deb' -exec cp -f {} "$repo/pool/main/" \;
test "$(find "$repo/pool/main" -maxdepth 1 -name '*.deb' | wc -l)" -eq 5
cp "$packages/SHA256SUMS" "$repo/SHA256SUMS"
cd "$repo"
dpkg-scanpackages -m pool/main /dev/null > dists/trixie/main/binary-arm64/Packages
gzip -n -9 -c dists/trixie/main/binary-arm64/Packages \
  > dists/trixie/main/binary-arm64/Packages.gz
apt-ftparchive \
  -o APT::FTPArchive::Release::Origin=debian-tegra \
  -o APT::FTPArchive::Release::Label=debian-tegra \
  -o APT::FTPArchive::Release::Suite=trixie \
  -o APT::FTPArchive::Release::Codename=trixie \
  -o APT::FTPArchive::Release::Architectures=arm64 \
  -o APT::FTPArchive::Release::Components=main \
  release dists/trixie > dists/trixie/Release
gpg --batch --yes --local-user "$APT_SIGNING_KEY" \
  --armor --detach-sign --output dists/trixie/Release.gpg dists/trixie/Release
gpg --batch --yes --local-user "$APT_SIGNING_KEY" \
  --clearsign --output dists/trixie/InRelease dists/trixie/Release
gpg --batch --export "$APT_SIGNING_KEY" > archive-keyring.gpg
touch .nojekyll
cat > index.html <<'EOF'
<!doctype html>
<html lang="en"><meta charset="utf-8"><title>debian-tegra APT repository</title>
<h1>debian-tegra APT repository</h1>
<p>Debian 13 ARM64 packages for Jetson TX1.</p>
<p><a href="archive-keyring.gpg">Archive signing key</a> ·
<a href="SHA256SUMS">Package checksums</a> ·
<a href="https://github.com/boondocklabs/debian-tegra">Source and instructions</a></p>
</html>
EOF
