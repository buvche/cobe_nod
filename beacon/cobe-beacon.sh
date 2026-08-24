#!/usr/bin/env bash
#
# cobe-beacon.sh — runs ON a СЛОБО node; announces the node to the collector.
#
# The problem it solves: this node gets its address by DHCP, and the address
# moves. It moved once already when the board was put on a USB ethernet
# adapter — different MAC, new lease, and the node was simply lost until
# someone swept the subnet. A node that announces itself cannot be lost.
#
# Two independent channels, because each fails in a different way:
#
#   1. HTTP push to the collector. Active, carries full state (temps, load,
#      models, disk), but needs the collector to be up.
#   2. mDNS via avahi. Passive, no collector required, always resolvable on
#      the LAN as <hostname>.local — but tells you only where, not how.
#
# Run from cobe-beacon.service on boot and cobe-beacon.timer thereafter.
# NEVER fails hard: a node must not be held back by an unreachable collector.
#
set -uo pipefail

BEACON_URL="${BEACON_URL:-}"
STATE_DIR="/var/lib/cobe-nod"
LAST="${STATE_DIR}/beacon-last.json"
CONF="/etc/cobe-nod/beacon.conf"
PORT="${OLLAMA_PORT:-11434}"

[[ -r "$CONF" ]] && . "$CONF"
[[ -n "$BEACON_URL" ]] || { echo "no BEACON_URL configured; mDNS only"; }

mkdir -p "$STATE_DIR"

read_t() { local f="$1"; [[ -r "$f" ]] && echo $(( $(cat "$f") / 1000 )) || echo 0; }

collect() {
  local board="unknown"
  for f in /proc/device-tree/model /sys/firmware/devicetree/base/model; do
    [[ -r "$f" ]] && { board="$(tr -d '\0' < "$f")"; break; }
  done

  local iface ip
  iface="$(ip -4 -o route get 1.1.1.1 2>/dev/null | sed -n 's/.* dev \([^ ]*\).*/\1/p')"
  ip="$(ip -4 -o route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([^ ]*\).*/\1/p')"
  local mac=""
  [[ -n "$iface" && -r "/sys/class/net/${iface}/address" ]] && mac="$(cat "/sys/class/net/${iface}/address")"

  # every address, not just the primary — the whole point is to be findable
  local all_ips
  all_ips="$(ip -4 -o addr show scope global 2>/dev/null | awk '{printf "%s%s", sep, $4; sep=","}')"

  local ollama_state="absent" ollama_ver="" models="" resident=""
  if systemctl is-active --quiet ollama 2>/dev/null; then
    ollama_state="active"
    ollama_ver="$(ollama --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || true)"
    models="$(curl -fsS --max-time 3 "http://127.0.0.1:${PORT}/api/tags" 2>/dev/null \
              | jq -r '[.models[].name] | join(",")' 2>/dev/null || true)"
    resident="$(curl -fsS --max-time 3 "http://127.0.0.1:${PORT}/api/ps" 2>/dev/null \
              | jq -r '[.models[].name] | join(",")' 2>/dev/null || true)"
  elif systemctl list-unit-files ollama.service >/dev/null 2>&1; then
    ollama_state="inactive"
  fi

  local store store_free=""
  store="$(cat "${STATE_DIR}/models-dir" 2>/dev/null || echo "")"
  [[ -n "$store" && -d "$store" ]] && store_free="$(df -BM --output=avail "$store" 2>/dev/null | tail -1 | tr -dc '0-9')"

  jq -nc \
    --arg host    "$(hostname)" \
    --arg nodeid  "$(cat /etc/machine-id 2>/dev/null || echo unknown)" \
    --arg board   "$board" \
    --arg iface   "$iface" \
    --arg ip      "$ip" \
    --arg allips  "$all_ips" \
    --arg mac     "$mac" \
    --arg kernel  "$(uname -r)" \
    --arg os      "$(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-unknown}")" \
    --arg ostate  "$ollama_state" \
    --arg over    "$ollama_ver" \
    --arg models  "$models" \
    --arg resident "$resident" \
    --arg boot    "$(uptime -s 2>/dev/null)" \
    --argjson up      "$(cut -d. -f1 /proc/uptime)" \
    --argjson soc     "$(read_t /sys/class/thermal/thermal_zone0/temp)" \
    --argjson big     "$(read_t /sys/class/thermal/thermal_zone1/temp)" \
    --argjson load    "$(cut -d' ' -f1 /proc/loadavg)" \
    --argjson memtot  "$(awk '/MemTotal/{printf "%d",$2/1024}' /proc/meminfo)" \
    --argjson memav   "$(awk '/MemAvailable/{printf "%d",$2/1024}' /proc/meminfo)" \
    --argjson storefree "${store_free:-0}" \
    --arg port    "$PORT" \
    '{
      node_id:$nodeid, hostname:$host, board:$board, os:$os, kernel:$kernel,
      net:{iface:$iface, ip:$ip, all_ips:($allips|split(",")), mac:$mac, port:($port|tonumber)},
      uptime_s:$up, boot_time:$boot,
      thermal:{soc_c:$soc, bigcore_c:$big},
      load1:$load,
      mem:{total_mb:$memtot, available_mb:$memav},
      ollama:{state:$ostate, version:$over,
              models:(if $models=="" then [] else ($models|split(",")) end),
              resident:(if $resident=="" then [] else ($resident|split(",")) end)},
      model_store_free_mb:$storefree,
      reported_at:(now|todate)
    }'
}

main() {
  local payload
  payload="$(collect)" || { echo "collect failed"; exit 0; }
  echo "$payload" > "$LAST"

  if [[ -n "$BEACON_URL" ]]; then
    # Short timeouts and no retry loop: the timer is the retry mechanism.
    if curl -fsS --max-time 8 -H 'Content-Type: application/json' \
         -X POST --data "$payload" "$BEACON_URL" >/dev/null 2>&1; then
      echo "beacon delivered to ${BEACON_URL}"
    else
      echo "collector unreachable at ${BEACON_URL} (will retry on next timer tick)"
    fi
  fi
  # Never fail: an unreachable collector must not mark the node degraded.
  exit 0
}

main "$@"
