# Ousia — GPU LLM Inference Platform

Self-hosted, GitOps-managed LLM platform on the Teyvat k0s cluster, running on
the dedicated GPU node `ousia`. Everything below deploys from this repo via
ArgoCD (app-of-apps); the only out-of-band items are the node join itself,
two secrets, and host-level GPU driver/power config on `ousia` directly.

## Architecture

```
client / Open WebUI (ai.local)
      │
      ▼
LiteLLM gateway ── 192.168.1.55 (MetalLB) / llm.local (route) / :4000 in-cluster
  models: qwen2.5-32b · qwen2.5-coder-32b · bge-small-en-v1.5 · teyvat-rag
      │                                        │                    │
      │ (chat/coder)                           │ (embeddings)       │ (RAG)
      ▼                                        ▼                    ▼
vllm-<m>-gw (ExternalName)                TEI (CPU,           rag-api (FastAPI)
      │                                   bge-small)               │
      ▼                                                            ▼
KEDA HTTP interceptor :8080 ──── holds request, wakes model    Qdrant :6333
      │        ▲                                               (Longhorn PVC)
      ▼        │ external-push scaler                              ▲
vllm-chat / vllm-coder  (Deployments, min 0 / max 1)               │
      │                                                     rag-ingest CronJob
      ▼                                                     (docs → embeddings,
   ousia (k0s GPU worker, Debian VM 103 on furina, static IP  daily)
   192.168.1.215) — RTX 3090 24GB, power-capped 275W,
   taint nvidia.com/gpu=present:NoSchedule
```

**One GPU, one model at a time.** Both vLLM deployments scale 0↔1 via KEDA.
Requesting the cold model while the other is warm: the interceptor holds the
request, the warm model scales to 0 after its 300s idle cooldown, the cold one
starts. Route budgets: readiness 900s, response-header 900s, total 1800s.

Unlike the old `pneuma` build, `ousia` is a **dedicated** compute node — no
gaming/desktop session competing for the GPU, so no `game-mode.sh`-style
handoff is needed here. `pneuma` (5070 Ti) is pure gaming and fully off the
k0s cluster.

## Components (ArgoCD Applications)

| App | What | Pin |
|---|---|---|
| `gpu-operator` | device plugin, GFD, DCGM exporter (driver+toolkit host-installed on the node, not operator-managed — see gotcha in `ousia-llm-platform-plan.md`) | v26.3.3 |
| `vllm` | 2 Deployments: chat `Qwen/Qwen2.5-32B-Instruct-AWQ`, coder `Qwen/Qwen2.5-Coder-32B-Instruct-AWQ` | vllm-openai v0.8.4 (pinned — v0.24.0 bundles CUDA 13.0, incompatible with the 550.163.01 driver) |
| `litellm` | OpenAI-compatible gateway, master-key auth (DB-less) | v1.90.0 |
| `keda` + `keda-http-add-on` | scale-to-zero + request-holding interceptor | 2.20.1 / 0.15.0 |
| `qdrant` | vector store (Longhorn, regular workers) | chart 1.18.2 |
| `rag` | TEI embeddings (CPU) + ingest CronJob + rag-api | TEI cpu-1.9 |
| `monitoring` | KPS + `teyvat-ai-inference` dashboard (re-labeled off "(Pneuma)" 2026-08-14) + GPU/vLLM PrometheusRule | see `kube-prometheus-stack` app |

## Node facts (`ousia`)

| | |
|---|---|
| VM | VMID 103 on `furina`, Debian 13 (trixie) cloud image |
| IP | `192.168.1.215/24` static (hand-written `systemd-networkd` `.network` file — netplan's own generation proved unreliable on this image, see plan doc gotchas) |
| RAM | 30GiB (rebalanced 2026-08-17; `pneuma` gave up 18GB to make room) |
| GPU | RTX 3090 24GB, driver 550.163.01 / CUDA 12.4, **power-capped 275W** via a persistent `nvidia-power-limit.service` systemd unit (survives reboots) |
| Taint / label | `nvidia.com/gpu=present:NoSchedule` / `teyvat.io/gpu=true` |
| Longhorn | excluded (no toleration) — node downtime must never degrade volumes |
| Model cache | hostPath `/var/lib/vllm-models`, owned `1000:1000` (non-root fix, 2026-08-17) |

## How to query

```bash
KEY=$(kubectl -n ai-stack get secret litellm-secret -o jsonpath='{.data.LITELLM_MASTER_KEY}' | base64 -d)
curl -s http://192.168.1.55/v1/models -H "Authorization: Bearer $KEY"
curl -s http://192.168.1.55/v1/chat/completions -H "Authorization: Bearer $KEY" \
  -H 'Content-Type: application/json' \
  -d '{"model":"qwen2.5-32b","messages":[{"role":"user","content":"hello"}]}'
```
First request after idle = cold start; LiteLLM holds/retries within its 900s
budget. `teyvat-rag` answers questions about this repo with citations.

## Add a new model

1. Copy `kubernetes/apps/vllm/vllm-chat-deployment.yaml` + service; change
   `--model`, `--served-model-name`, names/labels. Check VRAM: weights+KV
   must fit 24GB × the chosen `--gpu-memory-utilization`.
2. Add an InterceptorRoute + ScaledObject + `-gw` ExternalName Service in
   `keda-routing.yaml` (copy a block, rename).
3. Register in `kubernetes/apps/litellm/configmap.yaml` `model_list` with
   `api_base: http://vllm-<name>-gw.ai-stack.svc.cluster.local:8080/v1`.
4. Commit — ArgoCD does the rest. Consider a one-off prefetch Job
   (`model-prefetch-job.yaml` pattern) so the first real request doesn't eat
   the full download time on top of KEDA's cold-start window.

## Physical/hardware notes

The 3090 is vertically mounted (VG4v4-style riser bracket) so the case can
close — see `ousia-llm-platform-plan.md` for the full PCIe link-width
investigation (x8 is expected board behavior for this slot, not a fault) and
the thermal/power-cap tuning (275W plateaus at 83°C vs. 87°C-and-climbing at
stock 350W). Top-mount case fans are a planned follow-up for more headroom.

## Observability

Grafana → dashboard **"AI Inference (Ousia)"** (uid `teyvat-ai-inference`):
GPU util/VRAM/temp/power (DCGM), vLLM TTFT/throughput/KV-cache/queue, replica
& KEDA scaler state, LiteLLM request rate/latency. A `PrometheusRule` covers
GPU-down, driver/thermal fault, and VRAM-pinned-but-idle (stuck request);
routes through Alertmanager's `"null"` receiver until the hardening plan's
ntfy integration lands (SOPS-gated) — verified firing correctly regardless.
See `Documentation/ousia/phase-2-notes.md` for the full account.

## Secrets (out-of-band until hardening plan's SOPS phase)

| Secret | ns | Keys | Used by |
|---|---|---|---|
| `litellm-secret` | ai-stack | LITELLM_MASTER_KEY | litellm, open-webui, rag-api, rag-ingest |
| `grafana-admin` | monitoring | admin-user, admin-password | Grafana login |

## Teardown (reverse order works per-phase)

Remove the corresponding `kubernetes/infrastructure/<app>.yaml` (ArgoCD
prunes; `monitoring` deliberately has no cascade finalizer). Model cache
lives at `/var/lib/vllm-models` on `ousia` (hostPath; wipe manually if
desired). Node removal: same token-based `k0s reset` pattern used to retire
`pneuma` from the cluster — see `ousia-llm-platform-plan.md` Phase 0 notes.
