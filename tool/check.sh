#!/usr/bin/env bash
# Analyze + test every package. Usage: tool/check.sh [--no-remote]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
for pkg in packages/pi_tv_shared apps/server; do
  echo "== $pkg"
  (cd "$ROOT/$pkg" && dart pub get >/dev/null && dart format --output=none --set-exit-if-changed . && dart analyze --fatal-infos && dart test)
done
if [ "${1:-}" != "--no-remote" ]; then
  echo "== apps/remote"
  (cd "$ROOT/apps/remote" && flutter pub get >/dev/null && dart format --output=none --set-exit-if-changed lib test && flutter analyze --fatal-infos && flutter test)
fi
echo "all checks passed"
