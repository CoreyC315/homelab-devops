# Homelab Cluster Deep Dive

_Date:_ 2026-02-27  
_Method:_ Read-only audit of GitOps repo + live Kubernetes API + Proxmox hypervisors (`aether`, `raiden`).  
_Change policy followed:_ No infrastructure changes were made.

---

## 1) Executive Summary

Your homelab is a **GitOps-managed k0s Kubernetes cluster** on top of **Proxmox VE 9.1.4**, with:

- 2 active Kubernetes worker VMs (`k3s-worker-1`, `k3s-worker-aether-0`)
- 1 controller VM (`k3s-master-1`) hosting API server (`192.168.1.201:6443`) in **controller-only mode** (`Workloads: false`)
- ArgoCD managing both local manifests and Helm-based infra apps
- MetalLB providing L2 LoadBalancer addresses (`192.168.1.50-192.168.1.55`)
- Longhorn + NFS CSI together for storage (RWO on Longhorn, RWX media on TrueNAS NFS)
- App stack focused on media workflow (qBittorrent/Prowlarr/Radarr/Sonarr/Jellyfin) + Glance dashboard + monitoring

Overall: cluster is healthy and serving workloads, with two persistent GitOps drifts (Longhorn/MetalLB CRDs) that appear benign but noisy.

---

## 2) Physical & Virtual Substrate (Proxmox)

## 2.1 Proxmox Cluster Nodes

- **aether**
  - Proxmox: `pve-manager/9.1.4`
  - Kernel: `6.17.2-1-pve`
  - CPU capacity: 16 vCPU
  - RAM: 29.3 GiB (currently highly utilized)
- **raiden**
  - Proxmox: `pve-manager/9.1.4`
  - Kernel: `6.17.4-1-pve`
  - CPU capacity: 8 vCPU
  - RAM: 16.7 GiB (currently highly utilized)

## 2.2 VM Inventory (Observed)

### On `raiden`
- `k3s-master-1` (VMID 201)
  - 2 vCPU, 2 GiB RAM, 20G disk, IP `192.168.1.201`
- `k3s-worker-1` (VMID 211)
  - 4 vCPU, 10 GiB RAM, 40G disk, IP `192.168.1.211`
- template VMs present (stopped)

### On `aether`
- `k3s-worker-aether-0` (VMID 112)
  - 4 vCPU, 10G RAM configured (~9.3G in use), 60G disk, IP `192.168.1.212`
- `truenas-scale` (VMID 100)
  - 2 vCPU, 16 GiB RAM, OS disk + large virtio data disk (~700G)
- template VM present (stopped)

No LXC containers detected on either host.

## 2.3 Storage Backends (Proxmox)

- Shared NFS storage: `raiden-storage` (mounted on both nodes)
- Node-local LVM thin pools (`local-lvm`) for VM disks
- Node-local dir storage (`local`) for ISO/backups/templates

---

## 3) Kubernetes Control Plane & Node Topology

- API endpoint: `https://192.168.1.201:6443`
- Distribution: `k0s v1.30.2+k0s.0`
- Controller status (on 192.168.1.201):
  - Role: `controller`
  - `Workloads: false` (controller-only)
  - service active: `k0scontroller`

### Registered worker nodes
1. `k3s-worker-1` (`192.168.1.211`)
   - 4 CPU, allocatable memory ~9.6 GiB
2. `k3s-worker-aether-0` (`192.168.1.212`)
   - 4 CPU, allocatable memory ~9.4 GiB

Both workers are `Ready` and untainted.

**Note:** README and `k0sctl.yaml` mention additional nodes (e.g., Raspberry Pi and a second Aether worker), but they are not currently registered in this cluster state.

---

## 4) Namespaces & Platform Services

Active namespaces include:

- `argocd`
- `azure-arc`, `azure-arc-release`
- `ingress-nginx`
- `metallb-system`
- `longhorn-system`
- `monitoring`
- `glance`
- `default`
- core system namespaces (`kube-system`, etc.)

### Major platform components running

- **ArgoCD** (full core stack in `argocd`)
- **Ingress NGINX** controller (LoadBalancer exposed)
- **MetalLB** controller + speakers
- **Longhorn** manager, UI, CSI components
- **NFS CSI driver** (`kube-system`)
- **Prometheus/Grafana stack** in `monitoring`
- **Azure Arc agents** (multiple controllers/operators)

---

## 5) GitOps Architecture (ArgoCD)

## 5.1 App-of-Apps bootstrap

- `kubernetes/infrastructure/project-bootstrap.yaml` defines `Application` named `infrastructure`
- It targets `kubernetes/infrastructure` path in this repo
- That path defines child Applications (local manifests + Helm/chart sources)

## 5.2 ArgoCD Applications (Live)

Healthy+Synced:
- glance
- infrastructure
- ingress-nginx
- jellyfin
- kube-prometheus-stack
- monitoring
- networking
- nfs-csi-driver
- nfs-driver
- prowlarr
- qbittorrent
- radarr
- sonarr

Healthy but OutOfSync:
- longhorn
- metallb

### OutOfSync specifics

- `longhorn`: several Longhorn CRDs flagged OutOfSync
- `metallb`: `bgppeers.metallb.io` CRD flagged OutOfSync

Recent event stream shows Argo repeatedly attempting partial syncs for both apps at short intervals (recurring churn).

---

## 6) Networking Model

## 6.1 Ingress + LoadBalancer

- `ingress-nginx-controller` Service is `LoadBalancer` on **192.168.1.50**
- MetalLB pool configured: **192.168.1.50-192.168.1.55**

## 6.2 Ingress hosts

- `glance.local` → Glance
- `jellyfin.local` → Jellyfin
- `prowlarr.local` → Prowlarr
- `qbit.local` → qBittorrent
- `radarr.local` → Radarr
- `sonarr.local` → Sonarr
- `pihole.local` → Pi-hole
- `longhorn.local` → Longhorn UI
- `argo.local` manifest exists in repo (`kubernetes/apps/argocd/ingress.yaml`)

## 6.3 DNS / Ad-blocking

- `pihole-dns` Service is `LoadBalancer` on **192.168.1.51** exposing:
  - DNS TCP/UDP 53
  - HTTP 80

---

## 7) Storage Model

## 7.1 StorageClasses

- `longhorn` (**default**, RWO workloads)
- `longhorn-static`
- `truenas-nfs` (NFS CSI, `Retain` reclaim policy)

## 7.2 Persistent volumes

- App config PVCs (Longhorn): Pihole, Jellyfin config, Prowlarr, qBittorrent, Radarr, Sonarr
- Shared media PVC:
  - `irminsul-records-pvc` (10Gi request, RWX, class `truenas-nfs`)
  - Used as shared `/data` or `/media` across media applications

## 7.3 Data path intent

- **State/config** on Longhorn (resilient block volumes)
- **Bulk media** on TrueNAS NFS share (`192.168.1.103:/mnt/celestia/testing`)

This is a strong split for your workload profile.

---

## 8) Workload-by-Workload Service Map

## 8.1 Glance (`namespace: glance`)

- Image: `glanceapp/glance:latest`
- 1 replica, ClusterIP service on port 80
- Ingress: `glance.local`
- Uses ConfigMap-driven `glance.yml`
- Resource profile is lightweight

## 8.2 Jellyfin (`namespace: default`)

- Image: `jellyfin/jellyfin:latest`
- Service: `jellyfin-service` (80 → 8096)
- Ingress: `jellyfin.local` + catch-all rule
- Volumes:
  - `/config` from `akasha-config-pvc` (Longhorn)
  - `/media` from `irminsul-records-pvc` (NFS RWX)

## 8.3 qBittorrent (`namespace: default`)

- Containers in one pod:
  - `qmcgaw/gluetun:latest` (VPN sidecar with `NET_ADMIN`)
  - `lscr.io/linuxserver/qbittorrent:latest`
- Service ports: 8080 (UI), 6881 TCP/UDP
- Ingress: `qbit.local`
- Volumes:
  - config on Longhorn
  - data on shared NFS RWX PVC
- Uses secret ref `protonvpn-secret` for VPN env

## 8.4 Prowlarr / Radarr / Sonarr (`namespace: default`)

Common pattern:
- LinuxServer images (`:latest` tags)
- Config PVC per app on Longhorn
- Shared `/data` on `irminsul-records-pvc` (NFS)
- Ingress host per app (`prowlarr.local`, `radarr.local`, `sonarr.local`)

This establishes your media-automation pipeline around one shared RWX data substrate.

## 8.5 Monitoring (`namespace: monitoring`)

- Deployed via `kube-prometheus-stack` Helm app (chart 61.3.2)
- Components observed:
  - Prometheus (statefulset)
  - Alertmanager (statefulset)
  - Grafana
  - kube-state-metrics
  - node-exporter daemonset

---

## 9) Runtime Resource Observations

## 9.1 Node utilization snapshot

- `k3s-worker-1`: ~3% CPU, ~63% memory
- `k3s-worker-aether-0`: ~6% CPU, ~55% memory

## 9.2 Top memory consumers (pods)

- `jellyfin` ~2.8 GiB
- `qbittorrent` ~2.4 GiB
- `prometheus` ~441 MiB
- `argocd-application-controller` ~347 MiB
- `longhorn-manager` (notably one instance) up to ~284 MiB

Your current pressure appears primarily memory-oriented due to media services.

---

## 10) Repo vs Live State Notes

1. **Cluster naming drift:** node names still use `k3s-*` while runtime is k0s. Cosmetic but potentially confusing.
2. **Topology drift:** docs include nodes not currently participating (Pi, second Aether worker, possibly controller-as-node expectations).
3. **Argo drift noise:** repeated auto-sync loops on Longhorn/MetalLB CRDs.
4. **File naming typo:** `kubernetes/apps/nfs-driver/nfs-csi-driver.yaml.yaml` (double extension).
5. **Monitoring app destination namespace note:** `kubernetes/infrastructure/monitoring.yaml` destination is `argocd` while child chart deploys to `monitoring`; functionally works because Application CR lives in argocd, but worth documenting clearly.

---

## 11) Risks & Operational Considerations (Read-only Findings)

- Extensive `:latest` image tags across user apps increase update unpredictability.
- qBittorrent pod requires privileged network capability (`NET_ADMIN`) for gluetun sidecar.
- Controller VM is modest (2 GiB) but currently controller-only, which is appropriate.
- Argo sync churn could mask genuinely important drift/noise in event streams.
- NFS media path is single backend dependency (TrueNAS availability impacts all media apps).

---

## 12) Recommended Next Documentation Artifacts

If you want, next I can generate these as separate files in-repo:

1. `docs/architecture.md` (network/data/control diagrams + ownership)
2. `docs/services/<service>.md` per app (ports, storage, ingress, dependencies, recovery)
3. `docs/runbooks/` (restore, node failure, storage outage, Argo drift troubleshooting)
4. `docs/inventory.md` (single source of truth for physical + VM + k8s nodes)

---

## 13) Command Basis (what this audit used)

- `kubectl cluster-info`, `get nodes/pods/svc/ingress/sc/pv/pvc/events/top`
- `kubectl get applications.argoproj.io -A`
- Proxmox API via `pvesh` and VM inspection via `qm config` on `aether` and `raiden`
- Static repo review of `kubernetes/` and `terraform/`

No mutating operations (`apply`, `delete`, `patch`, `terraform apply`) were run.
