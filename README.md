# 🌌 Teyvat Homelab Cluster

A distributed, high-availability Kubernetes cluster spanning multiple **Proxmox** hypervisors and **Bare Metal** ARM devices. This cluster leverages **GitOps** for automated deployments and **Longhorn** for resilient, distributed storage.



---

## 🏗️ Hardware Architecture

The cluster is named after the world of Teyvat, with nodes distributed across different physical hardware to balance compute power and energy efficiency.

### Physical Hosts
| Hostname | Hardware | Role | OS / Hypervisor |
| :--- | :--- | :--- | :--- |
| **Raiden** | Mini PC | Virtualization Host | Proxmox VE 8.x |
| **Aether** | Mini PC | Virtualization Host | Proxmox VE 8.x |
| **Paimon** | Raspberry Pi | Bare Metal Worker | Debian (ARM64) |
| **Lumine** | Mini PC (N100) | Media Transcoding | *Incoming* |

---

## ☸️ Kubernetes Topology
**Distribution:** k0s (v1.30.2)  
**Control Plane:** 1 Node  
**Workers:** 4 Nodes (Current)

### Node Inventory
| Node Name | Physical Host | CPU | RAM | Type |
| :--- | :--- | :--- | :--- | :--- |
| `k3s-master-1` | Raiden | 2 vCPU | 2 GB | VM |
| `k3s-worker-1` | Raiden | 4 vCPU | 10 GB | VM |
| `k3s-worker-aether-1` | Aether | 4 vCPU | 12 GB | VM |
| `k3s-worker-aether-2` | Aether | 4 vCPU | 12 GB | VM |
| `paimon` | RPi | 4 Cores | 4 GB | Bare Metal |

---

## 🚀 Deployed Services

### 🛠️ Cluster Infrastructure
* **GitOps:** [ArgoCD](https://argoproj.github.io/cd/) - Managing application lifecycles.
* **Ingress:** `ingress-nginx` - Routing external traffic.
* **Load Balancer:** `MetalLB` - Assigned Layer 2 IP: `192.168.1.50`.
* **Storage:** `Longhorn` - Replicated block storage across all nodes.
* **Monitoring:** `Prometheus` & `Grafana` - Full stack observability.

### 📂 Hosted Applications
* 🎬 **Jellyfin** - Personal media streaming.
* 📂 **Filestash** - Web-based file management and S3/FTP client.
* 📊 **Glance** - Minimalist self-hosted dashboard.
* 🚀 **Metrics Server** - Enabling HPA and resource monitoring.

---

## 💾 Storage & Data Management
The cluster currently utilizes **Longhorn** for persistent volumes, ensuring data high availability. 

---

## 🛠️ Tech Stack
![Proxmox](https://img.shields.io/badge/Proxmox-E57020?style=for-the-badge&logo=proxmox&logoColor=white)
![Kubernetes](https://img.shields.io/badge/kubernetes-%23326ce5.svg?style=for-the-badge&logo=kubernetes&logoColor=white)
![ArgoCD](https://img.shields.io/badge/Argo%20CD-ef7b4d?style=for-the-badge&logo=argo-cd&logoColor=white)
![Raspberry Pi](https://img.shields.io/badge/-RaspberryPi-C51A4A?style=for-the-badge&logo=Raspberry-Pi)

---

## 📅 Roadmap
- [ ] **Lumine Integration:** Add the N100 Mini PC to the cluster.
- [ ] **GPU Passthrough:** Configure Intel QuickSync on Lumine for Jellyfin transcoding.
- [ ] **Storage Expansion:** Deploy TrueNAS on Aether for 1TB media storage.
- [ ] **Ad-Blocking:** Deploy and configure **Pi-hole** in the `kube-system` namespace.
