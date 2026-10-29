#!/bin/bash
# Builds NetPilot, installs it to /Applications and starts it at login.
# Runs as your user; the root helper is installed separately by install-daemon.sh.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="/Applications"
AGENT_LABEL="local.netpilot.app"
AGENT_PLIST="$HOME/Library/LaunchAgents/$AGENT_LABEL.plist"

"$ROOT/Scripts/build-app.sh"

mkdir -p "$APP_DIR" "$HOME/Library/LaunchAgents"
pkill -x NetPilot 2>/dev/null || true
ditto "$ROOT/build/NetPilot.app" "$APP_DIR/NetPilot.app"

sed "s|__APP_BINARY__|$APP_DIR/NetPilot.app/Contents/MacOS/NetPilot|" \
  "$ROOT/Resources/$AGENT_LABEL.plist" >"$AGENT_PLIST"

launchctl bootout "gui/$(id -u)/$AGENT_LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$AGENT_PLIST"

echo "installed: $APP_DIR/NetPilot.app (starts at login)"
