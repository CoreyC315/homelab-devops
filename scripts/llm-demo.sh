#!/usr/bin/env bash
# llm-demo.sh — guided tour of the Pneuma inference platform.
#
#   ./scripts/llm-demo.sh            full tour (incl. the GPU-swap leg, ~10 min if models are cold)
#   ./scripts/llm-demo.sh --quick    skips the coder/GPU-swap leg (~4 min worst case)
#
# Needs: kubectl (cluster access), curl, python3. No other deps.
set -euo pipefail
QUICK=${1:-}

GW=${GW:-http://192.168.1.55}
KEY=$(kubectl -n ai-stack get secret litellm-secret -o jsonpath='{.data.LITELLM_MASTER_KEY}' | base64 -d)

say()   { printf '\n\033[1;36m═══ %s ═══\033[0m\n' "$*"; }
note()  { printf '\033[0;33m%s\033[0m\n' "$*"; }
state() { kubectl -n ai-stack get deploy vllm-chat vllm-coder \
            -o custom-columns='MODEL:.metadata.name,REPLICAS:.spec.replicas,READY:.status.readyReplicas' ; }

say "0. The gateway"
echo "Everything OpenAI-compatible speaks to one endpoint: $GW (a.k.a. https://llm.local)"
echo "Auth: 'Authorization: Bearer \$KEY' — key lives in the litellm-secret."

say "1. What models does it serve?"
curl -s -H "Authorization: Bearer $KEY" "$GW/v1/models" \
  | python3 -c "import json,sys; [print('  •', m['id']) for m in json.load(sys.stdin)['data']]"
note "qwen3-14b + qwen2.5-coder-14b run on the GPU (one at a time);"
note "bge-small-en-v1.5 is CPU embeddings; teyvat-rag answers questions about this repo."

say "2. Current GPU scale state (KEDA owns this — 0 replicas = scaled to zero)"
state
note "If both are 0, the GPU is idle and the next request wakes a model (~2-3 min, held open)."

say "3. Chat completion"
note "('/no_think' is Qwen3's soft switch to skip its reasoning phase — snappier demos.)"
T0=$(date +%s)
curl -s --max-time 900 -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' \
  "$GW/v1/chat/completions" \
  -d '{"model":"qwen3-14b","messages":[{"role":"user","content":"/no_think In two sentences, what is special about running LLMs at home?"}],"max_tokens":150}' \
  | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['choices'][0]['message']['content'].strip())"
echo "(took $(( $(date +%s) - T0 ))s — a cold start means KEDA scaled 0→1 while the request was held)"

say "4. Streaming (watch tokens arrive)"
curl -sN --max-time 900 -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' \
  "$GW/v1/chat/completions" \
  -d '{"model":"qwen3-14b","stream":true,"messages":[{"role":"user","content":"/no_think Count from 1 to 10 with a word between each number."}],"max_tokens":120}' \
  | python3 -u -c "
import json, sys
for line in sys.stdin:
    line = line.strip()
    if not line.startswith('data: ') or line == 'data: [DONE]': continue
    delta = json.loads(line[6:])['choices'][0].get('delta', {})
    print(delta.get('content') or '', end='', flush=True)
print()"

say "5. Embeddings (TEI on CPU — instant, never wakes the GPU)"
curl -s -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' \
  "$GW/v1/embeddings" -d '{"model":"bge-small-en-v1.5","input":"longhorn replica count"}' \
  | python3 -c "import json,sys; v=json.load(sys.stdin)['data'][0]['embedding']; print(f'  {len(v)}-dim vector, first 5: {[round(x,4) for x in v[:5]]}')"

say "6. RAG — ask about your own infrastructure (teyvat-rag cites the repo docs)"
curl -s --max-time 900 -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' \
  "$GW/v1/chat/completions" \
  -d '{"model":"teyvat-rag","messages":[{"role":"user","content":"/no_think How do I free the GPU when I want to game, and how do I give it back?"}],"max_tokens":1200}' \
  | python3 -c "import json,sys; print(json.load(sys.stdin)['choices'][0]['message']['content'].strip()[:900])"

if [ "$QUICK" != "--quick" ]; then
  say "7. The coder model — single-GPU arbitration, live"
  note "If chat is warm, this request is HELD at the KEDA interceptor while chat idles out"
  note "(300s cooldown), then coder cold-starts and answers. Worst case ~8 min. Watch"
  note "'kubectl -n ai-stack get pods -w' in another terminal to see the swap."
  T0=$(date +%s)
  curl -s --max-time 1200 -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' \
    "$GW/v1/chat/completions" \
    -d '{"model":"qwen2.5-coder-14b","messages":[{"role":"user","content":"Write a k8s one-liner to show pods not in Running state, all namespaces."}],"max_tokens":200}' \
    | python3 -c "import json,sys; print(json.load(sys.stdin)['choices'][0]['message']['content'].strip())"
  echo "(took $(( $(date +%s) - T0 ))s)"
  state
fi

say "8. See it in the telemetry"
echo "  Grafana:    https://grafana.local  →  dashboard 'AI Inference (Pneuma)'"
echo "  Live tok/s: sum(rate(vllm:generation_tokens_total[5m]))"
GPU=$(curl -s --max-time 10 -H "Host: prometheus.local" \
  "http://192.168.1.50/api/v1/query?query=DCGM_FI_DEV_FB_USED" 2>/dev/null \
  | python3 -c "import json,sys; r=json.load(sys.stdin)['data']['result']; print(r[0]['value'][1]+' MiB' if r else 'n/a')" || echo n/a)
echo "  VRAM right now (via Prometheus): $GPU"

say "9. Scale-to-zero"
state
note "Leave it alone ~5 min and whatever is running scales back to 0 — check again with:"
note "  kubectl -n ai-stack get deploy vllm-chat vllm-coder"
printf '\n\033[1;32mDone. Point any OpenAI-compatible tool at %s with the key and it just works.\033[0m\n' "$GW"
