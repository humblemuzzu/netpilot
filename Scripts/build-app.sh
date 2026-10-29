#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/NetPilot.app"

swift build -c release --package-path "$ROOT"

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/.build/release/NetPilot" "$APP/Contents/MacOS/NetPilot"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
codesign --force --sign - "$APP" >/dev/null 2>&1

echo "built: $APP"
