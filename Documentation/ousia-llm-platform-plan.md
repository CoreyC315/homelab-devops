# Ousia LLM Platform — Implementation Plan

> Status: **Phase 0 COMPLETE 2026-08-10.** Phases 1+ not started.
> Context: RTX 3090 (24GB) landed 2026-08-10. New Proxmox VM `ousia` on host `furina`, separate from the existing gaming VM `pneuma` (5070 Ti). `pneuma` exits the k0s cluster entirely (goes back to gaming-only); `ousia` joins as the new dedicated GPU worker. This supersedes the torn-down `pneuma-inference-platform` build (commit `5db5028` removed vLLM) — same stack, different node, built to be permanent this time since gaming no longer competes for the GPU.
>
> Reuse sources: `Documentation/pneuma/{README,build-log,phase-0-node}.md` (prior build log + operational rules), `Documentation/furina-gpu-box-runbook.md` (Proxmox bring-up pattern already proven on `pneuma`).

## Phase 0 — actual results (2026-08-10)

**Node**: `ousia`, VMID 103 on furina. Debian 13 (trixie) cloud image (not netinst — interactive installer is impractical on a headless passthrough box with no monitor on the GPU output). 6 cores / 12GB RAM / 60GB disk — sized to what was free on furina (`pneuma` already holds 10 cores/40GB of the host's 16c/60GB). Static IP `192.168.1.215/24` via a hand-written `systemd-networkd` `.network` file (netplan's own generation was unreliable — see gotchas). Joined k0s via token (`k0s token create --role=worker` on the controller, same precedent as `pneuma`), labeled `teyvat.io/gpu=true`, tainted `nvidia.com/gpu=present:NoSchedule`.

**Driver**: NVIDIA 550.163.01 (proprietary, DKMS, installed via `apt` from Debian's `non-free` component — the driver lives in `non-free`, not `non-free-firmware`). CUDA 12.4 toolkit installed alongside. `gpu-burn` (built from source) ran 60s at 100% load: **stable ~348W (at the 350W cap, no dangerous transients), 78°C peak, 0 errors, 0 XID faults**. A longer 30-60min soak per the original bring-up runbook is still worth doing before fully trusting it long-term.

**VRAM tested clean 2026-08-11**: `cuda_memtest` (github.com/ComputationalRadiationPhysics/cuda_memtest, built from source — `apt install cmake`, `cmake .. -DCMAKE_CUDA_ARCHITECTURES=86`) ran the full default 9-test suite (walking-bit, own-address, moving-inversions ×4 variants, block-move, random-sequence, modulo-20, stress) across the entire ~24GB, one pass, **zero memory errors**, ~8.5 min total, Test10 measured ~5.2TB/s effective bandwidth. The only "error"-matching log line was NVML failing to read a serial number (metadata-only, common on GeForce cards, unrelated to memory correctness). Bit-fade (Test9, needs hours of idle time to be meaningful) was skipped — not run yet. Card is confirmed solid on both compute and memory; owner has signed off as good to go.

**k8s GPU stack**: cluster already runs a full **NVIDIA GPU Operator** (namespace `gpu-operator`) rather than a bare device plugin — its DaemonSets (device-plugin, dcgm-exporter, gpu-feature-discovery, node-feature-discovery) scheduled onto `ousia` automatically via the taint/label match. End-to-end proven with a real pod: `runtimeClassName: nvidia` + `resources.limits.nvidia.com/gpu: 1` → `nvidia-smi` inside the container sees the 3090 cleanly. **`runtimeClassName: nvidia` is required on any pod that wants the GPU** — without it containerd uses the default runtime and no driver libs get injected (fails with "nvidia-smi: executable file not found", not an obvious GPU error).

### Gotchas hit during bring-up (read before doing this again)

1. **NIC name flip-flops on furina across every reboot** (`enp8s0` ⇄ `enp9s0`) — adding/removing the 3090 shifts PCI enumeration order each boot, so `/etc/network/interfaces`' `bridge-ports` goes stale and furina loses network. Recurred 3 times during this bring-up. Fix needed (not yet done): a MAC-pinned udev `.link` rule so the NIC gets a fixed name regardless of enumeration order.
2. **GPU PCI address also shifts on host reboot** (`03:00.0` was the 3090, then became a chipset bridge after one reboot) — same root cause as #1. Always re-`lspci -nn | grep -i nvidia` after a furina reboot before assuming a hostpci address is still correct.
3. **3090 stuck in D3cold after a failed `qm start`** — vfio-pci can't wake a device from D3cold in software; needed a full furina power cycle (not just VM restart) to clear. `cat /sys/bus/pci/devices/<addr>/power_state` is the tell.
4. **3090 dropped off the PCI bus entirely after one reboot** — traced to the riser cable under mechanical strain from the case-clearance fight; physically reseating both ends of the riser fixed it. Confirms the case-fit problem is a real reliability risk, not just cosmetic — the [[VG4v4 vertical mount]] fix is not optional.
5. **`x-vga=1` on a passthrough GPU with no monitor attached to it = silent hang.** For a headless compute-only VM, use `vga: serial0` (redirects OVMF+console to the serial socket, readable via `qm terminal`) and leave the GPU as a plain secondary passthrough device (no `x-vga`). Also incidentally avoids Proxmox's automatic `kvm=off` cpu flag (added automatically alongside `x-vga` on Nvidia cards to dodge Windows driver code-43 — irrelevant here and better left off).
6. **Debian cloud image's netplan didn't reliably generate its `systemd-networkd` unit files** (`/etc/systemd/network/` stayed empty despite a valid `/etc/netplan/50-cloud-init.yaml`) — root cause never fully isolated (possibly a race on first boot). Worked around by writing the `.link`/`.network` files directly and deleting the netplan yaml; **file naming matters** — a hand-written file must sort lexically before any netplan-generated one in `/run/systemd/network/` (e.g. `05-eth0.network` beats `10-netplan-eth0.network`) or it's silently ignored.
7. **k0s bundles containerd 1.7.x, whose CRI plugin ID is `io.containerd.grpc.v1.cri`** — NOT `io.containerd.cri.v1.runtime` (that's the containerd 2.x-era ID). Using the wrong one in the `/etc/k0s/containerd.d/nvidia.toml` drop-in parses fine and fails completely silently (no error, the `nvidia` runtime just never registers) — this is already called out in `Documentation/pneuma/build-log.md` but easy to get wrong again from memory instead of copying verbatim.
8. **GPU Operator's built-in `nvidia-cuda-validator` self-check crash-loops** (`forward compatibility was attempted on non supported HW`) on a host-driver install like this one — cosmetic, doesn't affect real GPU scheduling (proven by the manual smoke-test pod above). Don't chase this fully green; verify with a real workload instead.

---

---

## Guiding principles

- **GitOps only.** Everything under `kubernetes/apps/` and `kubernetes/infrastructure/`, ArgoCD-synced. No hand-applied manifests beyond what's already documented as an exception (secrets).
- **Reuse the working parts of the old build.** LiteLLM, KEDA scale-to-zero, and the Grafana dashboard pattern from `pneuma-inference-platform` were verified working — port them forward rather than re-deriving.
- **Don't repeat the failure mode that killed the last build.** It died because gaming and inference fought over one GPU. That's structurally solved now (separate VMs), so treat "durable, always-available platform" as a real design goal this time, not an aspiration.
- **Phase gates.** Each phase has a concrete success criterion before moving on — same discipline as `teyvat-hardening-plan.md`.

---

## Phase 0 — VM bring-up & cluster join

**Goal:** `ousia` exists, has the 3090, and is a Ready k0s worker. `pneuma` is fully off the cluster.

1. On `furina`, create VM `ousia`: q35/OVMF, vTPM, sized similarly to `pneuma`'s inference role (12 cores / 48G RAM is what pneuma used — right-size once you know what else runs on furina concurrently). Separate disk on local-lvm.
2. GPU passthrough: `hostpci0` for the 3090, following the exact pattern from `furina-gaming-vm` (IOMMU group check first — confirm the 3090 is in a clean group, no ACS override needed, before assuming it'll be as easy as the 5070 Ti).
3. OS: reuse whatever `pneuma` runs today (Arch/CachyOS-family) *if* you want a uniform base for `scripts/game-mode.sh`-style tooling, or go plain Ubuntu/Debian since `ousia` has no desktop/Sunshine requirement — simpler, fewer moving parts, faster unattended reboots. **Recommendation: minimal Debian/Ubuntu server, no desktop.** This box never needs a display.
4. Install NVIDIA drivers + container toolkit; verify `nvidia-smi` sees the 3090 host-side and inside a test container.
5. Join k0s as a worker: static IP (next free after `.213`/`.214` — check what's free), `onboot 1`, taint `nvidia.com/gpu=present:NoSchedule` (same as pneuma had).
6. Install/verify **NVIDIA device plugin** DaemonSet targets `ousia` only (nodeSelector or the existing taint/toleration pattern from the old build).
7. ~~Decommission `pneuma`'s cluster membership~~ **DONE 2026-08-10**: `kubectl drain pneuma --ignore-daemonsets --delete-emptydir-data` (only DaemonSet pods present, no real workloads — clean), then `k0s stop`/`k0s reset` via `qm guest exec` from furina (fully removed the systemd unit + worker state, no VM reboot needed), then `kubectl delete node pneuma`. VM itself (gaming, Sunshine, 5070 Ti passthrough) confirmed untouched. `ousia` is now the cluster's sole GPU worker.

**Success criteria:** `kubectl get nodes` shows `ousia` Ready with `nvidia.com/gpu` allocatable=1, `pneuma` no longer listed. A test pod requesting `nvidia.com/gpu: 1` schedules on `ousia` and `nvidia-smi` runs inside it.

---

## Phase 1 — Core LLM serving

**Status: COMPLETE 2026-08-11.** vLLM serving qwen2.5-32b + qwen2.5-coder-32b on `ousia`, reachable end-to-end through LiteLLM, KEDA scale-to-zero verified in both directions (cold-start and idle-scale-down). See `Documentation/ousia/phase-1-notes.md` for the full account — several real issues found and fixed along the way, not a clean first pass:

1. **gpu-operator's own CUDA validator was crash-looping** (`WITH_WORKLOAD` under `validator.cuda.env`, not the top-level `validator.env` the CRD schema might suggest) — cosmetic per the Phase 0 note above, but see #2, it wasn't fully cosmetic.
2. **The same forward-compatibility error also crashed the real vLLM engine**, not just the operator's validator — `vllm/vllm-openai:v0.24.0` bundles torch+cu130 (CUDA 13.0), but ousia's driver (550.163.01) only supports up to CUDA 12.4, and GeForce cards can't use forward-compat mode to bridge that. Fixed by pinning to `vllm/vllm-openai:v0.8.4` (bundles CUDA 12.4.0 — exact match) instead of upgrading the host driver (avoids re-risking the PCI/NIC enumeration flakiness from the Phase 0 bring-up).
3. **ousia's disk was 60GB, not the 200G this plan specified** — same hypervisor-sizing gap as the RAM note below. A single 32B AWQ model (26GB) plus the vLLM image pushed the node into kubelet disk-pressure, which blocks scheduling of *any* pod on the node, not just the offending one. Fixed properly: `qm resize 103 scsi0 +140G` on furina, then `growpart`/`resize2fs` on ousia (197G now).
4. **`huggingface-cli` is gone in huggingface_hub 1.x** — replaced by the unified `hf` CLI; the prefetch Job needed updating.
5. **KV cache OOM on engine init** — `gpu-memory-utilization=0.90` + `max-model-len=16384` left less headroom than the 32B model's weights + KV cache needed. Settled on `0.97` / `12288` (dedicated GPU, no other consumer, so pushing utilization higher than pneuma's old 0.70 is safe here).
6. **RAM is still only ~11.6GiB actual** (12288MB configured) vs. the 32G this plan specifies — not yet fixed (owner deferred; disk got fixed live during Phase 1 because it was actively blocking, RAM wasn't). vLLM pod memory requests/limits are kept conservative (6Gi/9Gi) to fit. Revisit if that becomes the next bottleneck.

1. Port `kubernetes/apps/vllm/` forward from `git show 5db5028^ -- kubernetes/apps/vllm/` — update the GPU node selector/UUID pin (the old one was pinned to a GPU UUID that's gone; either drop the pin or repin to the 3090's UUID) and bump the model list now that VRAM is 24GB not 16GB.
2. Model selection — 24GB opens real headroom versus the old 16GB ceiling:
   - A capable general model at good quant (Qwen2.5-32B-AWQ/GPTQ fits in 24GB; or stay at 14B-class unquantized for more headroom/faster loads).
   - Keep a coder-specialized model (Qwen2.5-Coder-14B or similar) as a second route, same as before.
   - Decide up front: single model with hot-swap (KEDA-driven, like before) vs. two models resident simultaneously (24GB may allow both at once at moderate quant — worth testing since that removes the ~400s swap latency entirely).
3. Model cache: hostPath on `ousia` (`/var/lib/vllm-models`, `HF_HOME=/models/hf`), same pattern as before. Pre-fetch via a one-off Job.
4. LiteLLM: restore config, repoint routes at the new vLLM service(s), reconnect `open-webui` and the RAG stack (Qdrant/TEI already alive with no backend — this closes that gap).
5. KEDA scale-to-zero: port forward if single-model-at-a-time is the choice; skip if going with dual-resident models (in which case size requests/limits conservatively instead).

**Success criteria:** `open-webui` chat works end-to-end against a real model. RAG queries return cited answers again. Config-rev annotation bump on the LiteLLM configmap is documented in the new runbook (this bit the old build).

---

## Phase 2 — Observability

**Goal:** Know what the box is doing without SSHing in.

1. GPU metrics: DCGM exporter (or reuse whatever the old `gpu-operator` setup provided) → Prometheus (already-deployed KPS stack, `infrastructure/monitoring.yaml`).
2. Grafana dashboard: port the old `teyvat-ai-inference` dashboard UID forward — GPU utilization/VRAM, token throughput, request latency, per-model split.
3. Alerting: at minimum, alert on GPU-down / driver-fault / VRAM-pinned-but-idle (a symptom of a stuck request) via the existing Alertmanager→ntfy path if that landed from the hardening plan, otherwise a basic PrometheusRule.

**Success criteria:** Dashboard live, one synthetic alert test-fires and reaches ntfy/wherever alerts currently land.

---

## Phase 3 — Hardening & documentation

**Goal:** Make it survive owner-absence and node churn, and leave a paper trail worth citing on a resume.

1. Write `Documentation/ousia/README.md` + `build-log.md`, same structure as the old `Documentation/pneuma/` docs — model list, add-a-model recipe, gotchas.
2. Apply whatever's landed from `teyvat-hardening-plan.md` by this point (resource limits/probes on the new deployments, Kyverno posture, SOPS for any new secrets) rather than exempting `ousia`'s apps from cluster-wide policy.
3. Snapshot the VM post-bring-up (mirrors the `pre-pneuma` snapshot habit) before first real workload.
4. Write the retrospective note per `CLAUDE.md`'s documentation convention once this phase closes.

**Success criteria:** A cluster reboot or `ousia` VM restart brings the platform back with zero manual steps (verify by actually rebooting it).

---

## Phase 4 (stretch) — GPU multi-tenancy

**Goal:** the platform-engineering flex piece, once Phases 0–3 are boring and stable.

1. Evaluate MIG (3090 does **not** support MIG — that's Ampere-datacenter/Hopper-only via A100/H100; 3090 is consumer Ampere) — so this is **time-slicing** (`nvidia.com/gpu` shared via the device plugin's time-slicing config), not MIG. Correct the plan here versus the earlier brainstorm.
2. Configure the NVIDIA device plugin for time-slicing (replicate the GPU into N schedulable units), size N conservatively (2-4) given 24GB total.
3. Add a second, genuinely concurrent workload to prove isolation — e.g. a batch embedding/eval Job running alongside live inference — and measure interference (latency degradation on the inference path while the batch job runs).
4. Document the isolation characteristics honestly (time-slicing shares compute, not memory — OOM risk if both workloads are greedy; this is worth writing up as a real finding, not just "it worked").

**Success criteria:** two GPU-requesting pods scheduled concurrently on `ousia`, both making forward progress, degradation characterized and documented.

---

---

## Phase 5 (backlog) — AI-ops agent

**Goal:** an agent, backed by a model served on `ousia`, that operates this actual cluster/repo — not a toy demo. Do this only once Phases 0–3 are stable and boring; the agent needs a trustworthy platform under it.

**Scope, guardrails-first:**
1. **Read path first:** agent has read access to `kubectl` (cluster state), Prometheus/Grafana (metrics), and Alertmanager (firing alerts). It can *observe and reason*, nothing else, to start.
2. **Triage loop:** on an Alertmanager alert, the agent gathers context (recent events, relevant pod logs, related Grafana panels) and produces a written diagnosis — posted somewhere visible (ntfy, a GitHub issue, a Slack-equivalent) for a human to read. No autonomous action yet.
3. **Propose-a-fix loop:** for fixes that are pure GitOps commits (this repo, `kubernetes/`), let the agent open a PR with its proposed change and reasoning. **Never auto-merge.** A human reviews and merges — this is the one guardrail that matters most, since ArgoCD will auto-sync anything that lands on `main`.
4. **Postmortem drafting:** once a triaged incident is resolved (by human or agent-proposed PR), have the agent draft the retrospective note per this repo's existing documentation convention (`~/Homelab/claude-logs/...`), for a human to review/edit before it's considered final.
5. **Explicitly out of scope initially:** direct `kubectl apply`/`delete` by the agent, secret access, anything touching the k0s control plane, anything that bypasses the PR-review gate. Expand scope only after the propose-a-fix loop has a track record.

**Why this is worth doing:** it's the "AI SRE" pattern companies are actively hiring for, and unlike a lot of agent demos it's operating against real infrastructure with real failure modes and a real audit trail (git history) — very concrete to talk through in an interview.

**Build notes to revisit when starting:** decide on an agent framework (something you can self-host/control, given it's touching prod-ish infra — avoid opaque hosted agent platforms for this one), and design the tool/permission boundary explicitly before writing any agent code, not as an afterthought.

---

## Phase 6 (backlog) — LLM security / guardrails red-teaming

**Goal:** put a prompt-injection / jailbreak detection layer in front of the LiteLLM gateway, then actually try to break it — especially via the RAG path, since untrusted document content reaching the model is the classic real-world injection vector.

**Scope:**
1. **Baseline red-team pass, no defenses yet:** catalog known jailbreak/prompt-injection techniques (direct instruction override, encoded payloads, indirect injection via a poisoned document ingested into the RAG corpus) and run them against the current `ousia`/LiteLLM/RAG stack as-is. Document what succeeds — this baseline is itself useful, publishable content.
2. **Indirect/RAG-specific injection is the priority case:** plant an instruction inside a document that gets ingested into the Qdrant corpus (`teyvat-rag` nightly ingest) and see whether a downstream query can be hijacked by content the user never typed. This is the attack class that matters most for a RAG-backed assistant and the one most write-ups skip.
3. **Add a defense layer:** a guardrails proxy in front of/alongside LiteLLM (e.g. an input/output classifier pass, or a rules-based filter as a first cut) that flags or blocks suspicious inputs/outputs. Keep it as its own component so before/after comparisons are clean.
4. **Re-run the baseline attack catalog against the defended stack**, measure what's actually stopped vs. what still gets through, and write up the delta honestly (including remaining gaps — a security write-up that claims "fully solved" is less credible than one that's honest about residual risk).
5. **Feed findings back into Phase 5 if it exists by then:** e.g. an alert rule for anomalous LiteLLM request patterns, surfaced through the same triage loop.

**Why this is worth doing:** fewer people can credibly claim hands-on AI security experience than can claim "I ran an LLM," and doing it against your own real RAG pipeline (not a synthetic benchmark) is a much stronger story than a canned CTF.

---

---

## Phase 7 (backlog) — Personal RAG over the Obsidian vault

**Goal:** extend the existing `teyvat-rag`/Qdrant pipeline (currently indexed only over this repo's docs) to the full personal vault at `/Users/ccampbell/Homelab`, with retrieval accurate enough to trust the citations.

**Scope:**
1. Add a second ingest source alongside the repo-docs nightly job — same blue/green ingest-behind-alias pattern (`homelab-docs` Qdrant alias) so a bad reindex never breaks live queries. Likely a second collection/alias (`personal-vault`) rather than merging into one, so you can route/scope queries later.
2. Chunking strategy needs real attention here — Obsidian notes are shorter and more cross-linked (`[[wikilink]]`-style) than repo docs; naive fixed-size chunking will sever context that a linked note provides. Worth experimenting with note-aware chunking (whole-note or heading-section chunks, with `[[links]]` resolved/expanded before embedding) rather than reusing the repo-docs chunker unchanged.
3. Build a small retrieval eval set — a list of Q&A pairs you already know the right answer to from your own notes — and measure precision of *citations*, not just answer plausibility. This is the part most RAG demos skip and the part that's actually hard; treat "citations are accurate" as the success bar, not "the answer sounds right."
4. Expose via the existing LiteLLM/open-webui path as a selectable RAG mode alongside `teyvat-rag`.

**Success criteria:** retrieval eval set hits an agreed precision bar (pick a number once you've built the eval set and seen a baseline — don't pre-commit to one blind); a query against a note you wrote last week returns it correctly cited.

---

## Phase 8 (backlog) — Multimodal media search

**Goal:** semantic search over your Jellyfin/media library using a vision-language model on `ousia` — "find the episode where X happens" instead of filename/metadata search.

**Scope:**
1. Model: a VLM in the Qwen-VL class (or similar) served via vLLM/a separate serving path on `ousia` — check VRAM budget against whatever text models are resident from Phase 1 before assuming this coexists live; may need to be a scheduled/batch job rather than always-on.
2. Ingest pipeline: sample frames from media (or reuse `subgen`'s existing Whisper transcripts as a text-search complement) → caption/tag via the VLM → embed → store in its own Qdrant collection, keyed back to media file + timestamp.
3. Start scoped: pick one media source (e.g. one Jellyfin library or a photo directory on `celestia-nfs`) rather than the whole library, to get the pipeline right before scaling ingest cost.
4. Search UI: simplest version is a query box hitting the new collection directly (doesn't need to go through LiteLLM); nice-to-have is combining this with the Whisper transcript text search from `subgen` for hybrid semantic+dialogue search.

**Success criteria:** a natural-language query against the pilot media source returns the correct scene/file with a timestamp, better than filename search would.

---

## Phase 9 (backlog) — Chaos engineering for the inference platform

**Goal:** verify the platform actually degrades/recovers the way Phase 1–3 assume, under real failure, rather than just under happy-path testing.

**Scope:**
1. Failure modes to inject, roughly in order of how cheap they are to test: pod kill (`kubectl delete pod` on vLLM/LiteLLM mid-request), network partition to `ousia` (block traffic, observe LiteLLM fallback/error behavior), GPU driver fault simulation (harder — maybe a forced `nvidia-smi` reset or unloading the kernel module under load), full `ousia` VM reboot under active load.
2. For each: define expected behavior *before* running it (e.g. "LiteLLM should return a clean 503 within 5s, not hang; KEDA should reschedule within N seconds; no data loss on in-flight RAG ingest jobs") — this is what makes it chaos *engineering* rather than just breaking things and looking.
3. Measure and record actual vs. expected for each. Where actual falls short (likely: cold-start latency after a kill, or a hung request during a network partition), that becomes a concrete follow-up fix — e.g. tighter liveness probes, request timeouts on the LiteLLM side.
4. Write it up as a real reliability report (expected/actual/gap/fix table) — this is the artifact that reads well on a resume, more than the chaos-running itself.

**Success criteria:** every injected failure mode has a documented expected-vs-actual result and, where they differ, a merged fix with a before/after re-test.

---

## Open decisions to make before/at Phase 0

- [x] `ousia` OS — minimal Debian 13 (trixie), decided during actual Phase 0 bring-up.
- [x] Static IP for `ousia` — `192.168.1.215`.
- [x] VM sizing (disk) — built at 60G, actively blocked Phase 1 (kubelet disk-pressure), fixed 2026-08-11: resized to 200G (`qm resize 103 scsi0 +140G` + `growpart`/`resize2fs`, no reboot needed).
- [ ] VM sizing (RAM) — still only 12288MB actual vs. the 32G this plan specifies. Didn't block Phase 1 (kept vLLM pod memory requests/limits conservative instead), but is the next likely bottleneck — same `qm set 103 --memory` pattern as the disk fix once it matters.
- [x] Single hot-swapped model vs. dual-resident models — went with **both**: `qwen2.5-32b` + `qwen2.5-coder-32b`, each independently KEDA scale-to-zero (min 0/max 1), same single-GPU-shared pattern as the old pneuma build. Disk headroom (197G) comfortably fits both checkpoints cached simultaneously.
- [x] KEDA scale-to-zero — carried forward, verified working end-to-end (cold-start from 0 and idle scale-down both confirmed 2026-08-11).
