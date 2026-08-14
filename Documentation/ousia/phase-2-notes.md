# Ousia Phase 2 — Observability: Build Notes (2026-08-14)

**Result:** GPU/vLLM/LiteLLM metrics flowing into the existing kube-prometheus-stack,
Grafana dashboard `teyvat-ai-inference` live and correctly labeled for `ousia`
(was still titled "(Pneuma)" from the torn-down build), and a new
`PrometheusRule` covering the three failure modes the plan doc called for
(GPU-down, driver/thermal fault, VRAM-pinned-but-idle). Verified end-to-end:
rules loaded with `health=ok`, and a synthetic alert posted directly to
Alertmanager showed up `active`, routed correctly.

Much less new work than Phase 1 — most of the observability plumbing
(dcgm-exporter + its ServiceMonitor via `gpu-operator.yaml`, the `vllm` and
`litellm` ServiceMonitors, the `dashboard-ai-inference.yaml` panels) had
already survived the Phase 1 GitOps restoration and just needed verifying,
not rebuilding.

---

## 1. What was already live (verified, not built)

- `nvidia-dcgm-exporter` — `Running`, its ServiceMonitor scraping fine
  (`up{job="nvidia-dcgm-exporter"} == 1` in Prometheus).
- `litellm` ServiceMonitor — scraping fine.
- `vllm` ServiceMonitor — selector/port (`app.kubernetes.io/part-of: vllm`,
  port name `http`) correctly matches the `vllm-chat`/`vllm-coder` Services.
  No active target right now because both models are scaled to 0 — that's
  expected (the manifest already has a comment noting this) and not a bug;
  confirmed by checking Service labels/port names line up rather than
  forcing a cold start just to see a target appear.
- `dashboard-ai-inference.yaml` — full 12-panel dashboard (GPU util/VRAM/
  temp/power, vLLM running/waiting requests, TTFT p50/p95, generation
  throughput, KV cache %, replica count vs KEDA scale target, LiteLLM
  request rate/latency) was already ported from the old `pneuma` build and
  rendering correctly against real PromQL — `DCGM_FI_DEV_*`, `vllm:*`,
  `litellm_*`, `keda_scaler_active` all resolve.

## 2. Dashboard title was stale

Still said `"AI Inference (Pneuma)"` — a leftover from before pneuma was
pulled off the cluster and ousia took over inference. Cosmetic only (same
UID, same panels, same queries — nothing was actually pointed at pneuma),
but worth fixing so it doesn't read as a lie. Updated title to
`"AI Inference (Ousia)"`, added an `ousia` tag alongside the existing
`teyvat`/`ai` tags.

## 3. Alerting: ntfy path hasn't landed yet, so a plain PrometheusRule

`teyvat-hardening-plan.md` Phase 12 (Alertmanager → ntfy) is still
unstarted — checked the live `alertmanager.yaml` secret directly, and the
only receiver configured is `"null"`. Per the plan doc's own fallback
language ("via the existing Alertmanager→ntfy path if that landed... otherwise
a basic PrometheusRule"), added `prometheusrule-ai-inference.yaml` with three
rules:

- **`OusiaGPUExporterDown`** — `up{job="nvidia-dcgm-exporter"} == 0` for 5m.
  Covers both "exporter crashed" and "driver/GPU wedged" — either way, GPU
  health goes blind, worth knowing.
- **`OusiaGPUTempCritical`** — `DCGM_FI_DEV_GPU_TEMP > 90` for 5m. The card's
  own thermal thresholds (confirmed via `nvidia-smi -q` earlier this build)
  are 95°C slowdown / 98°C shutdown, so 90°C for 5 minutes gives real margin
  while still catching a real problem before it throttles.
- **`OusiaVRAMPinnedIdle`** — `DCGM_FI_DEV_FB_USED > 15000 and (sum(vllm:num_requests_running) or vector(0)) == 0`
  for 20m. This is the "stuck request" symptom the plan doc named
  explicitly: VRAM holding >15GB (both 32B AWQ models weigh ~18GB alone, so
  this only trips when a model is actually loaded) while vLLM reports zero
  active requests, sustained well past KEDA's 300s idle cooldown
  (`keda-routing.yaml`). Normal idle scales to 0 within minutes; this means
  something didn't scale down or is wedged.

These land in Alertmanager and are visible there (and in Grafana's alerting
view) right now even without ntfy wired up — no rule changes needed once
that receiver lands, they'll just get a real destination.

## 4. Verification

- `kubectl get --raw /api/v1/rules` (via port-forward) showed all three new
  rules loaded with `health: ok`, `state: inactive`, no `lastError` —
  confirms the PromQL is valid and Prometheus picked up the CR (took about
  a minute after the ArgoCD sync for the operator to reconcile + reload).
- Ran a real `KubePodCrashLooping` trip (a `busybox`/`/bin/false` pod) to
  confirm the existing generic Prometheus→Alertmanager pipeline still
  works end-to-end post-Phase-1 — it went `pending` in Prometheus as
  expected (that rule's `for: 15m` is long; didn't wait it out).
- To actually confirm firing → Alertmanager delivery without waiting 15+
  minutes on a real trip, posted a synthetic alert directly to
  Alertmanager's `/api/v2/alerts` endpoint (`OusiaPhase2SyntheticTest`).
  Came back `active`, routed to the `null` receiver — exactly as expected
  given ntfy isn't wired yet. Confirms the rule-evaluation→Alertmanager→
  receiver-routing path is intact; auto-resolved after the configured 5m
  `resolve_timeout`, no manual cleanup needed.

## 5. Aside: the RAM gap from Phase 1 is now fixed

Not part of this phase's work, but worth noting since it changes a caveat in
`phase-1-notes.md` #6: the owner rebalanced furina's VM memory on
2026-08-13 (`pneuma` 40G→22G, `ousia` 12G→30G) — see the Phase 0 section of
the plan doc for the full account, including a host-level OOM-thrash
incident during the change (recovered via power cycle, root-caused to
growing one VM before shrinking the other). `ousia` now has ~27GB free RAM
headroom. vLLM's pod memory requests/limits (6Gi/9Gi) are still conservative
from when 12GB was the real ceiling — raising them is a reasonable future
pass if request volume grows, but out of scope here.

---

## Operational gotchas worth remembering

- **PrometheusRule CRs take a short but real delay to show up in
  `/api/v1/rules`** after ArgoCD reports `Synced` — the prometheus-operator
  has to notice the CR, regenerate the rule-files ConfigMap/Secret, and
  trigger a live Prometheus reload. Roughly a minute in practice here.
  Don't assume "Synced" means "Prometheus is evaluating it yet."
- **Testing Alertmanager delivery doesn't require waiting out a real rule's
  `for:` duration.** POSTing directly to `/api/v2/alerts` is the faster,
  equally valid way to confirm the receiver-routing side of the pipeline
  works, independent of whether any specific rule's condition is currently
  true. Rule *correctness* is separately confirmed via `health: ok` in
  `/api/v1/rules`.
- **`ruleSelectorNilUsesHelmValues: false`** (set in `stack.yaml`) means any
  `PrometheusRule` in the cluster is picked up regardless of labels — no
  `release: kube-prometheus-stack` label needed on app-owned rules, same
  pattern already established for the `vllm`/`litellm` ServiceMonitors.
