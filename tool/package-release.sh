#!/usr/bin/env bash
# Bundle server binary + web build + deploy files for the Pi:
#   dist/pi-tv-linux-arm64.tar.gz  (unpack on the Pi, then sudo ./install.sh)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
D="$ROOT/dist"
[ -x "$D/pi-tv-server-linux-arm64" ] || { echo "run tool/build-server-arm64.sh first"; exit 1; }
[ -d "$D/web" ] || { echo "run tool/build-web.sh first"; exit 1; }
STAGE="$(mktemp -d)/pi-tv"
mkdir -p "$STAGE"
cp "$D/pi-tv-server-linux-arm64" "$STAGE/"
cp -r "$D/web" "$STAGE/web"
cp "$ROOT/deploy/"{pi-tv.service,pi-tv.user.service,pi-tv.env.example,install.sh} "$STAGE/"
cp "$ROOT/docs/INSTALL.md" "$STAGE/"
tar -C "$(dirname "$STAGE")" -czf "$D/pi-tv-linux-arm64.tar.gz" pi-tv
echo "release bundle: $D/pi-tv-linux-arm64.tar.gz"
