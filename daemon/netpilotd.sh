#!/bin/bash
# netpilotd — root helper for the NetPilot menu bar app.
#
# Two jobs, both deliberately small enough to audit in one sitting:
#   1. While the flag file exists, keep AWDL (AirDrop's radio) down.
#      macOS brings it back on reconnect, sleep/wake and Handoff activity.
#   2. Run queued requests from the app: join a Wi-Fi network using the
#      password macOS already stored, or reorder network services.

set -u

DIR=/usr/local/etc/netpilot
FLAG="$DIR/awdl_off"
REQ="$DIR/request.txt"
LOG=/var/log/netpilot.log
LAST=""
WIFI_DEVICE=$(
  /usr/sbin/networksetup -listallhardwareports 2>/dev/null |
    /usr/bin/awk '/Hardware Port: Wi-Fi/{f=1} f && /Device:/{print $2; exit}'
)
[ -n "$WIFI_DEVICE" ] || WIFI_DEVICE=en0

log() { printf '%s %s\n' "$(/bin/date '+%Y-%m-%dT%H:%M:%S')" "$*" >>"$LOG"; }

enforce_awdl() {
  [ -e "$FLAG" ] || return 0
  for iface in awdl0 llw0; do
    /sbin/ifconfig "$iface" >/dev/null 2>&1 || continue
    if /sbin/ifconfig "$iface" | /usr/bin/grep -q 'flags=.*UP'; then
      /sbin/ifconfig "$iface" down && log "awdl: lowered $iface"
    fi
  done
}

enabled_services() {
  /usr/sbin/networksetup -listallnetworkservices 2>/dev/null |
    /usr/bin/grep -v '^\*' |
    /usr/bin/grep -v 'denotes' |
    /usr/bin/grep -v '^$'
}

apply_order() {
  local -a wanted=()
  local s
  for s in "$@"; do wanted+=("$s"); done
  local -a all=("${wanted[@]}")
  while IFS= read -r s; do
    local skip=0
    for w in "${wanted[@]}"; do [ "$s" = "$w" ] && skip=1; done
    [ "$skip" -eq 0 ] && all+=("$s")
  done < <(enabled_services)
  if [ "${#all[@]}" -lt 2 ]; then
    echo "order:not-enough-services"
    return
  fi
  /usr/sbin/networksetup -ordernetworkservices "${all[@]}" >/dev/null 2>&1
  echo "order:${all[*]}"
}

handle_request() {
  [ -f "$REQ" ] || return 0
  local id="" action="" ssid="" device="$WIFI_DEVICE"
  local -a services=()
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    local key="${line%% *}" val="${line#* }"
    [ "$key" = "$line" ] && continue
    case "$key" in
      id) id="$val" ;;
      action) action="$val" ;;
      ssid) ssid="$val" ;;
      device) device="$val" ;;
      service) services+=("$val") ;;
    esac
  done <"$REQ"

  [ -n "$id" ] || return 0
  [ "$id" = "$LAST" ] && return 0
  LAST="$id"

  local result="unknown:$action"
  case "$action" in
    join)
      [ -n "$ssid" ] || { result="join:no-ssid"; }
      if [ -n "$ssid" ]; then
        local pass code
        pass=$(/usr/bin/security find-generic-password -wa "$ssid" -D 'AirPort network password' 2>/dev/null)
        if [ -n "$pass" ]; then
          /usr/sbin/networksetup -setairportnetwork "$device" "$ssid" "$pass" >/dev/null 2>&1
          code=$?
        else
          /usr/sbin/networksetup -setairportnetwork "$device" "$ssid" >/dev/null 2>&1
          code=$?
        fi
        result="join:$ssid:$code"
      fi
      ;;
    order)
      result=$(apply_order "${services[@]}")
      ;;
    awdl-off)
      /bin/mkdir -p "$DIR"
      /usr/bin/touch "$FLAG"
      enforce_awdl
      result="awdl:off"
      ;;
    awdl-on)
      /bin/rm -f "$FLAG"
      /sbin/ifconfig awdl0 up 2>/dev/null
      result="awdl:on"
      ;;
  esac

  log "request $id -> $result"
}

log "netpilotd start (wifi=$WIFI_DEVICE)"
while true; do
  enforce_awdl
  handle_request
  sleep 2
done
