#!/usr/bin/env bash
# Cross-compile pi-tv-server for the Pi INSIDE a Debian 13 (Trixie)
# linux/arm64 container (qemu-user-static on x86_64 hosts).
#
#   tool/build-server-arm64.sh            -> dist/pi-tv-server-linux-arm64
#
# Needs podman or docker with arm64 emulation (binfmt qemu-aarch64).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENGINE="${ENGINE:-$(command -v podman || command -v docker)}"
IMAGE="${IMAGE:-pi-tv-builder-trixie-arm64}"
DART_VERSION="${DART_VERSION:-3.13.7}"
OUT="$ROOT/dist"
mkdir -p "$OUT"

if ! "$ENGINE" image exists "$IMAGE" 2>/dev/null && ! "$ENGINE" image inspect "$IMAGE" >/dev/null 2>&1; then
  "$ENGINE" build --platform linux/arm64 --build-arg DART_VERSION="$DART_VERSION" \
    -t "$IMAGE" -f "$ROOT/tool/Containerfile.arm64" "$ROOT/tool"
fi

# The repo is mounted read-only and copied, so the host's .dart_tool is untouched.
"$ENGINE" run --rm --platform linux/arm64 \
  -v "$ROOT:/src:ro" -v "$OUT:/out" "$IMAGE" bash -euo pipefail -c '
    echo "container: $(uname -m), $(ldd --version | head -1)"
    mkdir -p /build && cd /build
    cp -r /src/packages /src/apps . && rm -rf apps/remote
    find . -name .dart_tool -prune -exec rm -rf {} +
    cd apps/server
    dart pub get
    dart compile exe bin/pi_tv_server.dart --target-os=linux --target-arch=arm64 \
      -o /out/pi-tv-server-linux-arm64
    /out/pi-tv-server-linux-arm64 --version
    file_info=$(od -An -tx1 -N20 /out/pi-tv-server-linux-arm64 | tr -d " \n")
    echo "ELF header: $file_info"
  '
ls -l "$OUT/pi-tv-server-linux-arm64"
