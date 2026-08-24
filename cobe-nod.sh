#!/usr/bin/env bash
#
# cobe-nod.sh — deploy a СЛОБО inference node on any hardware.
#
# Runs ON the node itself (not over SSH). Point it at a fresh Ubuntu/Debian
# arm64 or x86_64 box with a shell and sudo, and it turns that box into a
# second Ollama endpoint on the LAN serving the СЛОБО Macedonian model.
#
# First target: Orange Pi 5 (RK3588S, 16 GB LPDDR4X, 512 GB NVMe), booted from
# the SD image built by ./build-sd.sh — that image runs this script on first
# boot via cloud-init, so the node deploys itself with nothing plugged in but
# power and ethernet.
#
# ---------------------------------------------------------------------------
# WHAT THIS NODE IS FOR — read before tuning anything
# ---------------------------------------------------------------------------
# It shares load with the main box (Ryzen 5500 / RTX 4070 12 GB) at the
# REQUEST level, not the tensor level. Small always-on work — chat, Macedonian
# replies, inbox triage, classification — lands here and never touches the
# 4070, so the big model on the main box is not woken up, loaded, and evicted
# for trivia. That is the whole win: you stop paying a ~2 minute cold load of
# a 17 GB model to answer a one-line question.
#
# What this node CANNOT do, and no flag will change:
#   * Run qwen3.8:27b. It is 17 GB; this board has 16 GB total. Even paging it
#     off NVMe, RK3588 memory bandwidth puts generation under 1 tok/s.
#   * Split one model's layers with the main box. llama.cpp's RPC backend can
#     do that in principle, but 1 GbE moves ~118 MB/s where memory moves
#     gigabytes/s — the interconnect becomes the bottleneck and the pair runs
#     slower than either machine alone. Ollama does not expose it anyway.
#
# ---------------------------------------------------------------------------
# SECURITY POSTURE — non-negotiable, do not "simplify" this away
# ---------------------------------------------------------------------------
# Ollama has NO authentication. Anything that can reach port 11434 can run
# inference, list models, and pull or delete them. Therefore:
#
#   * The service binds 0.0.0.0 so the main box can reach it, and ufw is then
#     scoped to THIS SUBNET ONLY, auto-derived from the node's own interface.
#     Bind and firewall are a pair. Keep both.
#   * NEVER port-forward 11434 on the router. NEVER enable UPnP for it.
#   * If you remove the ufw rule you have published an unauthenticated LLM
#     endpoint to every network this board ever joins.
#
# Idempotent: every phase is safe to re-run. Nothing is uninstalled or wiped
# except the NVMe, which is only ever touched when you pass --nvme explicitly
# and confirm.
#
# Usage:
#   sudo ./cobe-nod.sh all                    # detect -> ... -> verify
#   sudo ./cobe-nod.sh <phase> [options]
#
# Phases:
#   detect     hardware, RAM, storage, network — reports only, changes nothing
#   deps       apt packages this script needs
#   storage    put the model store on NVMe instead of the SD card
#   ollama     install Ollama + hardened systemd override
#   firewall   ufw rule scoped to the local subnet
#   model      pick a base model for this RAM and pull it
#   slobo      render the Modelfile and `ollama create slobo`
#   beacon     announce this node to the collector on boot and on a timer
#   verify     real Macedonian round-trip; prints load time and tok/s
#   all        every phase above, in order
#
# Options:
#   --model NAME     force a base model instead of sizing it to RAM
#   --nvme DEV       use DEV (e.g. /dev/nvme0n1) as the model store. If it
#                    already holds a filesystem it is ADOPTED — mounted, and
#                    models go in a subdirectory. Nothing is erased.
#   --format         only with --nvme: erase the device first. DESTRUCTIVE.
#                    Refuses to run unattended without --yes.
#   --models-dir P   use an existing path as the model store (no formatting)
#   --port N         Ollama port, default 11434
#   --subnet CIDR    override the auto-derived firewall subnet
#   --ctx N          force context window instead of sizing it to RAM
#   --yes            assume yes; required for unattended/cloud-init runs
#   --firewall-mode M  'ufw' (default) enables ufw with default-deny incoming —
#                    right for a dedicated node. 'targeted' inserts iptables
#                    rules that restrict ONLY the Ollama port and leave global
#                    policy alone — right for a box already running other
#                    services (k8s, tailscale) that default-deny would break.
#   --beacon-url U   collector endpoint this node announces itself to, e.g.
#                    http://192.168.100.65:9977/beacon. Without it the beacon
#                    phase still installs mDNS, so the node stays findable by
#                    <hostname>.local even when its DHCP address moves.
#   --no-beacon      skip the beacon phase
#   --no-firewall    skip the firewall phase entirely (only if something else
#                    is already filtering this port for you)
#   -h | --help
#
set -euo pipefail

# --------------------------------------------------------------------------
# defaults
# --------------------------------------------------------------------------
PHASE=""
FORCE_MODEL=""
NVME_DEV=""
MODELS_DIR=""
PORT="11434"
SUBNET=""
FORCE_CTX=""
ASSUME_YES=0
DO_FIREWALL=1
DO_FORMAT=0
FIREWALL_MODE="ufw"
BEACON_URL=""
DO_BEACON=1

SERVICE_NAME="ollama"
OVERRIDE_DIR="/etc/systemd/system/${SERVICE_NAME}.service.d"
OVERRIDE_FILE="${OVERRIDE_DIR}/cobe-nod.conf"
DEFAULT_MODELS_DIR="/var/lib/cobe-nod/models"
STATE_DIR="/var/lib/cobe-nod"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODELFILE_TMPL="${SCRIPT_DIR}/slobo/Modelfile.tmpl"

# populated by phase_detect
ARCH=""; BOARD=""; RAM_MB=0; IS_RK3588=0; BIG_CORES=""; NCPU=0
NODE_IP=""; NODE_CIDR=""; NODE_IFACE=""
BASE_MODEL=""; CTX=""; THREADS=""

# --------------------------------------------------------------------------
# output
# --------------------------------------------------------------------------
if [[ -t 1 ]]; then
  R=$'\e[0m'; B=$'\e[1m'; GRN=$'\e[32m'; YEL=$'\e[33m'; RED=$'\e[31m'; DIM=$'\e[2m'
else
  R=""; B=""; GRN=""; YEL=""; RED=""; DIM=""
fi
ok()   { echo "  ${GRN}[ ok ]${R} $*"; }
warn() { echo "  ${YEL}[warn]${R} $*"; }
err()  { echo "  ${RED}[fail]${R} $*" >&2; }
info() { echo "  ${DIM}[ .. ]${R} $*"; }
step() { echo; echo "${B}-- $* --${R}"; }
die()  { err "$*"; exit 1; }

banner() {
  echo
  echo "${B}  cobe-nod${R} — СЛОБО inference node"
  echo "  ${DIM}$(date -Is)${R}"
}

usage() { sed -n '2,/^[^#]/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0; }

confirm() {
  local prompt="$1"
  (( ASSUME_YES )) && return 0
  [[ -t 0 ]] || die "$prompt — refusing in a non-interactive run without --yes"
  local reply
  read -r -p "  ${YEL}?${R} ${prompt} [y/N] " reply
  [[ "$reply" =~ ^[Yy]$ ]]
}

need_root() {
  [[ "$(id -u)" == "0" ]] || die "this phase needs root — re-run with sudo"
}

# Phases are meant to be runnable one at a time, so the model store chosen by
# the storage phase has to outlive that process — otherwise a later standalone
# `ollama` phase silently falls back to the boot media.
MODELS_DIR_STATE="${STATE_DIR}/models-dir"

save_models_dir() {
  [[ -n "$MODELS_DIR" ]] || return 0
  mkdir -p "$STATE_DIR"
  printf '%s\n' "$MODELS_DIR" > "$MODELS_DIR_STATE"
}

load_models_dir() {
  [[ -z "$MODELS_DIR" ]] || return 0
  [[ -r "$MODELS_DIR_STATE" ]] || return 0
  MODELS_DIR="$(cat "$MODELS_DIR_STATE")"
  [[ -n "$MODELS_DIR" ]] && info "model store from previous run: $MODELS_DIR"
}

# --------------------------------------------------------------------------
# phase: detect
# --------------------------------------------------------------------------
detect_hardware() {
  ARCH="$(uname -m)"
  NCPU="$(nproc)"
  RAM_MB="$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo)"

  BOARD="unknown"
  for f in /proc/device-tree/model /sys/firmware/devicetree/base/model; do
    if [[ -r "$f" ]]; then
      BOARD="$(tr -d '\0' < "$f")"
      break
    fi
  done
  if [[ "$BOARD" == "unknown" && -r /sys/class/dmi/id/product_name ]]; then
    BOARD="$(cat /sys/class/dmi/id/product_name)"
  fi

  # RK3588/RK3588S: cpu0-3 are Cortex-A55 (slow), cpu4-7 are Cortex-A76 (fast).
  # Handing llama.cpp all 8 makes every token wait on the A55s. Use the A76s.
  if grep -qiE 'rk3588' /proc/device-tree/compatible 2>/dev/null \
     || [[ "$BOARD" =~ [Rr][Kk]3588 ]] \
     || [[ "$BOARD" =~ Orange[[:space:]]Pi[[:space:]]5 ]]; then
    IS_RK3588=1
    BIG_CORES="4-7"
    THREADS=4
  else
    THREADS="$NCPU"
  fi
}

detect_net() {
  local line
  line="$(ip -4 -o route get 1.1.1.1 2>/dev/null || true)"
  NODE_IFACE="$(sed -n 's/.* dev \([^ ]*\).*/\1/p' <<<"$line")"
  NODE_IP="$(sed -n 's/.* src \([^ ]*\).*/\1/p' <<<"$line")"
  [[ -n "$NODE_IFACE" ]] || return 0

  local cidr
  cidr="$(ip -4 -o addr show dev "$NODE_IFACE" | awk '{print $4}' | head -1)"
  NODE_CIDR="$cidr"
  if [[ -z "$SUBNET" && -n "$cidr" ]]; then
    # network address of our own /N, e.g. 192.168.100.65/24 -> 192.168.100.0/24
    local ip="${cidr%/*}" bits="${cidr#*/}"
    local o1 o2 o3 o4
    IFS=. read -r o1 o2 o3 o4 <<<"$ip"
    local addr=$(( (o1<<24) | (o2<<16) | (o3<<8) | o4 ))
    local mask=$(( 0xFFFFFFFF ^ ((1 << (32-bits)) - 1) ))
    local net=$(( addr & mask ))
    SUBNET="$(( (net>>24)&255 )).$(( (net>>16)&255 )).$(( (net>>8)&255 )).$(( net&255 ))/${bits}"
  fi
}

# Base model sized to RAM. Generation on a CPU-only board is memory-bandwidth
# bound: tok/s falls roughly linearly with model size, and a model that does
# not fit resident pages off storage and collapses. Leave real headroom.
pick_model() {
  if [[ -n "$FORCE_MODEL" ]]; then
    BASE_MODEL="$FORCE_MODEL"
  elif (( RAM_MB >= 14000 )); then
    BASE_MODEL="qwen3:8b"
  elif (( RAM_MB >= 7000 )); then
    BASE_MODEL="qwen3:4b"
  elif (( RAM_MB >= 3500 )); then
    BASE_MODEL="qwen3:1.7b"
  else
    BASE_MODEL="qwen3:0.6b"
  fi

  if [[ -n "$FORCE_CTX" ]]; then
    CTX="$FORCE_CTX"
  elif (( RAM_MB >= 14000 )); then
    CTX=16384
  elif (( RAM_MB >= 7000 )); then
    CTX=8192
  else
    CTX=4096
  fi
}

phase_detect() {
  step "detect"
  detect_hardware
  detect_net
  pick_model

  printf "  %-16s %s\n" "board"   "$BOARD"
  printf "  %-16s %s (%s cores)\n" "arch" "$ARCH" "$NCPU"
  printf "  %-16s %s MB\n" "ram" "$RAM_MB"
  if (( IS_RK3588 )); then
    ok "RK3588 detected — will pin inference to the A76 cores (cpu ${BIG_CORES})"
  fi

  if [[ -r /etc/os-release ]]; then
    printf "  %-16s %s\n" "os" "$(. /etc/os-release; echo "$PRETTY_NAME")"
  fi
  printf "  %-16s %s\n" "kernel" "$(uname -r)"

  if [[ -n "$NODE_IP" ]]; then
    ok "network ${NODE_IP} on ${NODE_IFACE} (${NODE_CIDR}) — subnet ${SUBNET}"
  else
    warn "no default route — the node has no LAN address yet"
  fi

  step "storage"
  lsblk -o NAME,SIZE,TYPE,MOUNTPOINT,MODEL 2>/dev/null | sed 's/^/  /' || true
  local nvme_found
  nvme_found="$(lsblk -dno NAME,SIZE -I 259 2>/dev/null | head -5 || true)"
  if [[ -n "$nvme_found" ]]; then
    ok "NVMe present:"
    sed 's/^/       /' <<<"$nvme_found"
    if ! findmnt -no TARGET --source "/dev/$(awk 'NR==1{print $1}' <<<"$nvme_found")" >/dev/null 2>&1 \
       && [[ -z "$MODELS_DIR" && -z "$NVME_DEV" ]]; then
      warn "NVMe is not mounted — models would land on the boot media"
      warn "pass --nvme /dev/nvme0n1 to adopt it (existing data is kept)"
    fi
  else
    warn "no NVMe found — the model store will sit on the boot media"
  fi

  step "plan"
  printf "  %-16s %s\n" "base model" "$BASE_MODEL"
  printf "  %-16s %s tokens\n" "context" "$CTX"
  printf "  %-16s %s\n" "threads" "$THREADS"
  printf "  %-16s %s\n" "model store" "${MODELS_DIR:-$DEFAULT_MODELS_DIR}"
  printf "  %-16s %s\n" "listen" "0.0.0.0:${PORT}"
  printf "  %-16s %s\n" "firewall" "$( (( DO_FIREWALL )) && echo "${FIREWALL_MODE}: allow ${SUBNET:-<unknown>} -> ${PORT}" || echo "SKIPPED (--no-firewall)" )"

  if [[ "$BASE_MODEL" == qwen3.8:27b || "$BASE_MODEL" =~ 27b|32b|70b ]]; then
    warn "${BASE_MODEL} is far larger than this board's RAM. It will page off"
    warn "storage and generate at well under 1 tok/s. Keep big models on the"
    warn "GPU box and let this node take the small always-on work."
  fi
}

# --------------------------------------------------------------------------
# phase: deps
# --------------------------------------------------------------------------
phase_deps() {
  step "deps"
  need_root
  export DEBIAN_FRONTEND=noninteractive
  local want=(curl ca-certificates jq lsb-release)
  (( DO_BEACON )) && want+=(avahi-daemon avahi-utils)
  if (( DO_FIREWALL )); then
    case "$FIREWALL_MODE" in
      ufw)      want+=(ufw) ;;
      targeted) want+=(iptables iptables-persistent) ;;
    esac
  fi
  # only needed when we are going to repartition something ourselves
  (( DO_FORMAT )) && want+=(parted gdisk e2fsprogs)

  local missing=()
  for p in "${want[@]}"; do
    dpkg -s "$p" >/dev/null 2>&1 || missing+=("$p")
  done

  if (( ${#missing[@]} == 0 )); then
    ok "all packages already present: ${want[*]}"
    return 0
  fi

  info "installing: ${missing[*]}"
  apt-get update -qq
  apt-get install -y -qq "${missing[@]}"
  ok "installed: ${missing[*]}"
}

# --------------------------------------------------------------------------
# phase: storage
# --------------------------------------------------------------------------
# The SD card is the worst possible home for a model store: a few GB of writes
# per pull, random reads on every load, and flash wear that kills the card.
# On the Orange Pi 5 the 512 GB NVMe is the right place.
phase_storage() {
  step "storage"
  need_root
  mkdir -p "$STATE_DIR"

  if [[ -n "$MODELS_DIR" ]]; then
    mkdir -p "$MODELS_DIR"
    save_models_dir
    ok "using existing path as model store: $MODELS_DIR"
    return 0
  fi

  if [[ -z "$NVME_DEV" ]]; then
    MODELS_DIR="$DEFAULT_MODELS_DIR"
    mkdir -p "$MODELS_DIR"
    local src
    src="$(findmnt -no SOURCE --target "$MODELS_DIR")"
    warn "no --nvme given; model store stays on ${src} ($MODELS_DIR)"
    warn "on SD-card boot media this wears the card and loads models slowly"
    save_models_dir
    return 0
  fi

  [[ -b "$NVME_DEV" ]] || die "$NVME_DEV is not a block device"

  # Which partition are we actually talking about? The whole device may itself
  # carry a filesystem, or the data may be in the first partition.
  local part=""
  if [[ -n "$(blkid -o value -s TYPE "$NVME_DEV" 2>/dev/null)" ]]; then
    part="$NVME_DEV"
  else
    for cand in "${NVME_DEV}p1" "${NVME_DEV}1"; do
      [[ -b "$cand" ]] && { part="$cand"; break; }
    done
  fi

  local existing_fs=""
  [[ -n "$part" ]] && existing_fs="$(blkid -o value -s TYPE "$part" 2>/dev/null || true)"

  if (( DO_FORMAT )); then
    # -------------------------------------------------------------------
    # explicit erase — the only destructive path in this script
    # -------------------------------------------------------------------
    echo
    warn "--format given: about to ERASE ${NVME_DEV} and everything on it:"
    lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,MOUNTPOINT "$NVME_DEV" | sed 's/^/       /'
    if [[ -n "$existing_fs" ]]; then
      warn "${part} currently holds a ${existing_fs} filesystem with data on it."
      warn "Dropping --format would keep that data and just use free space."
    fi
    echo
    confirm "erase ${NVME_DEV}? this cannot be undone" \
      || die "aborted by operator — nothing was changed"

    local m
    for p in "$NVME_DEV" "${NVME_DEV}"p* "${NVME_DEV}"[0-9]*; do
      [[ -b "$p" ]] || continue
      for m in $(findmnt -rno TARGET --source "$p" 2>/dev/null || true); do
        info "unmounting $m"; umount "$m"
      done
    done

    info "partitioning $NVME_DEV"
    sgdisk --zap-all "$NVME_DEV" >/dev/null 2>&1 || wipefs -a "$NVME_DEV" >/dev/null
    parted -s "$NVME_DEV" mklabel gpt mkpart primary ext4 1MiB 100%
    partprobe "$NVME_DEV"; sleep 2
    part="${NVME_DEV}p1"; [[ -b "$part" ]] || part="${NVME_DEV}1"
    info "formatting $part ext4"
    mkfs.ext4 -q -L cobe-nod -m 0 "$part"
    ok "formatted $part"

  elif [[ -n "$existing_fs" ]]; then
    # -------------------------------------------------------------------
    # adopt — the default. Someone else's data lives here; we are a guest.
    # -------------------------------------------------------------------
    ok "adopting existing ${existing_fs} filesystem on ${part} — nothing erased"
  else
    die "${NVME_DEV} has no filesystem. Pass --format to partition and format it."
  fi

  # Mount it (wherever it already is, or at a stable path of our own).
  local mnt
  mnt="$(findmnt -fno TARGET --source "$part" 2>/dev/null || true)"
  if [[ -n "$mnt" ]]; then
    ok "already mounted at $mnt"
  else
    mnt="/mnt/nvme"
    mkdir -p "$mnt"
    local uuid; uuid="$(blkid -o value -s UUID "$part")"
    if ! grep -q "$uuid" /etc/fstab; then
      # nofail: a missing disk must never keep this node from booting.
      echo "UUID=${uuid} ${mnt} ext4 defaults,noatime,nofail 0 2" >> /etc/fstab
      ok "added ${part} to /etc/fstab as ${mnt} (noatime,nofail)"
    fi
    mount "$mnt"
    ok "mounted ${part} at ${mnt}"
  fi

  MODELS_DIR="${mnt}/cobe-nod/models"
  mkdir -p "$MODELS_DIR"
  save_models_dir
  ok "model store: $MODELS_DIR ($(df -h "$mnt" | awk 'NR==2{print $4}') free)"
}

# --------------------------------------------------------------------------
# phase: ollama
# --------------------------------------------------------------------------
phase_ollama() {
  step "ollama"
  need_root

  if command -v ollama >/dev/null 2>&1; then
    ok "ollama already installed: $(ollama --version 2>&1 | head -1)"
  else
    info "installing ollama (official script, arm64/amd64 autodetected)"
    # zstd is needed by recent installers to unpack the payload
    dpkg -s zstd >/dev/null 2>&1 || apt-get install -y -qq zstd
    curl -fsSL https://ollama.com/install.sh | sh
    command -v ollama >/dev/null 2>&1 || die "ollama install failed"
    ok "installed $(ollama --version 2>&1 | head -1)"
  fi

  load_models_dir
  [[ -n "$MODELS_DIR" ]] || MODELS_DIR="$DEFAULT_MODELS_DIR"
  mkdir -p "$MODELS_DIR"
  save_models_dir
  chown -R ollama:ollama "$MODELS_DIR" 2>/dev/null || true

  mkdir -p "$OVERRIDE_DIR"
  {
    echo "# Written by cobe-nod.sh — see the security note at the top of that script."
    echo "# OLLAMA_HOST=0.0.0.0 is only safe because ufw scopes 11434 to the LAN."
    echo "[Service]"
    echo "Environment=\"OLLAMA_HOST=0.0.0.0:${PORT}\""
    echo "Environment=\"OLLAMA_MODELS=${MODELS_DIR}\""
    echo "Environment=\"OLLAMA_KV_CACHE_TYPE=q8_0\""
    echo "Environment=\"OLLAMA_MAX_LOADED_MODELS=1\""
    echo "Environment=\"OLLAMA_NUM_PARALLEL=1\""
    # Keep the model resident: on a CPU node a cold load is tens of seconds,
    # and this node exists precisely to answer small requests immediately.
    echo "Environment=\"OLLAMA_KEEP_ALIVE=-1\""
    if (( IS_RK3588 )); then
      echo "# RK3588: bind to the A76 cluster. Including the A55s slows generation."
      echo "CPUAffinity=${BIG_CORES}"
    fi
  } > "$OVERRIDE_FILE"
  ok "wrote $OVERRIDE_FILE"

  if (( IS_RK3588 )); then
    for g in /sys/devices/system/cpu/cpufreq/policy*/scaling_governor; do
      [[ -w "$g" ]] && echo performance > "$g" 2>/dev/null || true
    done
    ok "cpufreq governor set to performance (this boot)"
  fi

  systemctl daemon-reload
  systemctl enable --now "$SERVICE_NAME" >/dev/null 2>&1 || true
  systemctl restart "$SERVICE_NAME"

  local i
  for i in $(seq 1 30); do
    if curl -fsS --max-time 2 "http://127.0.0.1:${PORT}/api/tags" >/dev/null 2>&1; then
      ok "ollama is serving on 0.0.0.0:${PORT}"
      return 0
    fi
    sleep 1
  done
  journalctl -u "$SERVICE_NAME" -n 20 --no-pager | sed 's/^/       /' || true
  die "ollama did not come up on port ${PORT}"
}

# --------------------------------------------------------------------------
# phase: firewall
# --------------------------------------------------------------------------
phase_firewall() {
  step "firewall (${FIREWALL_MODE})"
  if (( ! DO_FIREWALL )); then
    warn "skipped by --no-firewall — port ${PORT} is open to every network"
    warn "this board joins. Only acceptable if something else is filtering it."
    return 0
  fi
  need_root
  [[ -n "$SUBNET" ]] || die "could not derive the local subnet — pass --subnet CIDR"

  case "$FIREWALL_MODE" in
    ufw)
      command -v ufw >/dev/null 2>&1 || die "ufw not installed — run the deps phase"
      if [[ -n "$(ss -lntp 2>/dev/null | grep -E ':(16443|6443|41641)\b' || true)" ]]; then
        warn "this box is serving k8s and/or tailscale ports. Enabling ufw with"
        warn "default-deny incoming can cut them off. --firewall-mode targeted"
        warn "restricts only port ${PORT} and leaves global policy alone."
        confirm "enable ufw anyway?" || die "aborted — no firewall change made"
      fi
      ufw allow 22/tcp >/dev/null            # never lock ourselves out of ssh
      ufw allow from "$SUBNET" to any port "$PORT" proto tcp >/dev/null
      ufw --force enable >/dev/null
      ok "ufw: ${PORT} reachable from ${SUBNET} only; 22 open; rest denied"
      ufw status numbered | sed 's/^/       /'
      ;;

    targeted)
      # Restrict one port without touching the default policy, so whatever else
      # this box already does keeps working. Loopback is exempted explicitly:
      # 127.0.0.1 is not inside the LAN subnet, so the DROP rule would
      # otherwise cut off the node's own client and every local health check.
      command -v iptables >/dev/null 2>&1 || die "iptables not installed — run the deps phase"
      local chain="COBE_NOD"
      iptables -N "$chain" 2>/dev/null || iptables -F "$chain"
      iptables -A "$chain" -i lo -j ACCEPT
      iptables -A "$chain" -s "$SUBNET" -j ACCEPT
      iptables -A "$chain" -j DROP
      # jump into it exactly once, however many times this phase re-runs
      iptables -C INPUT -p tcp --dport "$PORT" -j "$chain" 2>/dev/null \
        || iptables -I INPUT 1 -p tcp --dport "$PORT" -j "$chain"
      ok "iptables chain ${chain}: port ${PORT} accepts lo + ${SUBNET}, drops the rest"

      if command -v netfilter-persistent >/dev/null 2>&1; then
        netfilter-persistent save >/dev/null 2>&1 \
          && ok "rules saved — they survive reboot" \
          || warn "could not persist rules; they are lost on reboot"
      else
        warn "iptables-persistent not installed — rules are lost on reboot"
      fi
      iptables -L "$chain" -n --line-numbers | sed 's/^/       /'
      ;;

    *) die "unknown --firewall-mode: ${FIREWALL_MODE} (want 'ufw' or 'targeted')" ;;
  esac
}

# --------------------------------------------------------------------------
# phase: model
# --------------------------------------------------------------------------
phase_model() {
  step "model"
  [[ -n "$BASE_MODEL" ]] || { detect_hardware; pick_model; }

  if ollama list 2>/dev/null | awk '{print $1}' | grep -qx "$BASE_MODEL"; then
    ok "$BASE_MODEL already pulled"
    return 0
  fi

  info "pulling $BASE_MODEL — this is the long part on a slow link"
  ollama pull "$BASE_MODEL"
  ok "pulled $BASE_MODEL"
}

# --------------------------------------------------------------------------
# phase: slobo
# --------------------------------------------------------------------------
phase_slobo() {
  step "slobo"
  [[ -r "$MODELFILE_TMPL" ]] || die "missing template: $MODELFILE_TMPL"
  [[ -n "$BASE_MODEL" ]] || { detect_hardware; pick_model; }

  local rendered="${STATE_DIR}/Modelfile"
  mkdir -p "$STATE_DIR"
  sed -e "s|@@BASE@@|${BASE_MODEL}|" \
      -e "s|@@CTX@@|${CTX}|" \
      -e "s|@@THREADS@@|${THREADS}|" \
      "$MODELFILE_TMPL" > "$rendered"
  ok "rendered $rendered (FROM ${BASE_MODEL}, ctx ${CTX}, ${THREADS} threads)"

  ollama create slobo -f "$rendered"
  ok "model 'slobo' created"
}

# --------------------------------------------------------------------------
# phase: beacon
# --------------------------------------------------------------------------
# A node whose address is handed out by DHCP will eventually move, and then it
# is simply lost until someone sweeps the subnet. This node announces itself
# instead: an HTTP push carrying full state, plus mDNS so it stays resolvable
# as <hostname>.local even with no collector running at all.
phase_beacon() {
  step "beacon"
  if (( ! DO_BEACON )); then
    warn "skipped by --no-beacon — this node will not announce itself"
    return 0
  fi
  need_root

  # mDNS: the channel that needs no infrastructure on the other end.
  if systemctl list-unit-files avahi-daemon.service >/dev/null 2>&1; then
    systemctl enable --now avahi-daemon >/dev/null 2>&1 || true
    ok "mDNS active — reachable as $(hostname).local regardless of DHCP"
  else
    warn "avahi-daemon not installed; mDNS channel unavailable (run deps)"
  fi

  install -D -m 0755 "${SCRIPT_DIR}/beacon/cobe-beacon.sh" /opt/cobe-nod/cobe-beacon.sh \
    || die "beacon/cobe-beacon.sh not found next to this script"

  mkdir -p /etc/cobe-nod
  if [[ -n "$BEACON_URL" ]]; then
    printf 'BEACON_URL=%q\nOLLAMA_PORT=%q\n' "$BEACON_URL" "$PORT" > /etc/cobe-nod/beacon.conf
    ok "collector: $BEACON_URL"
  else
    printf 'OLLAMA_PORT=%q\n' "$PORT" > /etc/cobe-nod/beacon.conf
    warn "no --beacon-url given; mDNS only, no state is pushed anywhere"
  fi

  install -m 0644 "${SCRIPT_DIR}/beacon/cobe-beacon.service" /etc/systemd/system/
  install -m 0644 "${SCRIPT_DIR}/beacon/cobe-beacon.timer"   /etc/systemd/system/
  systemctl daemon-reload
  systemctl enable --now cobe-beacon.timer >/dev/null 2>&1
  ok "cobe-beacon.timer enabled (30s after boot, then every 5 min)"

  systemctl start cobe-beacon.service 2>/dev/null || true
  local out
  out="$(journalctl -u cobe-beacon.service -n 3 --no-pager -o cat 2>/dev/null | tail -2)"
  [[ -n "$out" ]] && sed 's/^/       /' <<<"$out"
}

# --------------------------------------------------------------------------
# phase: verify
# --------------------------------------------------------------------------
# Not a smoke test of the HTTP layer — a real Macedonian prompt through the
# real model, reporting the two numbers that decide whether this node is worth
# routing to: cold load time and sustained tok/s.
phase_verify() {
  step "verify"
  local url="http://127.0.0.1:${PORT}/api/generate"
  local prompt="Кажи во една реченица што е Слободна Енергија и со што се занимава."

  info "unloading any resident model to time a genuine cold load"
  curl -fsS "$url" -d '{"model":"slobo","keep_alive":0,"prompt":""}' >/dev/null 2>&1 || true
  sleep 2

  info "prompting: ${prompt}"
  local body resp
  body="$(jq -nc --arg p "$prompt" '{model:"slobo", prompt:$p, stream:false, think:false}')"
  local t0 t1
  t0="$(date +%s.%N)"
  resp="$(curl -fsS --max-time 900 "$url" -d "$body")" || die "generate request failed"
  t1="$(date +%s.%N)"

  local text load_s eval_s eval_n prompt_n tps wall
  text="$(jq -r '.response // ""' <<<"$resp")"
  load_s="$(jq -r '(.load_duration // 0) / 1e9' <<<"$resp")"
  eval_s="$(jq -r '(.eval_duration // 0) / 1e9' <<<"$resp")"
  eval_n="$(jq -r '.eval_count // 0' <<<"$resp")"
  prompt_n="$(jq -r '.prompt_eval_count // 0' <<<"$resp")"
  tps="$(awk -v n="$eval_n" -v s="$eval_s" 'BEGIN{ printf "%.2f", (s>0 ? n/s : 0) }')"
  wall="$(awk -v a="$t0" -v b="$t1" 'BEGIN{ printf "%.1f", b-a }')"

  echo
  echo "  ${B}response${R}"
  fold -s -w 72 <<<"$text" | sed 's/^/       /'
  echo
  printf "  %-22s %s s\n"      "cold load"        "$(printf '%.1f' "$load_s")"
  printf "  %-22s %s tokens\n" "prompt"           "$prompt_n"
  printf "  %-22s %s tokens\n" "generated"        "$eval_n"
  printf "  %-22s %s tok/s\n"  "generation speed" "$tps"
  printf "  %-22s %s s\n"      "wall clock"       "$wall"

  # Is it actually answering in Macedonian, or has it drifted to Serbian?
  if grep -qE '[а-шА-Ш]' <<<"$text"; then
    ok "response is Cyrillic"
  else
    warn "response is not Cyrillic — check the SYSTEM prompt in the Modelfile"
  fi

  step "reachable from the main box"
  if [[ -n "$NODE_IP" ]]; then
    echo "       curl http://${NODE_IP}:${PORT}/api/tags"
    echo "       curl http://${NODE_IP}:${PORT}/api/generate -d '{\"model\":\"slobo\",\"prompt\":\"здраво\",\"stream\":false}'"
    echo
    echo "  ${DIM}Route small always-on work here; keep qwen3.8:27b on the 4070 box.${R}"
  else
    warn "node has no LAN address — nothing can reach it yet"
  fi

  jq -n --arg board "$BOARD" --arg model "$BASE_MODEL" --arg ip "$NODE_IP" \
        --argjson tps "$tps" --argjson load "$load_s" --argjson ctx "$CTX" \
        '{board:$board, model:$model, ip:$ip, ctx:$ctx, tok_per_s:$tps, cold_load_s:$load, at:(now|todate)}' \
     > "${STATE_DIR}/node.json" 2>/dev/null || true
  [[ -f "${STATE_DIR}/node.json" ]] && ok "fingerprint written to ${STATE_DIR}/node.json"
}

# --------------------------------------------------------------------------
# main
# --------------------------------------------------------------------------
main() {
  while (( $# )); do
    case "$1" in
      detect|deps|storage|ollama|firewall|model|slobo|beacon|verify|all) PHASE="$1" ;;
      --model)       FORCE_MODEL="$2"; shift ;;
      --nvme)        NVME_DEV="$2"; shift ;;
      --models-dir)  MODELS_DIR="$2"; shift ;;
      --port)        PORT="$2"; shift ;;
      --subnet)      SUBNET="$2"; shift ;;
      --ctx)         FORCE_CTX="$2"; shift ;;
      --yes|-y)      ASSUME_YES=1 ;;
      --format)      DO_FORMAT=1 ;;
      --firewall-mode) FIREWALL_MODE="$2"; shift ;;
      --beacon-url)  BEACON_URL="$2"; shift ;;
      --no-beacon)   DO_BEACON=0 ;;
      --no-firewall) DO_FIREWALL=0 ;;
      -h|--help)     usage ;;
      *) die "unknown argument: $1 (try --help)" ;;
    esac
    shift
  done

  [[ -n "$PHASE" ]] || usage
  banner

  case "$PHASE" in
    detect)   phase_detect ;;
    deps)     phase_deps ;;
    storage)  detect_hardware; detect_net; phase_storage ;;
    ollama)   detect_hardware; detect_net; pick_model; phase_ollama ;;
    firewall) detect_net; phase_firewall ;;
    model)    detect_hardware; pick_model; phase_model ;;
    slobo)    detect_hardware; pick_model; phase_slobo ;;
    beacon)   detect_hardware; detect_net; phase_beacon ;;
    verify)   detect_hardware; detect_net; phase_verify ;;
    all)
      phase_detect
      phase_deps
      phase_storage
      phase_ollama
      phase_firewall
      phase_model
      phase_slobo
      phase_beacon
      phase_verify
      step "done"
      ok "node is live — ${BASE_MODEL} as 'slobo' on ${NODE_IP}:${PORT}"
      ;;
  esac
  echo
}

main "$@"
