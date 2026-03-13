# 🌌 Teyvat Homelab DevOps

Production-ish homelab Kubernetes platform built on **Proxmox + k0s + ArgoCD (GitOps)**, with **MetalLB**, **Ingress NGINX**, **Longhorn**, and **TrueNAS NFS** storage.

This repo is the source of truth for cluster application and infrastructure manifests consumed by ArgoCD.

---

## 📌 Current State (Live)

- **Kubernetes distro:** `k0s v1.30.2+k0s.0`
- **Control plane endpoint:** `https://192.168.1.201:6443`
- **Workers currently active:**
  - `k3s-worker-1` (`192.168.1.211`)
  - `k3s-worker-aether-0` (`192.168.1.212`)
- **Cluster config declared in `terraform/k0sctl.yaml`:**
  - `k3s-worker-1` (`192.168.1.211`)
  - `k3s-worker-aether-0` (`192.168.1.212`)
  - `nahida-worker` (`192.168.1.213`)
- **Ingress external IP:** `192.168.1.50` (MetalLB)
- **Primary app namespace(s):** `default`, `glance`, `monitoring`, `argocd`

> Note: some names still use `k3s-*` from earlier cluster phases; runtime is k0s.

---

## 🧱 Physical / Hypervisor Layer

| Host | Role | Platform |
|---|---|---|
| **Aether** (`192.168.1.100`) | Proxmox node, TrueNAS VM, worker VM | Proxmox VE 9.1.4 |
| **Raiden** (`192.168.1.101`) | Proxmox node, controller VM, worker VM | Proxmox VE 9.1.4 |
| **Nahida** (`192.168.1.104`) | Proxmox node, worker VM | Proxmox VE 9.1.4 |

### Key VMs

| VM | Host | Purpose |
|---|---|---|
| `k3s-master-1` | Raiden | k0s controller |
| `k3s-worker-1` | Raiden | Kubernetes worker |
| `k3s-worker-aether-0` | Aether | Kubernetes worker |
| `nahida-worker` | Nahida | Kubernetes worker |
| `truenas-scale` | Aether | NAS backend (NFS for shared media) |

---

## ☸️ Kubernetes + GitOps Architecture

This repo uses an **App-of-Apps** pattern.

### Prerequisite bootstrap dependency

- **ArgoCD must already be installed** in the `argocd` namespace before applying `kubernetes/infrastructure/project-bootstrap.yaml`.
- This repo does **not** include an ArgoCD install Application; it only includes ArgoCD-facing resources such as [`kubernetes/apps/argocd/ingress.yaml`](kubernetes/apps/argocd/ingress.yaml).

### Flow

1. `kubernetes/infrastructure/project-bootstrap.yaml` creates Argo app `infrastructure`
2. `infrastructure` points at `kubernetes/infrastructure/`
3. That folder declares child Argo Applications for platform + app workloads

### Argo-managed platform components

- Ingress NGINX (Helm)
- MetalLB
- Longhorn (Helm)
- NFS CSI driver (Helm + local StorageClass)
- kube-prometheus-stack (Prometheus/Grafana)

### Argo-managed application components

- Glance
- Jellyfin
- qBittorrent
- Prowlarr
- Radarr
- Sonarr
- Overseerr

---

## 📁 Repository Layout

```text
kubernetes/
  apps/
    argocd/
    glance/
    jellyfin/
    monitoring/
    networking/
    nfs-driver/
    overseerr/
    prowlarr/
    qbittorrent/
    radarr/
    sonarr/
  infrastructure/
    project-bootstrap.yaml
    *.yaml (Argo Applications)

terraform/
  init.tf
  virtual-machines.tf
  k0sctl.yaml
  install-k3s.sh (legacy bootstrap helper script, not Terraform)
```

---

## 🚀 Deployed Services

### Platform

- **ArgoCD** - GitOps controller (bootstrap prerequisite; not installed by this repo)
- **Ingress NGINX** - HTTP ingress controller
- **MetalLB** - Bare-metal LoadBalancer IP allocation
- **Longhorn** - Replicated block storage (default class)
- **NFS CSI Driver** - Dynamic NFS-backed PV provisioning
- **Prometheus + Grafana** - Monitoring stack

### Applications

- **Glance** (`glance.local`) - dashboard/homepage
- **Jellyfin** (`jellyfin.local`) - media server
- **qBittorrent** (`qbit.local`) - downloader (with gluetun VPN sidecar)
- **Prowlarr** (`prowlarr.local`) - indexer manager
- **Radarr** (`radarr.local`) - movies automation
- **Sonarr** (`sonarr.local`) - TV automation
- **Overseerr** (`overseerr.local`) - media request management
- **Longhorn UI** (`longhorn.local`)

---

## 🌐 Networking

- **Ingress Controller Service:** `ingress-nginx-controller` (`LoadBalancer`)
- **Assigned external IP:** `192.168.1.50`
- **MetalLB pool:** `192.168.1.50-192.168.1.55`

Typical local DNS strategy:
- Either local DNS server entries
- Or `/etc/hosts` mappings for `*.local` test domains

---

## 💾 Storage Strategy

### StorageClasses

- `longhorn` (**default**) - app config/state (RWO)
- `truenas-nfs` - shared media/data (RWX, `Retain`)

### Intentional split

- **Config/state data** -> Longhorn PVCs
- **Shared media payloads** -> TrueNAS NFS via `irminsul-records-pvc`

This keeps media data centralized while preserving resilient app config volumes.

---

## 🛠️ Operations Cheat Sheet

### Validate cluster reachability

```bash
kubectl cluster-info
kubectl get nodes -o wide
```

### Check core health

```bash
kubectl get pods -A
kubectl get applications.argoproj.io -n argocd
kubectl get ingress -A
kubectl get sc,pv,pvc -A
```

### Resource pressure snapshot

```bash
kubectl top nodes
kubectl top pods -A | head -n 50
```

### Proxmox quick checks

```bash
ssh root@aether 'pveversion; pvesm status; qm list'
ssh root@raiden 'pveversion; pvesm status; qm list'
```

---

## ⚠️ Notes / Known Drift

- Longhorn and MetalLB may occasionally report `OutOfSync` due to CRD drift noise while still healthy.
- Some filenames and node names reflect older phases (k3s naming retained).
- Keep Terraform + live Proxmox changes aligned to avoid config drift.

---

## 🗺️ Roadmap

- [ ] Add new PC for dedicated control-plane/LLM workloads
- [ ] Promote to 3-controller topology (one per physical host)
- [ ] Pin app image versions (reduce `:latest` risk)
- [ ] Improve backup/restore runbooks (etcd + app + NAS)

---

## 🔒 Security & Reliability Practices

- Prefer scoped service accounts over admin kubeconfigs
- Backup:
  - Argo manifests (Git)
  - Kubernetes secrets strategy (SOPS/ExternalSecrets if added)
  - TrueNAS snapshots + off-host copy
- Keep control-plane workloads isolated from heavy media/LLM workloads
