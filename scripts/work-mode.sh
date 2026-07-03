#!/usr/bin/env bash
# work-mode: hand the GPU back to the inference platform after gaming.
# KEDA re-creates vLLM pods on the next request (scale-from-zero).
set -euo pipefail

kubectl uncordon pneuma

echo "pneuma uncordoned. Next LLM request cold-starts vLLM (~2-4 min on the x1 link)."
