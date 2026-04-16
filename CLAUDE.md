# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Repo Is

GitOps source of truth for a homelab Kubernetes platform called "Teyvat". ArgoCD watches this repo and syncs changes automatically to the cluster. The cluster runs k0s v1.35.2 on Proxmox VMs.

- **Control plane**: `192.168.1.201:6443`
- **Ingress IP**: `192.168.1.50` (MetalLB)
- **Node IPs**: `.201` (controller), `.211`, `.212`, `.213` (workers)

## Deployment Model

Changes are deployed by committing to `main`. ArgoCD auto-syncs with prune + self-heal enabled — no manual `kubectl apply` needed for anything under `kubernetes/`.

Entry point: `kubernetes/infrastructure/project-bootstrap.yaml` → creates an `infrastructure` ArgoCD Application → which declares child Applications for each platform component and app.

## Key Commands

```bash
# Cluster health
kubectl cluster-info
kubectl get nodes -o wide
kubectl get pods -A
kubectl get applications.argoproj.io -n argocd
kubectl top nodes && kubectl top pods -A

# Terraform (Proxmox VM provisioning)
cd terraform && terraform plan
cd terraform && terraform apply

# k0s cluster bootstrap (one-time)
k0sctl apply --config terraform/k0sctl.yaml

# Load testing
cd testing && locust -f locustfile.py

# Web scraper (separate Docker project)
cd web-scrapper && docker compose up
```

## Repository Layout

```
kubernetes/apps/<service>/     # Per-app K8s manifests
kubernetes/infrastructure/     # ArgoCD Applications for platform components
kubernetes/manual/             # One-time setup manifests (Synology NFS)
terraform/                     # Proxmox VM definitions + k0s bootstrap config
web-scrapper/                  # Standalone Python scraping service (Redis queue)
testing/                       # Locust load tests
Documentation/                 # Operational runbooks and deep-dive docs
```

## Conventions

**App manifest structure** — each service under `kubernetes/apps/<name>/` follows:
`deployment.yaml`, `service.yaml`, `configmap.yaml`, `storage.yaml`, `ingress.yaml`

**Storage split** (intentional two-tier):

- `longhorn` (default, RWO) — app config/state, replicated across nodes
- `celestia-nfs` (RWX, Retain) — shared media payloads on Synology NAS

**Helm-managed components** (Ingress NGINX, Longhorn, NFS CSI, cert-manager, kube-prometheus-stack) are declared as ArgoCD Applications pointing to Helm repos, not as raw manifests.

**Secrets** are created manually out-of-band and not stored in this repo. Example: `protonvpn-secret` for the qBittorrent/gluetun sidecar.

**Node naming**: VMs and nodes use `k3s-*` prefix — legacy artifact from a prior k3s phase, the cluster now runs k0s.

## Known Quirks

- Longhorn and MetalLB ArgoCD Applications may show `OutOfSync` due to CRD drift — this is cosmetic; the services function correctly.
- Most app images use `:latest` tags (pinning is a planned improvement).
- Terraform state is local and `.gitignored`.
- SSH host key verification is disabled in `terraform/install-k3s.sh` (intentional for ephemeral reprovisioning).

## Obsidian Vault

My notes and documentation live at '/Users/ccampbell/Homelab'

## Documentation Convention

When completing tasks, write a summary note to ~/Users//vault/claude-logs/YYYY-MM-DD-<task>.md
covering: what was done, why, any commands run, and gotchas encountered.
