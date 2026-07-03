# Pneuma — GPU LLM Inference Platform

Self-hosted, GitOps-managed LLM platform on the Teyvat k0s cluster. Everything
below deploys from this repo via ArgoCD (app-of-apps); the only out-of-band
items are the node join itself, two secrets, and the game-mode scripts.

## Architecture

```
client / Open WebUI (ai.local)
      │
      ▼
LiteLLM gateway ── 192.168.1.55 (MetalLB) / llm.local (ingress) / :4000 in-cluster
  models: qwen3-14b · qwen2.5-coder-14b · bge-small-en-v1.5 · teyvat-rag
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
   pneuma (k0s GPU worker = Omarchy VM 100 on furina)         4:30am daily)
   RTX 5070 Ti 16GB · taint nvidia.com/gpu=present:NoSchedule
```

**One GPU, one model at a time.** Both vLLM deployments scale 0↔1 via KEDA.
Requesting the cold model while the other is warm: the interceptor holds the
request, the warm model scales to 0 after its 300s idle cooldown, the cold one
starts (~2–4 min; PCIe x1 until the slot RMA). Route budgets: readiness 900s,
response-header 900s, total 1800s.

## Components (ArgoCD Applications)

| App | What | Pin |
|---|---|---|
| `gpu-operator` | device plugin, GFD, DCGM exporter (driver+toolkit preinstalled on node) | v26.3.3 |
| `vllm` | 2 Deployments: chat `Qwen/Qwen3-14B-AWQ`, coder `Qwen/Qwen2.5-Coder-14B-Instruct-AWQ` | vllm-openai v0.24.0 |
| `litellm` | OpenAI-compatible gateway, master-key auth (DB-less) | v1.90.0 |
| `keda` + `keda-http-add-on` | scale-to-zero + request-holding interceptor | 2.20.1 / 0.15.0 |
| `qdrant` | vector store (10Gi Longhorn, regular workers) | chart 1.18.2 |
| `rag` | TEI embeddings (CPU) + ingest CronJob + rag-api | TEI cpu-1.9 |
| `monitoring` | KPS (fresh 87.5.1) + dashboards incl. `teyvat-ai-inference` | 87.5.1 |

## How to query

```bash
KEY=$(kubectl -n ai-stack get secret litellm-secret -o jsonpath='{.data.LITELLM_MASTER_KEY}' | base64 -d)
curl -s http://192.168.1.55/v1/models -H "Authorization: Bearer $KEY"
curl -s http://192.168.1.55/v1/chat/completions -H "Authorization: Bearer $KEY" \
  -H 'Content-Type: application/json' \
  -d '{"model":"qwen3-14b","messages":[{"role":"user","content":"hello"}]}'
```
First request after idle = cold start (~2–4 min); LiteLLM holds/retries within
its 900s budget. `teyvat-rag` answers questions about this repo with citations.

## Add a new model

1. Copy `kubernetes/apps/vllm/vllm-chat-deployment.yaml` + service; change
   `--model`, `--served-model-name`, names/labels. Check VRAM: weights+KV must
   fit 16GB×0.85 (AWQ 14B ≈ 10GB weights).
2. Add an InterceptorRoute + ScaledObject + `-gw` ExternalName Service in
   `keda-routing.yaml` (copy a block, rename).
3. Register in `kubernetes/apps/litellm/configmap.yaml` `model_list` with
   `api_base: http://vllm-<name>-gw.ai-stack.svc.cluster.local:8080/v1`.
4. Commit — ArgoCD does the rest.

## Gaming (GPU handoff)

`scripts/game-mode.sh` → cordon + kill vLLM pods (VRAM free in seconds, node
stays up, Sunshine unaffected). `scripts/work-mode.sh` → uncordon. Details +
Arch update procedure: `phase-0-node.md`.

## Observability

Grafana → dashboard `AI Inference (Pneuma)` (uid `teyvat-ai-inference`):
GPU util/VRAM/temp/power (DCGM), vLLM TTFT/throughput/KV-cache/queue, replica
& KEDA scaler state, LiteLLM request rate/latency. Logs: arrive with the
hardening plan's Loki/Alloy phases (loki-stack was EOL and is archived).

## Secrets (out-of-band until hardening P2/SOPS)

| Secret | ns | Keys | Used by |
|---|---|---|---|
| `litellm-secret` | ai-stack | LITELLM_MASTER_KEY | litellm, open-webui, rag-api, rag-ingest |
| `grafana-admin` | monitoring | admin-user, admin-password | Grafana login |

## Teardown (reverse order works per-phase)

Remove the corresponding `kubernetes/infrastructure/<app>.yaml` (ArgoCD prunes;
`monitoring` deliberately has no cascade finalizer). Node teardown:
`phase-0-node.md`. Model cache lives at `/var/lib/vllm-models` on pneuma
(hostPath; wipe manually if desired).
