# Ousia platform — build log & measured results

Built 2026-08-10 → 2026-08-17 (hardware bring-up through Phase 3 hardening).
Architecture/ops: `README.md`. Full phase-by-phase narrative + every gotcha
hit along the way: `Documentation/ousia-llm-platform-plan.md`. Detailed notes
per phase: `phase-1-notes.md` (core serving), `phase-2-notes.md`
(observability). This file is the consolidated summary.

## Measured numbers (record; sized the timeouts/limits)

| Metric | Value |
|---|---|
| `gpu-burn` 60s @ stock 350W | 0 errors, 78°C peak |
| `gpu-burn` 180s @ stock 350W (case closed, vertical mount) | 0 errors, 87°C peak, ~4% throughput dip near the end (mild thermal backoff) |
| `gpu-burn` 180s @ capped 275W | 0 errors, **83°C plateau** (didn't keep climbing) |
| `cuda_memtest` full 9-test suite, ~24GB, 1 pass | 0 errors, ~8.5 min, Test10 ~5.2TB/s effective bandwidth |
| PCIe link (post-reseat) | 16GT/s (Gen4, the 3090's own native max), x8 width (expected — board's x8/x8 CPU-slot split when both GPU slots populated) |
| Idle GPU draw | ~7-14W |
| vLLM 32B-AWQ weights | ~18.15GiB, leaves ~5.1GB for KV cache at `--gpu-memory-utilization=0.97` / `--max-model-len=12288` |
| Model prefetch (both 32B AWQ) | ~26GB each |
| ousia disk | resized 60G → 200G (live, `qm resize` + `growpart` + `resize2fs`, no reboot) |
| ousia RAM | 12GiB (Phase 1) → 30GiB (rebalanced 2026-08-17, `pneuma` 40G→22G to make room) |

## Verification checklist (all passed)

- [x] `kubectl get node ousia` Ready, taint + `teyvat.io/gpu=true`, Longhorn excluded
- [x] `nvidia.com/gpu: 1` allocatable; GPU-operator daemonsets running (cuda-validator disabled — see gotcha #1)
- [x] Real k8s pod with `runtimeClassName: nvidia` sees the GPU via `nvidia-smi` end-to-end
- [x] Completion via `http://192.168.1.55/v1/chat/completions` (both models)
- [x] Both models scale to 0 when idle; cold request held by interceptor and served
- [x] DCGM/vLLM/LiteLLM metrics in Prometheus; Grafana dashboard `teyvat-ai-inference` correctly labeled "(Ousia)"
- [x] PrometheusRule (GPU-down, thermal fault, VRAM-pinned-idle) verified firing via synthetic alert
- [x] `pneuma` cleanly removed from the k0s cluster (drained, `k0s reset`, node deleted); gaming VM itself untouched
- [x] 275W power cap survives a real reboot (not just live-session)
- [x] RAM rebalance survives a real reboot (verified post host-crash-recovery)
- [x] Kyverno `require-run-as-nonroot` fixed on vllm-chat/vllm-coder/litellm (2026-08-17)
- [x] `ousia` `onboot: 1` — VM auto-starts with the host

## Incidents & gotchas hit during the build

1. **GPU Operator's `nvidia-cuda-validator` crash-loops on host-installed drivers** — `driver.enabled=false` (host driver, standard for this cluster) means the validator's own bundled CUDA runtime shadows the real driver libs and trips a forward-compatibility check that's datacenter-only, unsupported on GeForce. Disabled via `validator.cuda.env: WITH_WORKLOAD=false` on the `gpu-operator` ClusterPolicy — the exact field path matters (`validator.cuda.env`, not top-level `validator.env`; verify with `kubectl get clusterpolicy -o jsonpath`).
2. **The identical error broke real vLLM, not just the cosmetic validator** — `vllm-openai:v0.24.0` bundles CUDA 13.0; the 550.163.01 driver only supports up to 12.4. Fixed by pinning to `v0.8.4` (CUDA 12.4.0, exact match) rather than upgrading the driver — a driver upgrade needs a reboot and risks re-triggering the PCI/NIC enumeration flakiness (gotcha #6 below).
3. **`ousia`'s disk was 60GB, not the 200G planned** — actively blocking (kubelet disk-pressure taint blocked scheduling of *anything* on the node, not just the offending pod). Fixed live: `qm resize` + `growpart` + `resize2fs`, no reboot needed. Kubelet's disk-pressure condition can also lag reality after cleanup — `systemctl restart k0sworker` force-recomputes it.
4. **`huggingface-cli` is gone in `huggingface_hub` 1.x** — the unified CLI is now `hf`; `hf_transfer` replaced by Xet (on by default). Don't set `HF_XET_HIGH_PERFORMANCE=1` without 64GB+ RAM — it OOMKilled the prefetch job outright on ousia's then-12GB node.
5. **KV cache didn't fit at the first `gpu-memory-utilization`/`max-model-len` settings** — 32B AWQ weights (~18.15GiB) leave little room at 0.90 util; settled on 0.97/12288 for ~5.1GB of real KV-cache headroom, safe specifically because the GPU is fully dedicated (no desktop session sharing VRAM the way `pneuma`'s old build had to).
6. **furina's NIC name and the GPU's own PCI address both shift on every reboot where PCI enumeration changes** (adding/removing the 3090, or even just a plain reboot after the vertical remount) — `enp8s0` ⇄ `enp9s0` for the NIC, and the GPU's `lspci` address moved entirely once. Always re-check both after any furina reboot; a permanent MAC-pinned udev fix for the NIC is still outstanding.
7. **3090 stuck in D3cold after a failed `qm start`** — vfio-pci can't wake a device from D3cold in software; needed a full furina power cycle. **3090 also dropped off the PCI bus entirely once** — a marginal riser connection, fixed by reseating both ends; this is a real recurring risk with the vertical-mount riser, not a one-off.
8. **`x-vga=1` on a passthrough GPU with no monitor on it = silent OVMF hang.** For a headless compute VM, use `vga: serial0` (redirects console to the serial socket, readable via `qm terminal`) instead — also avoids Proxmox's automatic `kvm=off` cpu flag that comes bundled with `x-vga` on Nvidia cards.
9. **Debian cloud image's netplan didn't reliably generate its `systemd-networkd` unit files** on first boot — worked around with hand-written `.link`/`.network` files, naming them to sort lexically before anything netplan might still generate in `/run/systemd/network/`.
10. **k0s bundles containerd 1.7.x, whose CRI plugin ID is `io.containerd.grpc.v1.cri`** — not `io.containerd.cri.v1.runtime` (the 2.x-era ID). Wrong ID in the `nvidia.toml` containerd drop-in parses fine and fails completely silently.
11. **`runtimeClassName: nvidia` is required on any pod that wants the GPU** — without it, containerd uses the default runtime and no driver libs get injected (fails as "nvidia-smi: executable file not found", not an obvious GPU error).
12. **Rebalancing VM memory: shrink before grow, always.** Rebooted `ousia` into its new (larger) RAM allocation while `pneuma` was still running its old (larger) one — briefly requested more than furina's physical RAM, thrashed the host until a physical power cycle. See `feedback_furina_memory_rebalance_sequencing` memory. Side effect: Proxmox regenerates the cloud-init instance-id on every `qm set`, so a config change can make cloud-init treat the next boot as a "new instance" and regenerate the VM's SSH host key — benign, just needs `ssh-keygen -R <ip>`.
13. **Kyverno `require-run-as-nonroot` caught vllm-chat/vllm-coder/litellm running as root** (default for CUDA/Python images) — fixed with a pod-level `securityContext` (UID/GID 1000) and a matching `chown` on the `/var/lib/vllm-models` hostPath. GPU access via the nvidia CDI runtime doesn't depend on the container's UID, so this was a clean fix with no functional impact.
