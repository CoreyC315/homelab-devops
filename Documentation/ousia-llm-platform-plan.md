# Ousia LLM Platform — Implementation Plan

> Status: DRAFT, awaiting 3090 hardware arrival. No execution until Phase 0.
> Context: RTX 3090 (24GB) inbound as of 2026-08-08. New Proxmox VM `ousia` on host `furina`, separate from the existing gaming VM `pneuma` (5070 Ti). `pneuma` exits the k0s cluster entirely (goes back to gaming-only); `ousia` joins as the new dedicated GPU worker. This supersedes the torn-down `pneuma-inference-platform` build (commit `5db5028` removed vLLM) — same stack, different node, built to be permanent this time since gaming no longer competes for the GPU.
>
> Reuse sources: `Documentation/pneuma/{README,build-log,phase-0-node}.md` (prior build log + operational rules), `Documentation/furina-gpu-box-runbook.md` (Proxmox bring-up pattern already proven on `pneuma`).

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
7. Decommission `pneuma`'s cluster membership: `kubectl drain`/`delete node pneuma`, remove its taint/labels, confirm k0s config no longer expects it. Keep the VM itself untouched (gaming stays fully intact).

**Success criteria:** `kubectl get nodes` shows `ousia` Ready with `nvidia.com/gpu` allocatable=1, `pneuma` no longer listed. A test pod requesting `nvidia.com/gpu: 1` schedules on `ousia` and `nvidia-smi` runs inside it.

---

## Phase 1 — Core LLM serving

**Goal:** vLLM serving at least one model on `ousia`, reachable via LiteLLM, replacing the dead backend that `litellm`/`open-webui`/`rag` have had since 2026-07-14.

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

- [ ] `ousia` OS: minimal Debian/Ubuntu (recommended) vs. matching pneuma's Arch-family base
- [ ] Static IP for `ousia`
- [ ] VM sizing (cores/RAM) — depends what else furina's host resources need to cover
- [ ] Single hot-swapped model vs. dual-resident models now that VRAM allows it
- [ ] Whether to carry forward the KEDA scale-to-zero pattern, or run always-on now that there's no gaming contention to scale down for
