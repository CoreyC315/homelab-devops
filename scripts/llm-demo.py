#!/usr/bin/env python3
"""Pneuma platform via the official OpenAI SDK — this is all any app needs.

    pip install openai
    export LITELLM_KEY=$(kubectl -n ai-stack get secret litellm-secret \
        -o jsonpath='{.data.LITELLM_MASTER_KEY}' | base64 -d)
    python3 scripts/llm-demo.py
"""
import os
from openai import OpenAI

client = OpenAI(
    base_url="http://192.168.1.55/v1",  # the LiteLLM gateway
    api_key=os.environ["LITELLM_KEY"],
    timeout=900,  # survives a scale-from-zero cold start
)

# --- plain chat (streaming) -------------------------------------------------
print("chat (streaming):")
for chunk in client.chat.completions.create(
    model="qwen3-14b",
    messages=[{"role": "user", "content": "/no_think Two sentences on why GitOps suits a homelab."}],
    stream=True,
    max_tokens=150,
):
    print(chunk.choices[0].delta.content or "", end="", flush=True)
print("\n")

# --- embeddings (CPU, instant) ----------------------------------------------
vec = client.embeddings.create(model="bge-small-en-v1.5", input="jellyfin transcoding").data[0].embedding
print(f"embedding: {len(vec)} dims\n")

# --- RAG over the homelab-devops repo ----------------------------------------
print("teyvat-rag:")
resp = client.chat.completions.create(
    model="teyvat-rag",
    messages=[{"role": "user", "content": "/no_think Which storage class should app config use, and which is for media?"}],
    max_tokens=800,
)
print(resp.choices[0].message.content.strip())
