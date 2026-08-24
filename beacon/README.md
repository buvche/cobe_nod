# beacon — nodes announce themselves

A node's address is handed out by DHCP, so it moves. It moved once already:
`192.168.100.155` became `192.168.100.77` when the board was put on a USB
ethernet adapter — different MAC, new lease — and the node was unfindable until
someone swept the subnet. A node that announces itself cannot be lost.

Two independent channels, because each fails differently.

## 1. mDNS — always works, no infrastructure

`avahi-daemon` on the node publishes `<hostname>.local`. Nothing needs to be
running on the other end and no firewall rule is involved.

```bash
ssh orangepi@orangepi5.local
curl http://orangepi5.local:11434/api/tags
```

Requires an mDNS resolver on the machine doing the lookup:

```bash
sudo apt-get install -y avahi-daemon avahi-utils libnss-mdns
```

This channel tells you *where* the node is, not *how* it is.

## 2. HTTP beacon — full state, needs the collector reachable

`cobe-beacon.service` fires 30 s after boot and every 5 min thereafter
(`cobe-beacon.timer`), POSTing JSON to the collector: board, all addresses,
MAC, uptime, SoC/bigcore temps, load, memory, Ollama state and version, the
model list, which model is resident, and free space on the model store.

The beacon **never fails hard** — an unreachable collector logs a line and
exits 0. The timer is the retry.

```bash
./collector.py                  # listen on 0.0.0.0:9977
./collector.py --list           # print what's known, don't listen
curl http://127.0.0.1:9977/     # table of nodes
curl http://127.0.0.1:9977/nodes # same as JSON
```

State in `~/.cobe-nod/`: `nodes.json` (current, atomic writes) and
`nodes.jsonl` (append-only history). An address change is called out
explicitly on the collector's console.

Install on a node:

```bash
sudo ./cobe-nod.sh beacon --beacon-url http://<collector>:9977/beacon
```

Without `--beacon-url` the phase still sets up mDNS, so channel 1 works alone.

### WSL2: the collector needs a firewall rule

If the collector runs under WSL2, Windows Firewall drops inbound connections to
it even in mirrored networking mode — the node can ping the host but not reach
the port. In an **Administrator** PowerShell on Windows:

```powershell
New-NetFirewallRule -DisplayName "cobe-nod beacon" -Direction Inbound `
  -LocalPort 9977 -Protocol TCP -Action Allow
```

Mirrored mode also filters at the Hyper-V layer; if the rule above is not
enough, add:

```powershell
New-NetFirewallHyperVRule -Name "CobeNodBeacon" -DisplayName "cobe-nod beacon" `
  -Direction Inbound -VMCreatorId '{40E0AC32-46A5-438A-A0B2-2B479E8F2E90}' `
  -Protocol TCP -LocalPorts 9977 -Action Allow
```

Until then, mDNS covers finding the node; only the pushed state is missing.
