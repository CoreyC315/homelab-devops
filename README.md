# 🌌 Teyvat Homelab DevOps

Production-ish homelab Kubernetes platform built on **Proxmox + k0s + ArgoCD (GitOps)**, with **MetalLB**, **Envoy Gateway (Gateway API)**, **cert-manager**, **Longhorn**, and **Synology NFS** storage. A dedicated GPU worker runs a local LLM stack (vLLM + LiteLLM + Open WebUI).

This repo is the source of truth for every cluster manifest consumed by ArgoCD. Commit to `main` and ArgoCD syncs it (auto-sync, prune, self-heal).

---

## 📌 Current State (Live)

- **Kubernetes distro:** `k0s v1.35.2+k0s.0` (declared in `terraform/k0sctl.yaml`)
- **Control plane endpoint:** `https://192.168.1.201:6443`
- **Nodes:**

  | Node | IP | Host | Notes |
  |---|---|---|---|
  | `k0s-master-1` | `192.168.1.201` | Aether | k0s controller (5 GB / 4 vCPU) |
  | `aether-worker` | `192.168.1.212` | Aether | worker, Vega iGPU passthrough for Jellyfin VAAPI |
  | `nahida-worker` | `192.168.1.213` | Nahida | worker |
  | `ousia` | `192.168.1.215` | Furina | GPU worker (RTX 3090, 30 GB RAM), sole `nvidia.com/gpu` node |

- **Gateway external IP:** `192.168.1.50` (MetalLB, shared Envoy Gateway)
- **Namespaces of note:** `default` (media apps), `ai-stack`, `glance`, `homelable`, `monitoring`, `observability`, `pipeline`, `argocd`

> Some Terraform resource names still carry `k3s-*` from an earlier cluster phase; the runtime is k0s.

---

## 🧱 Physical / Hypervisor Layer

| Host | IP | Role | Platform |
|---|---|---|---|
| **Aether** | `192.168.1.100` | Proxmox node: k0s controller VM + worker VM | Proxmox VE 9.1.6 |
| **Nahida** | `192.168.1.104` | Proxmox node: worker VM, PBS VM, Home Assistant VM | Proxmox VE 9.1.6 |
| **Furina** | `192.168.1.103` | Proxmox node: `ousia` GPU worker VM + `pneuma` gaming VM (RTX 5070 Ti) | Proxmox VE 9.x |
| **Raiden** | `192.168.1.101` | Legacy Proxmox node, being retired | — |

Supporting systems outside the cluster:

- **Synology NAS** — NFS backend for shared media (`celestia-nfs` StorageClass) and Longhorn backup target
- **Proxmox Backup Server** (`192.168.1.105`, VM on Nahida) — VM-level backups
- **Pi-hole** (`192.168.1.102`) — local DNS for `*.local` / `*.lan` hostnames
- **Home Assistant** — standalone VM on Nahida, not managed by this repo

---

## ☸️ Kubernetes + GitOps Architecture

This repo uses an **App-of-Apps** pattern.

### Prerequisite bootstrap dependency

- **ArgoCD must already be installed** in the `argocd` namespace before applying `kubernetes/infrastructure/project-bootstrap.yaml`.
- This repo does **not** include an ArgoCD install Application; it only carries ArgoCD-facing resources (HTTPRoute, config) under `kubernetes/apps/argocd/`.

### Flow

1. `kubernetes/infrastructure/project-bootstrap.yaml` creates Argo app `infrastructure`
2. `infrastructure` points at `kubernetes/infrastructure/`
3. That folder declares one child Argo Application per platform component and app

### Argo-managed platform components

| Area | Components |
|---|---|
| Networking | MetalLB, Gateway API CRDs (vendored), Envoy Gateway (Helm), shared `teyvat-gateway`, cert-manager + local CA ClusterIssuers, NetworkPolicies |
| Storage | Longhorn (Helm) + recurring backup jobs, NFS CSI driver (Helm) + `celestia-nfs` StorageClass, MinIO (S3 for Loki/Velero) |
| Security | Kyverno + policies (Enforce), Trivy Operator |
| Backup | Velero (manifests → MinIO, daily 03:00), Longhorn recurring backups → Synology |
| Observability | kube-prometheus-stack (Prometheus/Grafana/Alertmanager), Loki, Tempo, Alloy, ServiceMonitors |
| Compute / scaling | NVIDIA GPU Operator, KEDA + HTTP add-on (vLLM scale-to-zero routing) |
| CI | Actions Runner Controller (ARC) self-hosted GitHub runners in `pipeline` |

### Argo-managed applications

| Group | Apps |
|---|---|
| Media | Jellyfin, qBittorrent (gluetun VPN sidecar), Prowlarr, Radarr, Sonarr, Seerr, FlareSolverr, subgen, whisper-jellyfin |
| Manga / books | Suwayomi, Komga, cbz-maker (CronJob) |
| AI stack (`ai-stack`) | vLLM (chat / coder / redshell models), LiteLLM, Open WebUI, RAG API + TEI embeddings + Qdrant |
| Dashboards / misc | Glance, homelable, obsidian-sync |

---

## 📁 Repository Layout

```text
kubernetes/
  apps/<service>/          # Per-app manifests: deployment, service, configmap, storage, httproute
  infrastructure/          # One ArgoCD Application per component/app (+ project-bootstrap.yaml)
  manual/                  # One-time setup manifests (Synology NFS)
terraform/
  init.tf                  # Proxmox provider
  virtual-machines.tf      # Master, worker, PBS, and Home Assistant VMs
  k0sctl.yaml              # k0s cluster definition (controller + workers)
  k0s-config               # k0s config fragments
  keepalived.conf.tpl      # Control-plane VIP template
  install-k3s.sh           # Legacy bootstrap helper, not Terraform
apps/                      # Source for custom-built images (whisper-jellyfin)
scripts/                   # Host helpers: game-mode / work-mode GPU handoff, LLM demo
Documentation/             # Runbooks, hardening plan + execution log, SOPs, per-node notes
archive/                   # Retired manifests kept for reference
testing/                   # Locust load tests
web-scrapper/              # Standalone Python scraping service (Docker Compose)
versions.lock.md           # Pinned chart/image versions (update in the same commit as any bump)
renovate.json              # Renovate config for dependency PRs
```

---

## 🌐 Networking

- **Gateway:** Envoy Gateway in `envoy-gateway-system`, single shared `Gateway` (`teyvat-gateway`) on `192.168.1.50`. Apps attach via `HTTPRoute`; no `Ingress` resources remain.
- **TLS:** cert-manager with a self-signed local root CA (`homelab-local-ca` ClusterIssuer). Trust `homelab-local-root-ca.crt` from the repo root on clients.
- **MetalLB pool:** `192.168.1.50-192.168.1.55`

  | IP | Service |
  |---|---|
  | `.50` | Envoy shared gateway |
  | `.51` | Suwayomi |
  | `.52` | Seerr |
  | `.54` | Komga |
  | `.55` | LiteLLM |

- **Hostnames:** every route serves both `<app>.local` and `<app>.lan`, resolved by Pi-hole.

| Hostname | Service |
|---|---|
| `argo` | ArgoCD |
| `glance` | Glance dashboard |
| `homelable` | homelable |
| `jellyfin` | Jellyfin |
| `qbit` | qBittorrent |
| `prowlarr` / `radarr` / `sonarr` / `seerr` | *arr stack |
| `suwayomi` / `komga` | manga / comics |
| `ai` | Open WebUI |
| `llm` | LiteLLM |
| `grafana` / `prometheus` | monitoring |
| `longhorn` / `minio` | storage UIs |

---

## 💾 Storage Strategy

### StorageClasses

- `longhorn` (**default**) — app config/state (RWO), replicated across workers
- `celestia-nfs` — shared media/data on the Synology NAS (RWX, `Retain`)

### Intentional split

- **Config/state data** → Longhorn PVCs, backed up on a recurring schedule to the NAS
- **Shared media payloads** → Synology NFS via the shared `irminsul-records-celestia-pvc`
- **Object storage** → in-cluster MinIO for Loki chunks and Velero manifests

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
kubectl get gateway,httproute -A
kubectl get sc,pv,pvc -A
```

### Resource pressure snapshot

```bash
kubectl top nodes
kubectl top pods -A | head -n 50
```

### Provisioning

```bash
cd terraform && terraform plan && terraform apply   # Proxmox VMs
k0sctl apply --config terraform/k0sctl.yaml         # k0s bootstrap / node add
```

### Proxmox quick checks

```bash
ssh root@aether 'pveversion; pvesm status; qm list'
ssh root@nahida 'pveversion; pvesm status; qm list'
ssh root@furina 'pveversion; pvesm status; qm list'
```

Runbooks for node rebuilds, Longhorn recovery, GPU handoff, and the LLM platform live in `Documentation/`.

---

## ⚠️ Notes / Known Drift

- Longhorn and MetalLB may report `OutOfSync` due to CRD drift noise while still healthy.
- Longhorn replica count must match the worker count or volumes sit permanently degraded.
- `ousia` shares Furina with the `pneuma` gaming VM; GPU ownership is swapped with `scripts/game-mode.sh` / `scripts/work-mode.sh`.
- Some Terraform resource names retain `k3s-*` naming from the original cluster.
- Terraform state is local and `.gitignored`; keep Terraform and live Proxmox changes aligned.
- Secrets (VPN keys, runner tokens, API keys) are created out-of-band and never stored here.

---

## 🗺️ Roadmap

- [ ] Pin remaining `:latest` app images (tracked in `versions.lock.md`)
- [ ] Promote to a multi-controller topology (one per physical host)
- [ ] Add a 4th node (Minisforum MS-A2 + Intel Arc Pro B50) as a second inference box
- [ ] Retire Raiden fully

Completed: GPU inference node (`ousia`), Ingress NGINX → Envoy Gateway migration, cert-manager TLS, Kyverno Enforce, Velero + Longhorn backups, Loki/Tempo/Alloy observability, ARC CI runners.

---

## 🔒 Security & Reliability Practices

- Kyverno policies (Enforce) require non-root, no privilege escalation, resource limits, probes, and no `:latest` tags
- Trivy Operator scans running images; Renovate proposes version bumps
- Baseline NetworkPolicies per namespace (DNS, same-namespace, gateway, monitoring, and S3 consumer ingress only)
- Backups in layers: Git (manifests), Velero (cluster resources), Longhorn → NAS (volumes), PBS (VMs)
- Keep control-plane workloads isolated from heavy media/LLM workloads
