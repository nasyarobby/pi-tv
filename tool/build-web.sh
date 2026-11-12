#!/usr/bin/env bash
# Flutter web remote -> dist/web (served by the server from WEB_DIR).
# Web resources (CanvasKit) are bundled so the remote works without internet.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/apps/remote"
flutter build web --release --no-web-resources-cdn
rm -rf "$ROOT/dist/web" && mkdir -p "$ROOT/dist" && cp -r build/web "$ROOT/dist/web"
echo "web build: $ROOT/dist/web"
