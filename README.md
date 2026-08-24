# cobe_nod

Deploy a **СЛОБО node** on any hardware — a second Ollama endpoint on the LAN
serving the Macedonian СЛОБО model, so the GPU box is not woken up for small
work.

First target: **Orange Pi 5 (v1.2 board, RK3588S, 16 GB LPDDR4X, 512 GB NVMe)**,
booted from an SD image that deploys itself. Plug it in, give it power and
ethernet, and it comes up serving.

```bash
./build-sd.sh --nvme /dev/nvme0n1     # on this box: bake the SD image
#   flash the .img from Windows, card into the Pi, power on
ssh cobe-nod-01.local 'journalctl -fu cobe-nod-firstboot'   # watch it build itself
curl http://cobe-nod-01.local:11434/api/tags                # it's up
```

---

## What "sharing the load" actually means here

The node shares load with the main box (Ryzen 5500 / RTX 4070 12 GB) **at the
request level**, not the tensor level:

| Work | Where | Why |
|---|---|---|
| Chat, Macedonian replies, inbox triage, classification | **Pi** | small, constant, latency-sensitive |
| Deep reasoning (`qwen3.8:27b`) | **main box** | needs the 4070 and 17 GB of weights |

The win is not raw throughput — it is that trivial requests stop costing you a
**~2 minute cold load of a 17 GB model** on the main box. The Pi keeps its
model resident (`OLLAMA_KEEP_ALIVE=-1`) and answers immediately, and the 27B is
only paged in when a job genuinely needs it.

### Two things this node cannot do

**Run `qwen3.8:27b`.** It is 17 GB; the board has 16 GB of RAM total. It does
not fit. Paging it off the NVMe puts generation well under 1 tok/s, because
token generation on a dense model is memory-bandwidth bound and RK3588 has a
fraction of the bandwidth the 4070 does. The 27B stays on the GPU box.

**Split one model's layers with the main box.** llama.cpp's RPC backend can
distribute layers across machines in principle, but 1 GbE moves ~118 MB/s where
system memory moves gigabytes per second — the interconnect becomes the
bottleneck and the pair runs *slower* than either machine alone. Ollama does
not expose that backend anyway. Route whole requests, don't split tensors.

### What to expect from the Pi

`cobe-nod.sh` sizes the model to the board's RAM:

| RAM | base model | on-disk | context |
|---|---|---|---|
| ≥ 14 GB | `qwen3:8b` | ~5 GB | 16384 |
| ≥ 7 GB | `qwen3:4b` | ~2.6 GB | 8192 |
| ≥ 3.5 GB | `qwen3:1.7b` | ~1.4 GB | 4096 |
| below | `qwen3:0.6b` | | 4096 |

The 16 GB Orange Pi 5 therefore gets **`qwen3:8b` at 16K context**. Measured on
one (RK3588S, 16 GB, Ubuntu 22.04, active cooling):

| | |
|---|---|
| Sustained generation | **3.63 tok/s** |
| Load when resident | 0.0 s (`OLLAMA_KEEP_ALIVE=-1`) |
| Cold load from NVMe | ~66 s, once per boot |
| Idle / under load | 39°C / 84–85°C SoC, 88–90°C big cores |

Under sustained load the SoC plateaus at the 85°C trip point and the governor
throttles to hold it: `cpu6-7` drop from 2208 MHz to 1608–2016 MHz while
`cpu4-5` mostly hold 2352 MHz. That is the thermal design limit, not a fault —
but it does mean **cooling directly buys tok/s** on this board.

**Cooling is not optional.** Before an active cooler was fitted, this exact
workload hard-reset the board three times, each reset sooner than the last,
until it stopped coming back without a power cycle. With cooling it runs a full
minute of generation at a stable 85°C. If you deploy to an RK3588 board, fit a
heatsink and a fan first.

Real tok/s is whatever `./cobe-nod.sh verify` measures on your board — it prints cold load
time and sustained generation speed and writes them to
`/var/lib/cobe-nod/node.json`. Trust that number over any estimate, including
one in this README. Override with `--model` if you want to trade quality for
speed (`qwen3:4b`) or the reverse.

Two RK3588-specific choices the script makes, both of which matter more than
they look:

- **`CPUAffinity=4-7`** — RK3588's `cpu0-3` are slow Cortex-A55s and `cpu4-7`
  are fast A76s. Handing llama.cpp all eight makes every token wait on the
  A55s. Pinning to the A76 cluster is faster than using the whole chip.
- **model store on NVMe** — the SD card is the worst possible home for a model
  store: gigabytes of writes per pull, random reads on every load, and flash
  wear that eventually kills the card.

The Mali-G610 GPU and the 6 TOPS NPU are **not** used. Ollama on RK3588 is
CPU-only; the NPU needs Rockchip's separate `rknn-llm` toolchain and a
converted model, which is a different project from this one.

---

## The two scripts

### `build-sd.sh` — bake the self-deploying image (runs here)

Downloads [Joshua Riek's ubuntu-rockchip](https://github.com/Joshua-Riek/ubuntu-rockchip)
Ubuntu 24.04 arm64 server image for the Orange Pi 5, verifies its SHA256, and
injects a cloud-init payload into the image's `CIDATA` partition. That payload
carries `cobe-nod.sh` itself (base64, so the node needs no access to this repo),
your SSH key, and a `cobe-nod-firstboot.service` oneshot that runs the deploy
on first boot and retries on failure.

```
--release TAG    ubuntu-rockchip release, default v2.4.0
--ubuntu VER     24.04 (default) or 22.04
--board NAME     orangepi-5 (default), orangepi-5-plus, orangepi-5-max, ...
--hostname NAME  default cobe-nod-01
--user NAME      login user on the node, default $USER
--key PATH       ssh public key, default the first ~/.ssh/*.pub
--model NAME     force the base model instead of sizing it to RAM
--nvme DEV       use this device as the model store; an existing filesystem
                 is ADOPTED, not erased
--format         only with --nvme: erase that device on first boot (unattended)
--firewall-mode  'ufw' (default) or 'targeted' — see Security below
--wifi 'S:P'     wifi SSID and passphrase (omit for ethernet DHCP)
--out PATH       output image path
--write DEV      flash to a block device (asks twice)
--dry-run        print the cloud-init payload and stop
```

**Under WSL2 you cannot flash the card directly** — a USB reader plugged into
Windows is not a Linux block device without `usbipd-win`. So the script writes
an `.img` and prints the Windows path; flash it with Raspberry Pi Imager
(*Use custom*), balenaEtcher, or USBimager. Do **not** let Imager apply its own
OS customisation — it would overwrite the cloud-init that was just injected.

Sanity-check what will be baked before you bake it:

```bash
./build-sd.sh --dry-run --nvme /dev/nvme0n1
```

### `cobe-nod.sh` — the deploy itself (runs on the node)

Nothing about it is Orange Pi specific; it is what makes the repo's promise
("any hardware") true. Copy it to any Ubuntu/Debian arm64 or x86_64 box with
sudo and run it. Every phase is idempotent.

```bash
sudo ./cobe-nod.sh all --nvme /dev/nvme0n1
sudo ./cobe-nod.sh detect          # reports only, changes nothing
```

`--nvme` **adopts** whatever filesystem is already on the disk — it mounts it
and puts models in a `cobe-nod/models` subdirectory. Erasing is a separate,
explicit `--format`, never implied. A disk with someone's data on it is the
normal case, not the exception.

| Phase | Does |
|---|---|
| `detect` | board, arch, RAM, storage, subnet; prints the plan. Read-only. |
| `deps` | `curl jq` + the firewall tooling (`parted gdisk` only with `--format`) |
| `storage` | mount the NVMe as the model store — adopting any filesystem already on it |
| `ollama` | install Ollama + hardened systemd override |
| `firewall` | restrict 11434 to the local subnet (`ufw` or `targeted`) |
| `model` | pull the base model sized to this board's RAM |
| `slobo` | render the Modelfile, `ollama create slobo` |
| `beacon` | mDNS + a boot/timer beacon so the node announces itself |
| `verify` | real Macedonian prompt; prints cold load time and tok/s |

`slobo/Modelfile.tmpl` holds the Macedonian system prompt (identity, Cyrillic,
the grammar rules that keep it off Serbian). `FROM`, `num_ctx`, and
`num_thread` are substituted at deploy time from what the hardware can hold.

---

## Security

**Ollama has no authentication.** Anything that reaches port 11434 can run
inference, list models, and pull or delete them.

The node binds `0.0.0.0` so the main box can reach it, and the firewall then
scopes 11434 to the node's own subnet, derived from its own interface. **Bind
and firewall are a pair — keep both.** Remove the rule and you have published
an unauthenticated LLM endpoint to every network that board ever joins.

Two ways to enforce it, because the right answer depends on what else the box
does:

- **`ufw`** (default) — enables ufw with default-deny incoming. Correct for a
  dedicated node, e.g. one built from the SD image.
- **`targeted`** — inserts an iptables chain that filters *only* port 11434 and
  leaves global policy untouched. Use this on a box already running other
  services: default-deny would cut off a k8s cluster or a tailnet. The `ufw`
  mode detects listening k8s/tailscale ports and asks before enabling.

Never port-forward 11434 on the router. Never enable UPnP for it.

The image is key-only: `ssh_pwauth: false`, root login disabled, and the stock
`ubuntu`/`ubuntu` password login of the base image is not used. `--nvme` is
the only destructive flag, it is never implied, and on an interactive run it
asks before erasing anything.

---

## Related

- [`../слобо`](../слобо) — the СЛОБО project this node serves (ngo-brain, chat
  UI, voice/hearing clients, the WP4 agent loop)
- [`../qwen3.8`](../qwen3.8) — `qwen3.8:27b` on the main box, and the eval
  harness that gates deploys
- [`../inference-node`](../inference-node) — the earlier SSH-driven bootstrap
  aimed at one specific LAN host

## Finding a node

Node addresses come from DHCP and they move — `192.168.100.155` became
`192.168.100.77` when the board went onto a USB ethernet adapter. The `beacon`
phase makes a node announce itself instead, over two channels: mDNS
(`<hostname>.local`, needs nothing running on the other end) and an HTTP push
carrying full state to a collector. See [`beacon/README.md`](beacon/README.md).

```bash
ssh orangepi@orangepi5.local          # mDNS: no IP needed, ever
./beacon/collector.py --list          # what has checked in, and when
```

## Deployed nodes

| Node | Hardware | Model | Speed |
|---|---|---|---|
| `orangepi5.local` | Orange Pi 5, RK3588S, 16 GB, 512 GB NVMe | `slobo` / `qwen3:8b` Q4_K_M, 16K ctx | 3.63 tok/s |

Deployed with `--nvme /dev/nvme0n1 --firewall-mode targeted`, since that board
also runs microk8s, tailscale, and a Nextcloud data directory on the NVMe.
`/var/log` there is on zram, so journald was pointed at persistent storage on
the NVMe — otherwise every crash erases its own evidence, which is exactly what
happened during the pre-cooling resets.
