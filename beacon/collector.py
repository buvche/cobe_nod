#!/usr/bin/env python3
"""
collector.py -- receives beacons from СЛОБО nodes.

Runs on the main box. Nodes POST their state here on boot and on a timer, so a
node that changes DHCP address (or moves to a different NIC, which is how
192.168.100.155 became .77) announces its new address instead of going missing.

  ./collector.py                 # listen on 0.0.0.0:9977
  ./collector.py --list          # print what is known, don't listen
  ./collector.py --port 9977 --state-dir ~/.cobe-nod

State, under --state-dir:
  nodes.json    current state per node_id, overwritten each beacon
  nodes.jsonl   append-only history, one beacon per line

Endpoints:
  POST /beacon   a node checking in
  GET  /         human-readable table of known nodes
  GET  /nodes    the same as JSON
"""
import argparse
import json
import os
import sys
import time
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

STATE_DIR = os.path.expanduser("~/.cobe-nod")
MAX_BODY = 64 * 1024          # a beacon is ~1KB; anything larger is not ours


def _paths(state_dir):
    return os.path.join(state_dir, "nodes.json"), os.path.join(state_dir, "nodes.jsonl")


def load_nodes(state_dir):
    cur, _ = _paths(state_dir)
    try:
        with open(cur) as f:
            return json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        return {}


def save_beacon(state_dir, payload, peer_ip):
    os.makedirs(state_dir, exist_ok=True)
    cur, hist = _paths(state_dir)

    node_id = payload.get("node_id") or payload.get("hostname") or peer_ip
    payload["_received_at"] = datetime.now(timezone.utc).isoformat()
    payload["_peer_ip"] = peer_ip

    nodes = load_nodes(state_dir)
    prev = nodes.get(node_id, {})
    # Surfacing an address change is the whole point of this thing.
    prev_ip = (prev.get("net") or {}).get("ip")
    new_ip = (payload.get("net") or {}).get("ip")
    changed = bool(prev_ip and new_ip and prev_ip != new_ip)
    payload["_first_seen"] = prev.get("_first_seen", payload["_received_at"])

    nodes[node_id] = payload
    tmp = cur + ".tmp"
    with open(tmp, "w") as f:
        json.dump(nodes, f, indent=2, ensure_ascii=False)
    os.replace(tmp, cur)          # atomic: never leave a torn nodes.json

    with open(hist, "a") as f:
        f.write(json.dumps(payload, ensure_ascii=False) + "\n")

    return node_id, changed, prev_ip


def fmt_uptime(s):
    try:
        s = int(s)
    except (TypeError, ValueError):
        return "?"
    d, s = divmod(s, 86400)
    h, s = divmod(s, 3600)
    m = s // 60
    return f"{d}d{h}h{m}m" if d else (f"{h}h{m}m" if h else f"{m}m")


def render(nodes):
    if not nodes:
        return "no nodes have checked in yet\n"
    now = time.time()
    rows = []
    for nid, n in sorted(nodes.items(), key=lambda kv: kv[1].get("hostname", "")):
        net = n.get("net") or {}
        th = n.get("thermal") or {}
        ol = n.get("ollama") or {}
        try:
            age = now - datetime.fromisoformat(n["_received_at"]).timestamp()
            age = f"{int(age)}s" if age < 120 else f"{int(age/60)}m"
        except Exception:
            age = "?"
        rows.append((
            n.get("hostname", "?"), net.get("ip", "?"),
            (n.get("board") or "?")[:18],
            f'{th.get("soc_c","?")}C', str(n.get("load1", "?")),
            fmt_uptime(n.get("uptime_s")),
            f'{ol.get("state","?")}',
            ",".join(ol.get("resident") or []) or "-",
            age,
        ))
    hdr = ("HOST", "IP", "BOARD", "TEMP", "LOAD", "UPTIME", "OLLAMA", "RESIDENT", "AGE")
    w = [max(len(str(r[i])) for r in (rows + [hdr])) for i in range(len(hdr))]
    out = ["  ".join(h.ljust(w[i]) for i, h in enumerate(hdr))]
    out.append("  ".join("-" * w[i] for i in range(len(hdr))))
    for r in rows:
        out.append("  ".join(str(c).ljust(w[i]) for i, c in enumerate(r)))
    return "\n".join(out) + "\n"


class Handler(BaseHTTPRequestHandler):
    state_dir = STATE_DIR

    def log_message(self, *a):
        pass                       # we print our own, quieter lines

    def _send(self, code, body, ctype="text/plain; charset=utf-8"):
        b = body.encode() if isinstance(body, str) else body
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def do_POST(self):
        if self.path.rstrip("/") not in ("/beacon", ""):
            return self._send(404, "not found\n")
        try:
            n = int(self.headers.get("Content-Length", 0))
        except ValueError:
            return self._send(400, "bad length\n")
        if n <= 0 or n > MAX_BODY:
            return self._send(413, "body too large\n")
        try:
            payload = json.loads(self.rfile.read(n))
            if not isinstance(payload, dict):
                raise ValueError("not an object")
        except Exception as e:
            return self._send(400, f"bad json: {e}\n")

        peer = self.client_address[0]
        nid, changed, prev_ip = save_beacon(self.state_dir, payload, peer)
        net = payload.get("net") or {}
        th = payload.get("thermal") or {}
        stamp = datetime.now().strftime("%H:%M:%S")
        line = (f"[{stamp}] {payload.get('hostname','?')} @ {net.get('ip', peer)} "
                f"{th.get('soc_c','?')}C load={payload.get('load1','?')} "
                f"up={fmt_uptime(payload.get('uptime_s'))} "
                f"ollama={(payload.get('ollama') or {}).get('state','?')}")
        if changed:
            line += f"   <-- ADDRESS CHANGED (was {prev_ip})"
        print(line, flush=True)
        self._send(200, "ok\n")

    def do_GET(self):
        nodes = load_nodes(self.state_dir)
        if self.path.rstrip("/") == "/nodes":
            return self._send(200, json.dumps(nodes, indent=2, ensure_ascii=False),
                              "application/json; charset=utf-8")
        self._send(200, render(nodes))


def main():
    ap = argparse.ArgumentParser(description="СЛОБО node beacon collector")
    ap.add_argument("--port", type=int, default=9977)
    ap.add_argument("--bind", default="0.0.0.0")
    ap.add_argument("--state-dir", default=STATE_DIR)
    ap.add_argument("--list", action="store_true", help="print known nodes and exit")
    a = ap.parse_args()

    a.state_dir = os.path.expanduser(a.state_dir)
    if a.list:
        sys.stdout.write(render(load_nodes(a.state_dir)))
        return

    os.makedirs(a.state_dir, exist_ok=True)
    Handler.state_dir = a.state_dir
    srv = ThreadingHTTPServer((a.bind, a.port), Handler)
    print(f"collector listening on {a.bind}:{a.port}  state={a.state_dir}", flush=True)
    print("nodes POST to /beacon ; GET / for a table", flush=True)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        print("\nstopped", flush=True)


if __name__ == "__main__":
    main()
