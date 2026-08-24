# cobe_nod — state and the 27B question

*2026-08-24. The node is **up** at `orangepi5.local` (currently 192.168.100.77;
it was 192.168.100.155 until the board moved onto a USB ethernet adapter — new
MAC, new DHCP lease). Address it by name, not by IP: the `beacon` phase
publishes mDNS precisely so a moved lease cannot lose the node again. Every
figure marked **measured** was captured on the board.*

---

## 1. Current state

### Deployed and working

| Item | State | Source |
|---|---|---|
| Board | Orange Pi 5 v1.2, RK3588S (4×A55 @1.8 GHz cpu0-3, 4×A76 @2.4 GHz cpu4-7) | measured |
| RAM | 16 GB LPDDR4X — 15,713 MB total, ~14 GB available | measured |
| Storage | 238 GB SD (boot, mmcblk1) + 512 GB Netac NVMe on PCIe 2.0 ×1 | measured |
| OS | Ubuntu 22.04.5, kernel 6.1.43-rockchip-rk3588 | measured |
| Ollama | 0.32.15 arm64, CPU-only (Mali GPU and 6 TOPS NPU unused) | measured |
| Model | `slobo` = qwen3:8b Q4_K_M, 16K ctx, num_thread 4 | measured |
| Service override | `/etc/systemd/system/ollama.service.d/cobe-nod.conf`: `OLLAMA_HOST=0.0.0.0:11434`, `OLLAMA_MODELS=/mnt/nvme/cobe-nod/models`, `OLLAMA_KV_CACHE_TYPE=q8_0`, `OLLAMA_MAX_LOADED_MODELS=1`, `OLLAMA_NUM_PARALLEL=1`, `OLLAMA_KEEP_ALIVE=-1`, `CPUAffinity=4-7` | deployed |
| Firewall | iptables chain `COBE_NOD`: 11434 accepts lo + 192.168.100.0/24, drops rest; persisted via iptables-persistent. Deliberately **not** ufw — the box runs microk8s + tailscaled and default-deny would break both | deployed |
| NVMe | Adopted, never formatted. Pre-existing: nextcloud dir (6.0 G) + backup (346 M). Models under `/mnt/nvme/cobe-nod/models` | deployed |
| Logging | journald persistent, bind-mounted to `/mnt/nvme/cobe-nod/journal` (`/var/log` is zram — volatile; crashes were erasing their own evidence) | deployed |
| Beacon | mDNS via avahi (`orangepi5.local`) + `cobe-beacon.timer` pushing full state to a collector 30 s after boot and every 5 min | deployed |
| Network | now on a USB ethernet adapter `enx1cbfce640211` (MAC `1c:bf:ce:64:02:11`), not the onboard NIC — this is why the address moved | measured |
| Extra model | `qwen3:0.6b` (522 MB) left in place deliberately as a fast triage/classification path — pulled by the aborted sweep, kept on purpose | deployed |

### Measured performance (qwen3:8b Q4_K_M)

| Metric | Value | Notes |
|---|---|---|
| Sustained generation | **3.63 tok/s** | warm, resident |
| Load when resident | 0.0 s | `KEEP_ALIVE=-1` |
| Cold load from NVMe | ~66 s | cold page cache, ~5.2 GB |
| Output quality | correct Macedonian, correct СЛОБО identity | verified |
| Mem bandwidth (A76 cluster) | 14.48 GB/s 1-thread read, **24.30 GB/s** 4-thread read, 19.51 GB/s memcpy 1-thread | custom C benchmark |
| Thermals | idle 39 °C; sustained inference: SoC 84–85 °C, big cores 88–90 °C; trips 75/85/115 °C | measured |
| Throttling | cpu6-7 drop 2208 → 1608–2016 MHz; cpu4-5 mostly hold 2352 MHz | measured |

### The stability caveat — be honest about it

Before the active-cooling upgrade, this workload hard-reset the board **three
times, each sooner than the last**. Cooling was added and a 60 s test passed.
But the board was on a DJI battery pack the whole time, and **brownout under
load was never ruled out as a cause of those resets**. Thermals are the leading
suspect, not the proven sole cause.

**Do not draw further stability conclusions until the board is on a proper
5 V/4 A (20 W) USB-C PD supply.** That is the first hardware purchase.

---

## 2. Next actions on boot

1. **Power the board from a real 5 V/4 A USB-C PD supply**, not a battery pack.
2. ~~Recover the interrupted benchmark sweep.~~ **Done — and there was nothing
   to recover.** `~/diag/sweep.csv` contains only its header row. Power died at
   03:36:30 during generation on the first model (`qwen3:0.6b`), immediately
   after its pull completed. **No sweep data exists.** The 0.6b model itself is
   still on the node and is being kept for triage work.
3. ~~Verify the deploy came back clean.~~ **Done.** Ollama enabled+active, NVMe
   remounted via the `nofail` fstab entry, `COBE_NOD` iptables rules persisted,
   models intact. The deploy survives reboots correctly.
4. **Re-run the sweep from scratch on stable power.** `~/diag/sweep.sh` is still
   on the node: qwen3:0.6b / 1.7b / 4b / 8b / 14b and qwen3.8:27b, prompt
   "Каде е Македонија?", `think:false`, `num_predict 64`. Expect the 27b row to
   fail or thrash — see §3; that failure is itself the data point.
5. **Open the collector port** so the HTTP beacon channel works (see §5).

---

## 3. The 27B question: can `qwen3.8:27b` run on this board?

### 3.1 Registry facts (verified against the Ollama registry)

- The qwen3.8 family is **27B only** (tags: `27b`, `27b-bf16`, `27b-mlx`,
  `27b-mlx-bf16`, `27b-mtp-bf16`, `27b-mtp-q4_`, `27b-mtp-q8_0`, `27b-mxfp8`,
  `27b-nvfp4`, `27b-q4_`, `27b-q8_0`, `latest`). There is no 2B–14B in the
  family — a "qwen3.8 2B→27B sweep" is impossible; the small rungs must come
  from the qwen3 (3.0) family, which is what the sweep script does.
- The registry offers **no q2/q3 tags** for 27B. Anything below Q4 means
  llama.cpp + a community GGUF from HuggingFace, outside Ollama entirely —
  and whether anyone has published sub-Q4 GGUFs of this model is itself
  unverified.
- `qwen3.8:27b` (Q4_K_M) is **17 GB on disk**. The board has ~14 GB usable.
  **It does not fit.** Everything below is about how close the alternatives get.

### 3.2 The governing equation

Dense-model token generation is memory-bandwidth bound: every weight is read
once per token, so

```
tok/s ceiling ≈ effective_read_bandwidth / model_bytes
```

Hardware ceiling: **24.30 GB/s** (measured, 4-thread A76 aggregate).
Real efficiency is lower. Sanity check against the one measured data point:
qwen3:8b Q4_K_M is ~5.0–5.2 GB and runs at 3.63 tok/s → implied effective
bandwidth **18.2–18.9 GB/s** (75–78 % of ceiling). The model is consistent;
predictions below use **~18.5 GB/s effective**.

### 3.3 Quantization ladder for 27.3B params

Size = 27.3e9 × bpw ÷ 8. bpw figures cross-checked against llama.cpp's
published tables (see sources at end).

| Quant | bpw | Weights | In Ollama registry? | Fits in RAM? | Predicted tok/s |
|---|---|---|---|---|---|
| Q4_K_M | ~4.85 | **16.6 GB** | yes (`27b`) | **No** — exceeds 14 GB before KV/OS | (1.46 absolute ceiling if it fit) |
| Q3_K_M | ~3.91 | 13.3 GB | no — llama.cpp + HF GGUF | **No, realistically** — 13.3 + KV + buffers > ~13 GB budget | ~1.4 |
| Q2_K | ~3.35 | 11.4 GB | no | Marginal — only at ≤4K ctx | ~1.6 |
| IQ2_M | ~2.70 | 9.2 GB | no | Yes, ~8K ctx | ~2.0 † |
| IQ2_XS | ~2.31 | 7.9 GB | no | Yes | ~2.3 † |

All sizes/speeds in this table are **estimates** except the bandwidth inputs.

† IQ (i-quant) formats trade size for decode compute; on CPU — especially ARM —
they run meaningfully **below** their bandwidth-implied speed. Treat the IQ2
rows as optimistic upper bounds.

**RAM budget behind the "fits?" column:** ~14 GB available − 0.6–1.5 GB
(OS + microk8s + tailscaled, estimated) − ~0.5 GB llama.cpp compute buffers
≈ **12–13 GB for weights + KV cache**. KV at q8_0 for a 27B-class model is
roughly 1–2 GB at 8–16K context (estimated; qwen3.8's hybrid attention likely
lowers it, but the exact layout is unverified).

### 3.4 What happens when it does NOT fit (the Q4_K_M paging case)

llama.cpp mmaps the weights; the OS pages the overflow from NVMe **every
token**, because token generation touches every weight and evicts in a cycle.
Overflow: 16.6 GB − ~12.5 GB cacheable ≈ **4 GB read from NVMe per token**.

| NVMe read speed | Per-token stall | tok/s | 64-token answer |
|---|---|---|---|
| ~450 MB/s (PCIe 2.0 ×1 theoretical best) | ~9 s | **~0.11** | ~10 min |
| ~87 MB/s (measured effective, 5.2 GB cold load) | ~47 s | **~0.02** | ~50 min |

Both bounds are catastrophic. This is the README's "well under 1 tok/s" claim,
now with arithmetic.

### 3.5 The non-options, dispatched

- **zram (7.7 GB) does not help.** Already-quantized weights are
  near-incompressible (~1.05×). Swapping to zram just burns CPU to move
  uncompressible data through a compressor.
- **The 6 TOPS NPU is not a path.** Ollama cannot use it; Rockchip's
  `rknn-llm` is a separate toolchain with a short supported-model list, and no
  quantization it supports fits 27B in 16 GB anyway.
- **Thermals get worse, not better.** The board already throttles at 85 °C
  running an 8B Q4 — cpu6-7 lose 10–27 % clock. A 27B run is strictly longer
  and hotter per answer, on a board whose reset history is not yet fully
  explained (see the power caveat above).

---

## 4. Verdict

**No configuration worth having.** The only quantizations that physically fit
(~IQ2_XS through Q2_K, ~8–11.4 GB) are 2-bit-class, are not in the Ollama
registry (llama.cpp + community GGUF, if one even exists for this model), and
would deliver ~1.6–2.3 tok/s *at best* on a throttling board. More
importantly: **2-bit quantization of a reasoning model destroys precisely the
capability that justifies running 27B instead of 8B.** You would get 27B's
memory footprint problems with quality plausibly below the qwen3:8b Q4_K_M
already deployed — at half its speed.

The sane architecture is the one already built:

| Work | Where | Why |
|---|---|---|
| Always-on: chat, Macedonian, triage | **Pi** — `slobo` (qwen3:8b Q4_K_M), 3.63 tok/s, resident | fits, fast enough, measured |
| Deep reasoning: `qwen3.8:27b` | **RTX 4070 box** | measured there: 31/66 layers on GPU, 52 % CPU / 48 % GPU, ~2 min cold load (`../qwen3.8/README.md`) |

The Pi's job is to make sure trivial requests never pay the 4070 box's 2-minute
cold load. It does that job now. Don't ask it to also be the 27B box.

*If* an experiment is still wanted after stable power is sorted: the honest one
is **Q3_K_M/Q2_K of qwen3.8:27b under llama.cpp at tiny context**, run once, to
put a measured number and a quality impression next to this table — as a data
point, not a deployment.

---

## 5. Open items

- [ ] **20 W USB-C PD supply** for the Pi (5 V/4 A) — before any further
      stability or thermal conclusions. Still the top item.
- [x] ~~Recover `~/diag/sweep.csv`~~ — recovered, and it holds only a header
      row. No sweep data survived; the run must start over (§2.4).
- [ ] **Open the beacon collector port.** The node builds and sends a correct
      payload, but Windows Firewall drops inbound to the WSL2 collector — the
      node can ping the host and not reach port 9977. One elevated PowerShell
      rule fixes it; see [`beacon/README.md`](beacon/README.md). Until then
      mDNS covers *finding* the node and only the pushed state is missing.
- [ ] **Isolate the reset cause**: rerun the sustained-load test on mains
      power with cooling — only then attribute the pre-cooling resets.
- [ ] **GUI question** (user plugged in a wireless mouse): not started. The
      board is a headless inference node; a desktop environment costs RAM the
      model budget needs. If desktop use is actually wanted, recommend
      something minimal (a lightweight WM, e.g. labwc/openbox class), installed
      knowingly — not a full DE.
- [ ] Optional: the one-off Q3/Q2 llama.cpp experiment above, strictly after
      power is stable.

---

*bpw figures cross-checked 2026-08-24 against llama.cpp's quantize docs and
published measurements:
[llama.cpp quantize README](https://github.com/ggml-org/llama.cpp/blob/master/tools/quantize/README.md),
[llama.cpp discussion #2094](https://github.com/ggml-org/llama.cpp/discussions/2094),
[K-quants vs I-quants comparison](https://kaitchup.substack.com/p/choosing-a-gguf-model-k-quants-i).*
