# Furina — GPU Box Bring-Up Runbook

Day-one runbook for the new GPU host (`furina`) that replaces `raiden`.
Hardware ordered 2026-06-23, **arriving Friday 2026-06-26**.

## Hardware (as ordered)

| Part | Model |
|------|-------|
| GPU | PNY NVIDIA RTX 5070 Ti OC — **16GB GDDR7**, Blackwell, PCIe 5.0 |
| CPU | AMD Ryzen 7 9800X3D (8c/16t, AM5) |
| Mobo | MSI MAG B850 Tomahawk MAX WiFi (ATX) |
| RAM | G.SKILL Flare X5 DDR5-6000 CL36 64GB (2x32) — AMD EXPO |
| PSU | be quiet! Pure Power 13 M 1000W (ATX 3.1, PCIe 5.1) |
| Cooler | Noctua NH-D15 chromax.Black |
| Boot/scratch | Samsung 990 Pro 2TB NVMe Gen4 |
| Case | be quiet! Pure Base 501 (vertical GPU mount) |

> **VRAM is 16GB, not the 24GB in the old plan.** Model sizing below reflects that.

## Decision summary

- **Topology**: Proxmox host + **GPU passthrough to a VM** (reverses the earlier
  bare-metal plan — keeps furina consistent with aether/nahida and inside GitOps).
- **Role**: replaces `raiden` (old OptiPlex 7020, ~11yr, power-hog).
- **Control plane**: already on **aether** (VM 201) — raiden only runs
  `raiden-worker` (VM 211), so retiring it is a drain + remove, **no CP migration**.

---

## Phase 0 — Proxmox host install + passthrough prep

1. Install Proxmox VE on furina; join the PVE cluster (API `192.168.1.100:8006`).
   Set up SSH-over-Tailscale (`ssh root@furina`) like the other hosts.
2. **BIOS**: enable AMD-Vi/IOMMU + SVM. Enable the **EXPO** profile for DDR5-6000.
3. **Kernel cmdline**: add `amd_iommu=on iommu=pt`.
4. **vfio-pci**: bind the 5070 Ti's GPU + HDMI-audio functions; blacklist
   `nouveau`/`nvidia` on the host so PVE doesn't claim the card.
5. Verify the GPU sits in its **own clean IOMMU group** (GPU + audio function).
   - Blackwell resets cleanly via FLR — should **NOT** hit the Vega PCI-reset boot
     hang we get on aether (see `aether-gpu-passthrough-boot-hang`). Confirm anyway.
6. Create the inference VM (Ubuntu 22.04 to match the cluster), pass through the
   GPU group, install NVIDIA drivers + CUDA + `nvidia-container-toolkit` inside it.

## Phase 1 — Burn-in / benchmark (DO BEFORE TRUSTING IT — still returnable)

Run inside the VM once passthrough works:

- `nvidia-smi` sanity; watch live with `nvtop`.
- **`gpu-burn` ~30–60 min** — temps should stay <83°C, **zero XID errors** in `dmesg`.
- GDDR7 memory stress (Blackwell-aware run — brand-new memory type).
- CPU/RAM: `stress-ng` + `mprime95` to confirm the **EXPO DDR5-6000** profile is
  stable (CL36 kit — validate before trusting it).
- **Throughput baseline**: quick `llama.cpp`/vLLM run, record tokens/sec to compare later.

## Phase 2 — GPU Whisper + whole-library subtitle strategy

Goal (decided 2026-06-23): subtitles for the **entire library** + **auto-subs for new
media**. CPU couldn't do the full backfill — subgen's own config notes
`TRANSCRIBE_FOLDERS=/media` OOM-looped on a 10Gi node and never converged. The GPU
makes it feasible. The in-cluster `ollama` is CPU today and also moves here.

### Subtitle architecture (hybrid — decided 2026-06-24)

User wants: English subs from **English/dub audio that follow the spoken audio**; for
sub-only foreign content, rely on **existing real translations** (NO machine
translation). So:

| Job | Owner | Notes |
|-----|-------|-------|
| Fill **genuinely missing** subs (backfill + new) | **Bazarr** (NEW app) | Real fansub/pro providers first, Whisper as last-resort fallback. DB-tracked → restart-safe (fixes the in-memory requeue pain). |
| **Dub-matching** (sub exists but mismatches the dub) | **subgen** | Bazarr's only-if-missing model can't express "generate even though a sub exists" — keep subgen's webhook + folder batches (`SKIP_IF_TARGET_SUBTITLES_EXIST: False`). |
| Machine-translate foreign audio | **nobody** | **Retire `whisper-jellyfin`** (its `translate` task = the unwanted MT path). |

> **Bazarr Whisper-provider caveat**: its Whisper provider auto-*translates* when audio
> ≠ target language. We do NOT want that — configure Whisper as fallback only, after
> real providers, so foreign content gets real subs not MT. Don't let Bazarr translate.

### Steps

1. Join furina's VM to k0s as a worker; install the **NVIDIA device plugin** so pods
   request `nvidia.com/gpu: 1`. Pin GPU workloads to furina via nodeSelector/affinity.
2. **subgen → GPU**: `TRANSCRIBE_DEVICE: cuda`, `WHISPER_MODEL: large-v3`. Keep its
   logic as-is (`transcribe` + `PREFERRED_AUDIO_LANGUAGES: eng` +
   `LIMIT_TO_PREFERRED_AUDIO_LANGUAGE: True` already = "English/dub audio only, skip
   Japanese-only"). `MONITOR: True` already auto-queues new Sonarr/Radarr imports.
3. **Add Bazarr** (`kubernetes/apps/bazarr/`): wire to Sonarr + Radarr; real providers
   first; Whisper (subgen ASR endpoint) as fallback. This is the robust orchestrator.
4. **Retire `whisper-jellyfin`** — delete the app (unwanted MT translate path).
5. **Backfill restart trap**: subgen's queue is in-memory and rebuilds on restart;
   for the dub-matching set keep folder batches and remove shows once done (current
   practice). Bazarr's DB state covers the gap-fill set safely.
6. **Schedule the big backfill overnight** — it pegs the GPU; don't fight LLM/gaming
   for VRAM. Expect ~30–60× real-time (24-min ep ≈ 30–60s; total ≈ library-hours/45).
7. Expect **~10–30×** per-file speedup over the old CPU path.

## Phase 3 — Local LLM server (flagship)

> **SUPERSEDED / BUILT 2026-07-03** — implemented as the Pneuma platform
> (vLLM + LiteLLM + KEDA scale-to-zero + RAG, fully GitOps): see
> `Documentation/pneuma/README.md`. The Omarchy VM itself became k0s worker
> `pneuma`; ollama was retired, open-webui retargeted at the gateway
> (192.168.1.55). The notes below are kept for history.

- vLLM or Ollama serving an OpenAI-compatible endpoint; retarget the in-cluster
  **Open WebUI** (`kubernetes/apps/open-webui`) from CPU ollama to furina.
- **16GB-friendly models**: Qwen2.5-14B / Qwen2.5-Coder-14B (coding), Llama-3.1-8B,
  Gemma-2-27B@Q4 (tight). 32B@Q4 won't fit comfortably — that was the 24GB plan.
- VRAM sharing w/ gaming: low/zero `keep_alive` so the GPU frees VRAM for games.

## Phase 3.5 — Gaming + remote access (Sunshine / Moonlight)

Gaming role (decided 2026-06-24): **single-player / Proton titles** (no kernel
anti-cheat → passthrough VM is fine). OS leaning **Omarchy** (Arch + Hyprland) or
Bazzite; run games via **gamescope + Proton-GE**, MangoHud for overlay.

**Remote desktop / "see my screen when away" = Sunshine (host) + Moonlight (client).**
Still the standard combo (Sunshine = LizardByte, the GameStream successor). Streams the
**whole desktop, not just games**, so it covers general remote access too.

- **Where it runs**: Sunshine runs **inside the GPU VM** (it needs the passed-through
  GPU for NVENC). Single GPU → whichever VM holds the card is the one you can stream
  from. Keeping furina as **one VM** (dev + LLM + gaming) means Sunshine is always
  available whenever that VM is up. Blackwell NVENC does **AV1** — excellent quality.
- **Display-capture gotcha (the big "when away" trap)**: Sunshine captures *a screen* —
  if furina is headless or the display sleeps, there's nothing to capture. Fix with an
  **HDMI dummy plug** (cheap) or a configured **virtual display** so a desktop always exists.
- **Wayland/Hyprland**: if on Omarchy, Sunshine capture works via KMS/wlroots but needs
  more setup than X11 (not zero-config). On X11 it's plug-and-play.
- **Remote-from-anywhere**: use **Moonlight over Tailscale** (furina's already on the
  tailnet) — encrypted, no port-forwarding, just hit the tailnet IP.
- **Lightweight backup**: for "just check in / fix something" when Sunshine's display is
  asleep, keep a light remote tool (**RustDesk** / **NoMachine**) over Tailscale as the
  always-works fallback. Many run both.

## Phase 4 — Decommission raiden

1. `kubectl drain raiden-worker --ignore-daemonsets --delete-emptydir-data`
2. **Longhorn**: going 3→2 workers temporarily then 2→3 (with furina) — set replica
   count to match node count through the swap to avoid permanent-degraded
   (see `longhorn-replica-count-and-orphan-cleanup`). Clean up the dead raiden node
   in Longhorn after removal (see `longhorn-dead-node-cleanup`).
3. `kubectl delete node raiden-worker`; remove VM 211; pull raiden from PVE cluster.
4. Physically retire the OptiPlex.

## Gotchas / cross-refs

- Bring switch/router/gateway up BEFORE any host or it boots into quorum isolation
  (the raiden "death" lesson).
- Custom images for the cluster must be built `--platform linux/amd64` (Mac is arm64) —
  see `docker-build-amd64-for-cluster`.
- Single GPU: gaming and cluster/inference GPU workloads can't run simultaneously —
  whichever VM holds the card wins. Simplest is one VM (dev + LLM + gaming) so there's
  no swapping (see Phase 3.5).
