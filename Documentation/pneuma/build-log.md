# Pneuma platform — build log & measured results

Built 2026-07-02 → 2026-07-03. Architecture/ops: `README.md`. Node details:
`phase-0-node.md`. Roadmap history: plan "Pneuma GPU Inference Platform +
Teyvat Hardening" (approved 2026-07-02).

## Measured numbers (record; sized the timeouts)

| Metric | Value |
|---|---|
| vLLM cold start, warm cache (schedule→Ready) | **165s** (Qwen3-14B-AWQ, PCIe 3.0 x1) |
| Generation throughput | **~80-85 tok/s** (single stream, via gateway) |
| VRAM under load | 14.0GB / 16.3GB (0.85 util + ~0.4GB desktop) |
| vLLM image pull (pre-warm) | 8.6 GiB @ 105 MiB/s ≈ 84s |
| Model prefetch (both AWQ 14B) | ~10GB each, ~2 min each |
| First RAG ingest | 124 chunks (Documentation/ + README + CLAUDE.md) |
| KEDA wake / swap | see README semantics; verified live 2026-07-03 |

## Verification checklist (all passed)

- [x] `kubectl get node pneuma` Ready, taint + `teyvat.io/gpu=true`, Longhorn excluded
- [x] `nvidia.com/gpu: 1` allocatable; cuda-validator Succeeded; awq_marlin auto-selected
- [x] DCGM metrics in Prometheus (incl. desktop VRAM visible)
- [x] Completion via `http://192.168.1.55/v1/chat/completions` (success criterion #2)
- [x] Reasoning parser: `reasoning_content` split from `content`
- [x] `/metrics` on LiteLLM scrapeable (v1.90.0 needs `require_auth_for_metrics_endpoint: false`)
- [x] Both models scale to 0 when idle; cold request held by interceptor and served (criterion #4)
- [x] Coder-while-chat-warm arbitration swap held and served
- [x] Grafana dashboard `teyvat-ai-inference` loaded; all targets up (criterion #3)
- [x] open-webui on ai.local against the gateway; ollama retired
- [x] RAG: ingest → Qdrant alias `homelab-docs`; `teyvat-rag` answers with citations
- [x] game-mode/work-mode cycle

## Incidents & gotchas hit during the build

1. **Control-plane starvation** — master VM was 2GB; KPS watchers + gpu-operator
   CRDs pushed apiserver into thrash (API timeouts, load 5). Now 5GB/4c.
   Check headroom before Stage C controllers (Kyverno/Trivy).
2. **Monitoring stack was already dead** — deleted live during the June
   consolidation; never GitOps-wired, so "restore cluster" couldn't bring it
   back. Rebuilt fresh at KPS 87.5.1 under the app-of-apps. loki-stack (EOL
   Promtail) archived, NOT resurrected — logs come with hardening P8-P10.
3. **GPU operator vs Arch**: needs os-release `VERSION_ID` (see
   phase-0-node.md). Also: NFD bind-mounts `/etc/os-release` — replacing the
   symlink requires an NFD worker pod restart (new inode invisible to the
   running mount).
4. **Longhorn SC drift**: StorageClass stamped `numberOfReplicas: 3` with only
   2 storage nodes post-raiden — every new PVC born degraded. Fixed via chart
   value (SC updated cleanly, no recreate needed).
5. **Application deletion does NOT cascade** — no repo Application carries the
   resources-finalizer, so deleting an app file orphans its live resources
   (deliberate safety default; saved monitoring from worse). True retirement
   (ollama) needs manual `kubectl delete` of the leftovers afterward.
6. **LiteLLM config changes don't restart the pod** — bump the
   `teyvat.io/config-rev` pod annotation in `deployment.yaml` with every
   configmap edit or the gateway keeps stale routing.
7. **k0s bundles containerd 1.7.x** (not 2.x) — the nvidia.toml drop-in uses
   the v2 schema with `io.containerd.grpc.v1.cri`.
8. **Tailscale SSH check** gates interactive SSH to the pneuma VM —
   automation path is `ssh root@192.168.1.103` + `qm guest exec 100`.

## Review-driven fixes (multi-agent adversarial review, pre-deploy)

- Registered `bge-small-en-v1.5` + `teyvat-rag` in LiteLLM model_list (RAG
  would have been dead-on-arrival: every embeddings call 400).
- `require_auth_for_metrics_endpoint: false` (silent Prometheus 401 otherwise;
  confirmed against v1.90.0 source).
- rag-api handlers made sync (`def`, not `async def`) — blocking `requests`
  calls would have frozen the event loop incl. `/healthz` per query.
- Ingest made blue/green behind a Qdrant ALIAS with an empty-collection guard
  (mid-run failure can't leave an empty corpus serving).
- vLLM startupProbe budget 15→30 min + models pre-fetched to the hostPath.
- Atomic Phase-4 cutover ordering (ScaledObjects + api_base flip in one sync).
- `keda_scaler_active` dashboard matcher fixed (operator SM relabels the
  ScaledObject namespace to `exported_namespace`).

## Out-of-band actions (documented exceptions to GitOps)

k0s node join (phase-0), `litellm-secret` + `grafana-admin` secrets
(TODO(SOPS): hardening P2), one-time model-prefetch Job (deleted), manual
ollama leftovers cleanup (finalizer note above), master VM resize (terraform
synced), game-mode/work-mode scripts.
