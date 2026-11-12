#!/usr/bin/env bash
# Android remote -> dist/pi-tv-remote.apk (needs Android SDK + JDK 17).
# Release builds are signed with android/key.properties if present,
# otherwise with the debug key (fine for side-loading at home).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/apps/remote"
flutter build apk --release
mkdir -p "$ROOT/dist"
cp build/app/outputs/flutter-apk/app-release.apk "$ROOT/dist/pi-tv-remote.apk"
echo "apk: $ROOT/dist/pi-tv-remote.apk"
