#!/usr/bin/env bash
#
# build-sd.sh — bake a self-deploying СЛОБО node image for the Orange Pi 5.
#
# Runs on this box (WSL2/Linux). Downloads an Ubuntu 24.04 arm64 server image
# for the Orange Pi 5, injects a cloud-init payload carrying cobe-nod.sh, and
# writes out a flashable .img. Put the card in the Pi, give it power and
# ethernet, and on first boot the node installs Ollama, pulls a model sized to
# its RAM, builds the СЛОБО model, firewalls port 11434 to your subnet, and
# comes up serving. Nothing to type on the Pi itself.
#
# The base image is Joshua Riek's ubuntu-rockchip build — the best-maintained
# Ubuntu for RK3588 boards, and its server images ship a CIDATA partition that
# cloud-init reads on first boot, which is exactly the hook we need.
#   https://github.com/Joshua-Riek/ubuntu-rockchip
#
# ---------------------------------------------------------------------------
# WHY NOT WRITE THE CARD DIRECTLY
# ---------------------------------------------------------------------------
# Under WSL2 a USB card reader plugged into Windows is not a block device in
# Linux unless you have set up usbipd-win. So by default this script produces
# an .img file and prints the Windows-side flashing command. Pass --write DEV
# if you do have the device visible (bare-metal Linux, or usbipd attached).
#
# Usage:
#   ./build-sd.sh                                   # build the .img
#   ./build-sd.sh --nvme /dev/nvme0n1               # also claim the NVMe on first boot
#   ./build-sd.sh --wifi 'SSID:passphrase'          # join wifi instead of ethernet
#   ./build-sd.sh --write /dev/sdX                  # build and flash (DESTRUCTIVE)
#
# Options:
#   --release TAG    ubuntu-rockchip release, default v2.4.0
#   --ubuntu VER     24.04 (default) or 22.04
#   --board NAME     orangepi-5 (default), orangepi-5-plus, orangepi-5-max, ...
#   --hostname NAME  node hostname, default cobe-nod-01
#   --user NAME      login user on the node, default the current $USER
#   --key PATH       ssh public key to authorize, default the first ~/.ssh/*.pub
#   --model NAME     force the base model instead of sizing it to the Pi's RAM
#   --nvme DEV       use this device on the node as the model store. An
#                    existing filesystem is ADOPTED, not erased.
#   --format         only with --nvme: erase that device on first boot.
#                    DESTRUCTIVE and unattended — be sure the disk is blank.
#   --firewall-mode M  'ufw' (default, right for a dedicated node) or
#                    'targeted' (restrict only port 11434, for a node that
#                    already runs other services)
#   --wifi 'S:P'     wifi SSID and passphrase (omit for ethernet DHCP)
#   --out PATH       output image path
#   --write DEV      write the finished image to a block device (asks first)
#   --dry-run        render the cloud-init payload to stdout and stop
#   -h | --help
#
set -euo pipefail

RELEASE="v2.4.0"
UBUNTU="24.04"
BOARD="orangepi-5"
NODE_HOSTNAME="cobe-nod-01"
NODE_USER="${SUDO_USER:-$USER}"
SSH_KEY=""
FORCE_MODEL=""
NVME_DEV=""
DO_FORMAT=0
FIREWALL_MODE=""
WIFI=""
OUT=""
WRITE_DEV=""
DRY_RUN=0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="${SCRIPT_DIR}/.work"
BASE_URL="https://github.com/Joshua-Riek/ubuntu-rockchip/releases/download"

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
usage() { sed -n '2,/^[^#]/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0; }

LOOP=""
MNT=""
cleanup() {
  [[ -n "$MNT"  ]] && mountpoint -q "$MNT" && sudo umount "$MNT" || true
  [[ -n "$LOOP" ]] && sudo losetup -d "$LOOP" 2>/dev/null || true
  [[ -n "$MNT"  ]] && rmdir "$MNT" 2>/dev/null || true
}
trap cleanup EXIT

# --------------------------------------------------------------------------
parse_args() {
  while (( $# )); do
    case "$1" in
      --release)  RELEASE="$2"; shift ;;
      --ubuntu)   UBUNTU="$2"; shift ;;
      --board)    BOARD="$2"; shift ;;
      --hostname) NODE_HOSTNAME="$2"; shift ;;
      --user)     NODE_USER="$2"; shift ;;
      --key)      SSH_KEY="$2"; shift ;;
      --model)    FORCE_MODEL="$2"; shift ;;
      --nvme)     NVME_DEV="$2"; shift ;;
      --format)   DO_FORMAT=1 ;;
      --firewall-mode) FIREWALL_MODE="$2"; shift ;;
      --wifi)     WIFI="$2"; shift ;;
      --out)      OUT="$2"; shift ;;
      --write)    WRITE_DEV="$2"; shift ;;
      --dry-run)  DRY_RUN=1 ;;
      -h|--help)  usage ;;
      *) die "unknown argument: $1 (try --help)" ;;
    esac
    shift
  done
  (( DO_FORMAT )) && [[ -z "$NVME_DEV" ]] && die "--format needs --nvme DEV"
  [[ -n "$OUT" ]] || OUT="${SCRIPT_DIR}/out/cobe-nod-${BOARD}-$(date +%Y%m%d).img"
}

preflight() {
  step "preflight"
  local missing=()
  for t in curl xz sha256sum losetup blkid sudo; do
    command -v "$t" >/dev/null 2>&1 || missing+=("$t")
  done
  (( ${#missing[@]} )) && die "missing tools: ${missing[*]}"
  ok "tools present"

  grep -qw vfat /proc/filesystems \
    || die "this kernel has no vfat support — cannot write the cloud-init partition"
  ok "kernel supports vfat"

  if [[ -z "$SSH_KEY" ]]; then
    SSH_KEY="$(ls -1 "$HOME"/.ssh/*.pub 2>/dev/null | head -1 || true)"
  fi
  [[ -n "$SSH_KEY" && -r "$SSH_KEY" ]] \
    || die "no ssh public key found — pass --key PATH (headless node needs one)"
  ok "authorizing key: $SSH_KEY"

  [[ -r "${SCRIPT_DIR}/cobe-nod.sh" ]] || die "cobe-nod.sh not found next to this script"
  [[ -r "${SCRIPT_DIR}/slobo/Modelfile.tmpl" ]] || die "slobo/Modelfile.tmpl not found"
  bash -n "${SCRIPT_DIR}/cobe-nod.sh" || die "cobe-nod.sh does not parse — refusing to bake it"
  ok "payload scripts present and valid"

  local free_gb
  free_gb="$(df -BG --output=avail "$SCRIPT_DIR" | tail -1 | tr -dc '0-9')"
  (( free_gb >= 20 )) || die "need ~20 GB free to unpack the image, have ${free_gb} GB"
  ok "${free_gb} GB free"
}

# --------------------------------------------------------------------------
fetch_image() {
  step "base image"
  mkdir -p "$WORK"
  local name="ubuntu-${UBUNTU}-preinstalled-server-arm64-${BOARD}.img.xz"
  local url="${BASE_URL}/${RELEASE}/${name}"
  local xz="${WORK}/${name}"

  if [[ -s "$xz" ]]; then
    ok "cached: $(basename "$xz") ($(du -h "$xz" | cut -f1))"
  else
    info "downloading ${url}"
    curl -fL --progress-bar -o "${xz}.part" "$url" \
      || die "download failed — check --release/--ubuntu/--board name"
    mv "${xz}.part" "$xz"
    ok "downloaded $(du -h "$xz" | cut -f1)"
  fi

  info "verifying sha256"
  local sum
  sum="$(curl -fsSL "${url}.sha256" 2>/dev/null | awk '{print $1}' || true)"
  if [[ -n "$sum" ]]; then
    local got; got="$(sha256sum "$xz" | awk '{print $1}')"
    [[ "$got" == "$sum" ]] || die "sha256 mismatch — refusing to build from a corrupt image"
    ok "sha256 verified"
  else
    warn "no published .sha256 for this asset — continuing unverified"
  fi

  mkdir -p "$(dirname "$OUT")"
  info "decompressing to $(basename "$OUT")"
  xz -dc "$xz" > "$OUT"
  ok "image: $OUT ($(du -h "$OUT" | cut -f1))"
}

# --------------------------------------------------------------------------
render_user_data() {
  local dest="$1"
  local key script_b64 tmpl_b64 nvme_args model_args fw_args
  key="$(cat "$SSH_KEY")"
  script_b64="$(base64 -w0 < "${SCRIPT_DIR}/cobe-nod.sh")"
  tmpl_b64="$(base64 -w0 < "${SCRIPT_DIR}/slobo/Modelfile.tmpl")"
  nvme_args=""
  [[ -n "$NVME_DEV" ]] && nvme_args=" --nvme ${NVME_DEV}"
  (( DO_FORMAT )) && nvme_args+=" --format"
  model_args=""
  [[ -n "$FORCE_MODEL" ]] && model_args=" --model ${FORCE_MODEL}"
  fw_args=""
  [[ -n "$FIREWALL_MODE" ]] && fw_args=" --firewall-mode ${FIREWALL_MODE}"

  cat > "$dest" <<CLOUD_EOF
#cloud-config
# Generated by cobe-nod/build-sd.sh on $(date -Is)
# Consumed once, on first boot, by cloud-init's NoCloud datasource.

hostname: ${NODE_HOSTNAME}
prefer_fqdn_over_hostname: false

users:
  - name: ${NODE_USER}
    groups: [adm, sudo]
    shell: /bin/bash
    sudo: "ALL=(ALL) NOPASSWD:ALL"
    lock_passwd: true
    ssh_authorized_keys:
      - ${key}

# Key-only. The stock image's ubuntu/ubuntu login is a headless liability.
ssh_pwauth: false
disable_root: true

package_update: true

write_files:
  - path: /opt/cobe-nod/cobe-nod.sh
    permissions: "0755"
    encoding: b64
    content: ${script_b64}

  - path: /opt/cobe-nod/slobo/Modelfile.tmpl
    permissions: "0644"
    encoding: b64
    content: ${tmpl_b64}

  - path: /opt/cobe-nod/firstboot.sh
    permissions: "0755"
    content: |
      #!/usr/bin/env bash
      # First-boot deploy wrapper. Idempotent: the stamp makes re-runs no-ops,
      # and cobe-nod.sh itself is safe to re-run regardless.
      set -euo pipefail
      STAMP=/var/lib/cobe-nod/.deployed
      LOG=/var/log/cobe-nod-firstboot.log
      mkdir -p /var/lib/cobe-nod
      if [[ -f "\$STAMP" ]]; then
        echo "already deployed on \$(cat "\$STAMP") — nothing to do"
        exit 0
      fi
      # Wait for a usable default route; a node with no LAN address cannot
      # derive its own firewall subnet or pull a model.
      for i in \$(seq 1 60); do
        ip -4 route get 1.1.1.1 >/dev/null 2>&1 && break
        sleep 5
      done
      /opt/cobe-nod/cobe-nod.sh all --yes${nvme_args}${model_args}${fw_args} 2>&1 | tee -a "\$LOG"
      date -Is > "\$STAMP"
      echo "cobe-nod deployed" | tee -a "\$LOG"

  - path: /etc/systemd/system/cobe-nod-firstboot.service
    permissions: "0644"
    content: |
      [Unit]
      Description=cobe-nod first-boot deploy (СЛОБО inference node)
      Wants=network-online.target
      After=network-online.target
      ConditionPathExists=!/var/lib/cobe-nod/.deployed

      [Service]
      Type=oneshot
      RemainAfterExit=yes
      ExecStart=/opt/cobe-nod/firstboot.sh
      # A model pull on a slow link can take a long while; do not time it out.
      TimeoutStartSec=0
      # If it fails (no network yet, mirror hiccup), try again rather than
      # leaving a half-built node that needs a human with a monitor.
      Restart=on-failure
      RestartSec=60
      StandardOutput=journal+console

      [Install]
      WantedBy=multi-user.target

runcmd:
  - [ systemctl, daemon-reload ]
  - [ systemctl, enable, --now, cobe-nod-firstboot.service ]

final_message: "cobe-nod: base system up after \$UPTIME s; deploy running in cobe-nod-firstboot.service (journalctl -fu cobe-nod-firstboot)"
CLOUD_EOF
}

render_network_config() {
  local dest="$1"
  if [[ -z "$WIFI" ]]; then
    cat > "$dest" <<'NET_EOF'
version: 2
ethernets:
  all-en:
    match: {name: "en*"}
    dhcp4: true
    optional: true
NET_EOF
    return
  fi
  local ssid="${WIFI%%:*}" psk="${WIFI#*:}"
  [[ "$ssid" != "$WIFI" && -n "$psk" ]] || die "--wifi wants 'SSID:passphrase'"
  cat > "$dest" <<NET_EOF
version: 2
ethernets:
  all-en:
    match: {name: "en*"}
    dhcp4: true
    optional: true
wifis:
  wlan0:
    dhcp4: true
    optional: true
    access-points:
      "${ssid}":
        password: "${psk}"
NET_EOF
}

# --------------------------------------------------------------------------
inject() {
  step "inject cloud-init"
  LOOP="$(sudo losetup --show -Pf "$OUT")"
  ok "attached $LOOP"
  sleep 1

  local target="" p label fstype
  for p in "${LOOP}"p*; do
    [[ -b "$p" ]] || continue
    fstype="$(sudo blkid -o value -s TYPE "$p" 2>/dev/null || true)"
    label="$(sudo blkid -o value -s LABEL "$p" 2>/dev/null || true)"
    info "$(basename "$p"): ${fstype:-?} ${label:+label=$label}"
    if [[ "$label" == "CIDATA" ]]; then target="$p"; fi
  done
  if [[ -z "$target" ]]; then
    # Older builds have no dedicated CIDATA partition; cloud-init's NoCloud
    # datasource also reads /boot/firmware on the first vfat partition.
    for p in "${LOOP}"p*; do
      [[ -b "$p" ]] || continue
      [[ "$(sudo blkid -o value -s TYPE "$p" 2>/dev/null)" == "vfat" ]] || continue
      target="$p"; break
    done
    [[ -n "$target" ]] && warn "no CIDATA partition; falling back to $(basename "$target")"
  fi
  [[ -n "$target" ]] || die "no FAT partition in the image — cannot seed cloud-init"

  MNT="$(mktemp -d)"
  sudo mount "$target" "$MNT"
  ok "mounted $(basename "$target") -> $MNT"

  local tmp; tmp="$(mktemp -d)"
  render_user_data "${tmp}/user-data"
  render_network_config "${tmp}/network-config"
  cat > "${tmp}/meta-data" <<META_EOF
instance-id: ${NODE_HOSTNAME}-$(date +%s)
local-hostname: ${NODE_HOSTNAME}
META_EOF

  sudo cp "${tmp}/user-data" "${tmp}/meta-data" "${tmp}/network-config" "$MNT/"
  sudo sync
  ok "wrote user-data ($(wc -c < "${tmp}/user-data") bytes), meta-data, network-config"
  rm -rf "$tmp"

  sudo umount "$MNT"; rmdir "$MNT"; MNT=""
  sudo losetup -d "$LOOP"; LOOP=""
  ok "image sealed"
}

# --------------------------------------------------------------------------
maybe_write() {
  [[ -n "$WRITE_DEV" ]] || return 0
  step "write to $WRITE_DEV"
  [[ -b "$WRITE_DEV" ]] || die "$WRITE_DEV is not a block device"
  lsblk -o NAME,SIZE,TYPE,MOUNTPOINT,MODEL "$WRITE_DEV" | sed 's/^/       /'
  echo
  warn "this ERASES ${WRITE_DEV} completely"
  local reply
  read -r -p "  ${YEL}?${R} type the device path again to confirm: " reply
  [[ "$reply" == "$WRITE_DEV" ]] || die "confirmation did not match — nothing written"
  sudo dd if="$OUT" of="$WRITE_DEV" bs=4M status=progress conv=fsync
  sudo sync
  ok "written and synced — the card is ready"
}

report() {
  step "next steps"
  echo "  image:  ${B}${OUT}${R}"
  echo "  size:   $(du -h "$OUT" | cut -f1)"
  echo
  if [[ -z "$WRITE_DEV" ]]; then
    echo "  Flash it from Windows (WSL cannot see your card reader):"
    echo "    ${DIM}Raspberry Pi Imager -> Use custom -> pick the file below,${R}"
    echo "    ${DIM}or balenaEtcher / USBimager. Do NOT let Imager apply its own${R}"
    echo "    ${DIM}customisation — it would overwrite the cloud-init we just wrote.${R}"
    echo
    local winpath
    winpath="$(wslpath -w "$OUT" 2>/dev/null || echo "$OUT")"
    echo "    ${winpath}"
    echo
  fi
  echo "  Then: card into the Orange Pi 5, ethernet, power on."
  echo "  First boot pulls a model, so give it 15-40 minutes on a normal link."
  echo
  echo "  Watch it deploy:"
  echo "    ssh ${NODE_USER}@${NODE_HOSTNAME}.local 'journalctl -fu cobe-nod-firstboot'"
  echo
  echo "  When it is up, from this box:"
  echo "    curl http://${NODE_HOSTNAME}.local:11434/api/tags"
  echo
  if (( DO_FORMAT )); then
    warn "first boot will ERASE ${NVME_DEV} on the node — unattended, no prompt"
  elif [[ -n "$NVME_DEV" ]]; then
    echo "  ${DIM}First boot adopts ${NVME_DEV} as the model store; existing data is kept.${R}"
  fi
  echo "  ${DIM}Port 11434 is unauthenticated by design. It is firewalled to the${R}"
  echo "  ${DIM}node's own subnet. Never forward it on the router.${R}"
}

main() {
  parse_args "$@"
  echo
  echo "${B}  cobe-nod${R} — building a self-deploying СЛОБО node image"
  echo "  ${DIM}${BOARD} / ubuntu ${UBUNTU} / ubuntu-rockchip ${RELEASE}${R}"
  preflight
  if (( DRY_RUN )); then
    step "cloud-init payload (dry run — no image touched)"
    local tmp; tmp="$(mktemp -d)"
    render_user_data "${tmp}/user-data"
    render_network_config "${tmp}/network-config"
    echo "  ${DIM}--- user-data ($(wc -c < "${tmp}/user-data") bytes) ---${R}"
    sed 's/^/  /' "${tmp}/user-data"
    echo "  ${DIM}--- network-config ---${R}"
    sed 's/^/  /' "${tmp}/network-config"
    rm -rf "$tmp"
    echo
    return 0
  fi
  fetch_image
  inject
  maybe_write
  report
  echo
}

main "$@"
