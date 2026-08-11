# Ousia Phase 1 — Core LLM Serving: Build Notes (2026-08-11)

**Result:** vLLM serving `qwen2.5-32b` (Qwen2.5-32B-Instruct-AWQ) and `qwen2.5-coder-32b`
(Qwen2.5-Coder-32B-Instruct-AWQ) on `ousia`'s 3090, both KEDA scale-to-zero,
reachable end-to-end through LiteLLM (`http://litellm.ai-stack.svc.cluster.local:80`
— note **port 80**, not 4000; the Service is `LoadBalancer` on 80 -> pod port 4000,
easy to get wrong).

Verified via a real chat completion (`qwen2.5-32b`, prompt "reply with exactly:
pong" -> `"content":"pong"`), through the full path: LiteLLM -> KEDA HTTP
interceptor -> cold-start scale from 0 -> vLLM pod -> real GPU inference ->
response -> KEDA scaled back to 0 after idle cooldown.

This was not a clean first pass — six distinct real issues surfaced and got
fixed live. Recorded here so the next person (or agent) doesn't rediscover
them the hard way.

---

## 1. gpu-operator's CUDA validator crash-looping

`nvidia-cuda-validator` / `nvidia-operator-validator` were `Init:CrashLoopBackOff`
with `Failed to allocate device vector A (error code forward compatibility was
attempted on non supported HW)!`. Root cause: `driver.enabled=false` (host-installed
driver, standard for this cluster) means the validator's own bundled CUDA runtime
can shadow the real host driver libs and trip forward-compatibility mode — which
NVIDIA restricts to datacenter GPUs. GeForce cards (the 3090 here) don't support it.

Fix: disable the workload validator via Helm values on the `gpu-operator`
ArgoCD Application:

```yaml
validator:
  cuda:
    env:
      - name: WITH_WORKLOAD
        value: "false"
```

**Gotcha:** the field is `validator.cuda.env`, not the top-level `validator.env`
— confirmed via `kubectl explain clusterpolicy.spec.validator` (the CRD is the
source of truth here, not the chart's `values.yaml`, which shows both `validator.env`
and `validator.plugin.env` but not the `cuda`/`driver`/`toolkit` sub-keys). Setting
the wrong key doesn't error, it's just silently absent from the rendered
`ClusterPolicy` CR — verify with `kubectl get clusterpolicy cluster-policy -o
jsonpath='{.spec.validator.cuda}'` after any change here.

**This is what the Phase 0 notes called "cosmetic."** It mostly was, for the
gpu-operator's own synthetic check — but see #2, the exact same failure mode
also breaks real workloads on this hardware/driver combination.

---

## 2. The real vLLM engine hit the identical forward-compat error

Once vLLM pods actually tried to start, they hit the *same* `Error 804: forward
compatibility was attempted on non supported HW`, this time inside
`torch.cuda._lazy_init()` — not cosmetic at all for a real serving workload.

Root cause: `vllm/vllm-openai:v0.24.0` bundles `torch==2.11.0+cu130` (CUDA 13.0).
ousia's driver is `550.163.01`, which only supports up to CUDA 12.4. There's no
forward-compat path available on GeForce to bridge a 13.0-vs-12.4 gap.

Two possible fixes: upgrade the host driver, or pin an older vLLM image built
against a CUDA version the current driver actually supports. **Chose the image
pin** — a driver upgrade needs a reboot and risks re-triggering the PCI/NIC
enumeration flakiness documented in the Phase 0 bring-up gotchas (NIC name
flip-flop, GPU PCI address shift, D3cold stuck-power). `vllm/vllm-openai:v0.8.4`
bundles CUDA 12.4.0 — an exact match — and Qwen2.5/AWQ-marlin support was
already mature by that release.

If you need a newer vLLM (for a newer model architecture, say), the driver
upgrade path is: check `apt-cache policy nvidia-driver` on ousia first — as of
this writing Debian trixie's own repos (main + backports) only offer
550.163.01. A newer driver means adding NVIDIA's own CUDA network repo, which
is a bigger, riskier change — test on a snapshot.

---

## 3. ousia's disk was 60GB, not 200G

The Phase 0 plan called for 200G; the box that actually got built has a 60GB
disk (`qm config 103` showed `scsi0: ...,size=60G`). Same category of gap as
the RAM note in item 6 — planned sizing didn't make it into the actual build.

Unlike the RAM gap, this one was **actively blocking** — not deferrable:

- A single 32B AWQ model (26GB on disk) plus the `vllm-openai` image
  (~8.6GB) plus OS/k0s overhead (~12GB) is already ~47GB of 60GB. Kubelet's
  disk-pressure eviction threshold triggers well before "full" (empirically
  ~9.5GB absolute headroom on this box, not a clean percentage), and once
  triggered it taints the node `node.kubernetes.io/disk-pressure:NoSchedule`
  — which blocks scheduling of *any* new pod on ousia, not just whatever
  filled the disk. This stalled the chat model's own pod, not just the
  second (coder) model.
- Kubelet's disk-pressure *condition* can also lag reality — after freeing
  space, the condition stayed `True` well past when `df` showed healthy
  headroom. `systemctl restart k0sworker.service` on ousia force-recomputes
  it; this was needed twice during Phase 1.
- Real fix: `qm resize 103 scsi0 +140G` on furina (thin-provisioned
  `local-lvm`, ~1.16TB free at the time — plenty of headroom), then on
  ousia: `growpart /dev/sda 1 && resize2fs /dev/sda1`. No reboot needed,
  the kernel picked up the larger block device live. ousia is now 197G,
  58% used with both 32B models cached.

---

## 4. `huggingface-cli` is gone in huggingface_hub 1.x

The model-prefetch Job's `huggingface-cli download ...` failed outright:
*"`huggingface-cli` is deprecated and no longer works. Use `hf` instead."*
huggingface_hub 1.27.0 dropped the old CLI entirely in favor of the unified
`hf` command. `hf_transfer` is also gone — replaced by Xet, on by default.

**Don't set `HF_XET_HIGH_PERFORMANCE=1`** unless the box actually has 64GB+
RAM — it's documented as requiring that much, and setting it on ousia's
~11.6GiB node OOMKilled the prefetch job outright (twice, at both 4Gi and
8Gi container memory limits, before this was diagnosed). Left it explicitly
`"0"` with `--max-workers 1` on the `hf download` calls to keep concurrent
download/reconstruction buffers small.

---

## 5. KV cache didn't fit at the first utilization/context settings

Engine init failed with:

```
ValueError: To serve at least one request with the models's max seq len
(16384), (4.00 GiB KV cache is needed, which is larger than the available
KV cache memory (2.21 GiB). Based on the available memory, Try increasing
`gpu_memory_utilization` or decreasing `max_model_len`...
```

The 32B AWQ model's weights alone take ~18.15GiB. At
`gpu-memory-utilization=0.90` (24GB * 0.90 = 21.6GB budget), that leaves
only ~3.4GB free — not enough for a 16384-token KV cache on even one
sequence, let alone `max-num-seqs=4` concurrent ones.

Settled on `gpu-memory-utilization=0.97` + `max-model-len=12288`: budget
23.28GB - 18.15GB weights = ~5.1GB for KV cache, comfortably covering a
12288-token sequence (~3GB) with real margin left for concurrency. Pushing
utilization this high is safe *specifically because* ousia's GPU is fully
dedicated — no desktop session or other workload competing for VRAM the
way pneuma's old 0.70 setting had to account for.

---

## 6. RAM: still not fixed, still 12288MB actual vs. 32G planned

Unlike the disk, this wasn't actively blocking Phase 1's goal, so it's still
open. `qm config 103` shows `memory: 12288`. vLLM pod memory
requests/limits are kept conservative (6Gi request / 9Gi limit) to fit
inside that. If a future phase needs more system RAM headroom (larger
concurrent request volume, a bigger embedding model running alongside,
etc.), this is the next thing to fix on furina — same `qm set 103 --memory
32768` pattern as the disk resize, just needs `pneuma`'s side of the
original Phase 0 RAM-shrink plan actually applied too (furina is 64GB
total, currently split oddly given neither VM matches its planned size).

---

## Operational gotchas worth remembering

- **ArgoCD + Kubernetes Jobs don't mix well for iterative fixes.** Jobs are
  immutable — editing a Job's pod template and pushing to git leaves the
  live Job unchanged; ArgoCD reports `OutOfSync` but can't patch it.
  `selfHeal` will also race you: delete the Job to let it recreate, and if
  the delete happens before your latest commit is the *synced* revision,
  self-heal recreates it from the *stale* spec. Always confirm `kubectl get
  application <app> -o jsonpath='{.status.sync.revision}'` matches your
  latest commit SHA *before* deleting, not just after pushing.
- **LiteLLM's Service is `LoadBalancer` on port 80**, not the pod's internal
  port 4000. Cost real time — every in-cluster test against
  `litellm...:4000` hung until this was caught via a Service/endpoints
  check. Use port 80 (or the LoadBalancer IP, `192.168.1.55`) for any
  future in-cluster client.
- **kubelet's disk-pressure condition can be stale relative to real disk
  usage** in both directions (stays `True` after cleanup, or presumably
  could stay `False` briefly after a sudden fill) — `systemctl restart
  k0sworker` on the affected node is the reliable way to force a recompute
  rather than waiting it out.
