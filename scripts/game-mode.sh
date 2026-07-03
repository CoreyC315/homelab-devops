#!/usr/bin/env bash
# game-mode: free the RTX 5070 Ti on pneuma for gaming.
#
# Cordons the node (KEDA scale-ups become harmlessly Pending) and deletes the
# vLLM pods (VRAM frees in seconds). The k8s node itself STAYS UP — Sunshine,
# DCGM metrics, and the rest of the cluster are unaffected.
#
# Do NOT `kubectl scale` the vLLM deployments instead: KEDA owns the replica
# count and ArgoCD self-heal reverts out-of-band drift.
#
# Undo with work-mode.sh.
set -euo pipefail

kubectl cordon pneuma
kubectl -n ai-stack delete pod -l teyvat.io/gpu-workload=true --ignore-not-found --wait=true

echo
echo "GPU freed. LLM requests will queue/504 until work-mode.sh is run."
echo "VRAM check: ssh root@192.168.1.103 'qm guest exec 100 -- nvidia-smi'"
