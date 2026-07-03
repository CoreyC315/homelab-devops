# Furina Cutover & Cleanup Checklist

Execution checklist for the maintenance window when **furina** (GPU box) arrives
(2026-06-26) and **raiden** is retired. Everything here was mapped/verified
2026-06-25; commit + push the GitOps parts when furina is ready.

Companion docs:
- `furina-gpu-box-runbook.md` — furina host install, passthrough, burn-in, GPU workloads.
- `teyvat-hardening-plan.md` — the separate 16-phase modernization (do NOT bundle into
  this window; it's GitOps/strangler-fig and wants apps up, not a downtime push).

> **Sequencing rule:** burn-in furina **while it's still returnable** (gpu-burn, EXPO
> stability, throughput baseline — see runbook Phase 1) BEFORE trusting it enough to
> drain raiden onto it.

---

## Part 1 — GitOps changes (commit to `main`, ArgoCD syncs; no downtime needed)

These are safe to commit independently. Grouped into logical commits.

### Commit A — Longhorn pod-mobility fixes ⭐ (the actual "pod won't move" bug)

**A1. `strategy: Recreate` on the 4 Longhorn-RWO-backed Deployments.**
A Longhorn RWO volume attaches to exactly one node at a time. Default `RollingUpdate`
starts the new pod (often on another node) before the old one releases the volume →
Multi-Attach deadlock → stuck `ContainerCreating` ~6 min. `Recreate` makes the old pod
detach first. No downtime benefit lost (single-replica apps can't share the volume anyway).

| App | File | Backing |
|-----|------|---------|
| komga | `kubernetes/apps/komga/komga-deployment.yaml` | Longhorn RWO ✔ |
| qbittorrent | `kubernetes/apps/qbittorrent/qbittorrent-deployment.yaml` | Longhorn RWO ✔ |
| radarr | `kubernetes/apps/radarr/radarr-deployment.yaml` | Longhorn RWO ✔ |
| sonarr | `kubernetes/apps/sonarr/sonarr-deployment.yaml` | Longhorn RWO ✔ |

Edit: add under `spec:` (sibling of `replicas:`), none of these set a strategy today:
```yaml
spec:
  replicas: 1
  strategy:
    type: Recreate
```
**Excluded on purpose:**
- `prowlarr` — shared **NFS** (RWX, `storageClassName: ""`), multi-attach is fine. Leave RollingUpdate.
- `glance`, `flaresolverr` — configmap-only, no Longhorn PVC. Leave as-is.
- `whisper-jellyfin` — being retired (see runbook Phase 2). Don't touch; delete it instead.

**A2. `nodeDownPodDeletionPolicy` — let Longhorn self-recover from a dead node.**
Currently `do-nothing` (verified live): when a node dies hard, the pod hangs and the
volume stays attached to the dead node forever — which is why `node-death-recovery`
has us clearing attachments by hand. Safe to enable here (daily NAS backups exist).

File: `kubernetes/infrastructure/longhorn-app.yaml`, in the existing `defaultSettings:`
block (line ~18):
```yaml
        defaultSettings:
          replicaNodeSoftAntiAffinity: false
          nodeDrainPolicy: allow-if-replica-is-stopped
          nodeDownPodDeletionPolicy: delete-both-statefulset-and-deployment-pod   # ADD
```
Set it here (not `kubectl patch`) so ArgoCD self-heal / chart re-sync can't revert it.

> **Not doing:** `dataLocality: best-effort`. SC is `disabled` today; best-effort adds a
> rebuild on every pod move. A1+A2 fix the hangs; revisit only if read latency bites.

### Commit B — Legacy / naming cleanup ("get things in order")
- **Untrack 4 `.DS_Store` files**: `git rm --cached` them + add `**/.DS_Store` to `.gitignore`.
- **`terraform/install-k3s.sh`** → rename to `install-k0s.sh` (or delete if dead — confirm
  it's unreferenced first). Cluster's been k0s for a while; name is a leftover.

### Commit C — Image pins (do as the workloads move to furina)
Of the 6 floating tags, 4 are GPU-bound and you're touching them during the move anyway:
- `ollama:latest` (×2), `open-webui:main`, `subgen:latest` → pin to a concrete version
  as you retarget them at furina's GPU.
- `whisper-jellyfin:latest` → **delete the app**, don't pin (retired per runbook).
- `alpine/git:latest` (obsidian-sync cron) → pin opportunistically.

Pinning these clears most of the Kyverno-Enforce blocker for the hardening plan later.

---

## Part 2 — Window-only / imperative work (not GitOps)

### B1. Pre-flight (before touching anything)
- [ ] furina burn-in PASSED (runbook Phase 1) — still returnable until trusted.
- [ ] Verify a **current, restorable PBS backup** of VM 211 exists *before* destroying it.
- [ ] `kubectl get nodes` — confirm aether/nahida Ready.

### B2. furina joins as a worker
- [ ] Per runbook Phase 0/2: PVE install + GPU passthrough, join k0s as worker, NVIDIA
      device plugin, pin GPU pods (ollama/open-webui/subgen) via nodeSelector.

### B3. Drain & remove raiden (cluster now has aether+nahida+furina)
- [ ] **Evacuate Longhorn first**: disable scheduling + request eviction on `raiden-worker`;
      wait for replicas to rebuild onto the others. (Only step where rushing risks data.)
- [ ] `kubectl cordon raiden-worker`
- [ ] `kubectl drain raiden-worker --ignore-daemonsets --delete-emptydir-data`
- [ ] Delete the Longhorn node CR for raiden (won't self-clean — known quirk).
- [ ] `kubectl delete node raiden-worker`

### B4. Longhorn replica count through the swap
- [ ] During 2-node window: replica-count stays **2** (already is) → no permanent-degraded.
- [ ] After furina joins (3 workers): bump back to **3** — `default-replica-count` setting
      + `persistence.defaultClassReplicaCount: 3` (already 3 in `longhorn-app.yaml`) + bump
      existing volumes' `numberOfReplicas` to 3.

### B5. Terraform / Proxmox host removal
- [ ] Remove the `k0s_worker_raiden` resource (`terraform/virtual-machines.tf:138`) so it
      isn't recreated; `terraform apply` to destroy VM 211.
- [ ] **Verify no other guests live on the raiden PVE host** (PBS is .105 — confirm it's
      not parked there) before removing the host.
- [ ] `pvecm delnode raiden` from aether/nahida (raiden is a corosync member — don't just
      unplug it or the 2-node cluster goes quorum-fragile).
- [ ] Power off; **wipe the SSD** (Longhorn replica data + touched `protonvpn-secret`)
      before it goes to work for CKA labbing.

### B6. Template consolidation (do while building furina's template)
- [ ] Collapse the **3 per-host templates** (`ubuntu-cloud-template-v2`, `-nahida`,
      `-raiden` — see `virtual-machines.tf:21,78,200`) into **one canonical template**;
      point all VMs at it. The `-raiden` template dies with raiden.
- [ ] **Bake `fs.inotify.max_user_instances=512` + `max_user_watches`** into that template
      so new nodes don't come up at the default 128 (media apps crash otherwise — recurring
      footgun we hand-fix every rebuild).

---

## Open decision (resolve before the window)

**Blast-radius topology.** Today VM 201 (control-plane master) **and** aether-worker both
run on the aether host (`virtual-machines.tf:20` + `:77`) — one host failure takes the
control plane AND a worker. With furina adding a 4th machine, the window is the time to
move aether-worker off so aether carries only the master. Recommend: **single CP on its
own host, workers spread across nahida/furina/(raiden's old slot)** — skip full HA control
plane (3 etcd members = more failure surface than it removes for a homelab). Needs a target
VM-layout sketch before executing.
