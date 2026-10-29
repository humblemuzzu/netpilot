#!/bin/bash
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "run with sudo: sudo $0"
  exit 1
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

mkdir -p /usr/local/etc/netpilot /usr/local/libexec
install -m 755 -o root -g wheel "$ROOT/daemon/netpilotd.sh" /usr/local/libexec/netpilotd
install -m 644 -o root -g wheel "$ROOT/daemon/local.netpilot.daemon.plist" \
  /Library/LaunchDaemons/local.netpilot.daemon.plist

chown root:admin /usr/local/etc/netpilot
chmod 775 /usr/local/etc/netpilot

touch /var/log/netpilot.log
chown root:wheel /var/log/netpilot.log

launchctl bootout system/local.netpilot.daemon 2>/dev/null || true
launchctl bootstrap system /Library/LaunchDaemons/local.netpilot.daemon.plist
launchctl enable system/local.netpilot.daemon

echo "helper installed."
echo "  flag dir : /usr/local/etc/netpilot"
echo "  log      : /var/log/netpilot.log"
