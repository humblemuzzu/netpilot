#!/bin/bash
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "run with sudo: sudo $0"
  exit 1
fi

launchctl bootout system/local.netpilot.daemon 2>/dev/null || true
rm -f /Library/LaunchDaemons/local.netpilot.daemon.plist
rm -f /usr/local/libexec/netpilotd
rm -f /usr/local/etc/netpilot/request.txt /usr/local/etc/netpilot/state.json
ifconfig awdl0 up 2>/dev/null || true

echo "helper removed. AWDL is back on (AirDrop works again)."
echo "left in place: /usr/local/etc/netpilot (your AWDL preference), /var/log/netpilot.log"
