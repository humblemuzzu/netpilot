#!/bin/bash
# Regenerates Resources/AppIcon.icns from the vector drawing in make-icon.swift.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"

swift "$ROOT/Scripts/make-icon.swift" "$WORK/AppIcon.iconset"
iconutil -c icns "$WORK/AppIcon.iconset" -o "$ROOT/Resources/AppIcon.icns"

echo "wrote $ROOT/Resources/AppIcon.icns"
