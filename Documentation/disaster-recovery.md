# Teyvat disaster recovery playbook

How to get the cluster back after losing the master, or everything. Written 2026-11-16 when
PBS was retired: VMs are now treated as **cattle** (Terraform + k0sctl). Their *state* lives in
four backups outside the cluster.

## What must survive outside the cluster

| Thing | Where | Restores |
|---|---|---|
| This repo | GitHub (`CoreyC315/homelab-devops`) | VM definitions, k0s config, every Argo app |
| **SOPS age key** (`age1skrf3yy…qsgjqzd743s`) | admin Mac `~/.config/sops/age/keys.txt` **+ password manager** | decrypts `kubernetes/secrets/*.sops.yaml` |
| k0s controller backups (etcd + PKI) | Synology `/volume1/backups/k0s-controller/` (nightly 01:30, keep 7, root-only) | the whole control plane, as-is |
| Longhorn volume backups | Synology `/volume1/backups/backupstore` (daily 02:00, keep 7) | app config/state PVCs |
| Media | Synology `celestia-nfs` shares | untouched by any of this; PVs reconnect |
| `terraform/terraform.tfstate` + `credentials.auto.tfvars` | admin Mac only (gitignored) | painless `terraform apply`; **keep a copy in the password manager / NAS** |

> ⚠ The age key is the single root of trust. Lose it and every `*.sops.yaml` is unrecoverable
> (you'd re-create each secret by hand). macOS `sops` needs
> `export SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt`.
>
> ⚠ The k0s backup contains every Secret in plaintext. Keep `k0s-controller/` root-only.

Getting a k0s backup off the NAS (the folder is root-only):
```bash
ssh starrider315@192.168.1.210 'sudo ls -t /volume1/backups/k0s-controller/'
ssh starrider315@192.168.1.210 'sudo cat /volume1/backups/k0s-controller/<k0s_backup_…tar.gz>' > ~/k0s_backup.tar.gz
```

---

## Scenario A: master (VM 201) dead, workers fine. ~15 min

This is the likely case: one VM on aether.

1. **Confirm it's dead, not network-isolated.** See the quorum/no-route note in the node-death notes.
   If the *host* (aether) is gone too, the master moves to nahida: set `target_node` for the
   master in `terraform/virtual-machines.tf`, and remove the dead host's `/etc/pve/nodes/<host>/qemu-server/201.conf`.
2. Recreate the VM: `cd terraform && terraform apply -target=proxmox_vm_qemu.k0s_master`
   (same IP .201 via cloud-init).
3. Fetch the newest k0s backup (above), then restore:
   ```bash
   k0sctl apply --config terraform/k0sctl.yaml --restore-from ~/k0s_backup.tar.gz
   ```
   Same CA, so workers (incl. ousia) reconnect on their own. Every Secret, Argo app, and Longhorn
   volume CR comes back exactly as it was at backup time.
4. Reinstall the backup timer on the new master (`scripts/k0s-backup/README.md`).
5. Check: `kubectl get nodes`, `kubectl -n argocd get applications`. Anything created after the
   backup (≤24h) is re-synced from git by Argo. Only out-of-band changes from that window are lost.

## Scenario B: everything is gone. A few hours

Don't use the k0s backup here. It would resurrect Longhorn objects pointing at disks
that no longer exist. Build fresh and pull state from git + Longhorn backups.

### 1. VMs + node prep
```bash
cd terraform && terraform apply
```
Terraform/k0sctl do **not** do these. Run on every Ubuntu worker (`ubuntu@<ip>`, key `~/.ssh/id_rsa`):
```bash
# inotify (media apps crash at the default 128)
echo -e 'fs.inotify.max_user_instances=512\nfs.inotify.max_user_watches=524288' | sudo tee -a /etc/sysctl.conf && sudo sysctl -p
# multipathd steals Longhorn block devices
echo 'blacklist { devnode "^sd[a-z0-9]+" }' | sudo tee -a /etc/multipath.conf && sudo systemctl restart multipathd
```
aether worker: Vega iGPU passthrough (`hostpci0`) for Jellyfin VAAPI. If it hangs at boot after an
unclean shutdown, boot once without `hostpci0`.

### 2. k0s
```bash
k0sctl apply --config terraform/k0sctl.yaml
k0sctl kubeconfig --config terraform/k0sctl.yaml > ~/.kube/config
```
ousia (GPU worker on furina) isn't in k0sctl.yaml. Join it by hand with a worker token
(`k0s token create --role=worker` on the master). On Arch/Debian GPU nodes, check `/etc/os-release` has
`VERSION_ID` or the GPU operator does nothing (see the GPU operator os-release notes).
Then install the backup timer on the master (`scripts/k0s-backup/README.md`).

### 3. Argo CD (hand-installed, not in git)
```bash
kubectl create ns argocd
kubectl apply -n argocd --server-side --force-conflicts \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/v3.6.1/manifests/install.yaml
```
Use the version in the Argo upgrade notes if it has moved on.

### 4. Secrets
```bash
export SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt
for f in kubernetes/secrets/*.sops.yaml; do
  ns=$(yq '.metadata.namespace' "$f"); kubectl create ns "$ns" --dry-run=client -o yaml | kubectl apply -f -
  sops -d "$f" | kubectl apply -f -
done
# the key itself, for future KSOPS wiring
kubectl -n argocd create secret generic sops-age --from-file=keys.txt="$SOPS_AGE_KEY_FILE"
```

### 5. Longhorn first, then restore data *before* the apps exist
Restoring before Argo creates the apps means each app comes up on its old PVC instead of an
empty one. This avoids the Argo self-heal race described in the Longhorn volume-restore notes.
```bash
kubectl apply -f kubernetes/infrastructure/longhorn-app.yaml   # backup target is in its values
```
Wait for Longhorn to be healthy (`kubectl -n longhorn-system get pods`). Then in the Longhorn UI (`longhorn.local`
won't route yet, so `kubectl -n longhorn-system port-forward svc/longhorn-frontend 8080:80`):
1. **Backup** tab → select the volumes you want back (skip ones whose app no longer exists in the
   repo) → **Restore Latest Backup** → tick **Use Previous Name**.
2. Wait for the restores to finish (volumes go `detached`).
3. **Volume** tab → select them → **Create PV/PVC** → tick **Use Previous PVC**.
   Create the target namespaces first; the backup's labels show `namespace/pvcName`.

### 6. Everything else
```bash
kubectl apply -f kubernetes/infrastructure/project-bootstrap.yaml
```
Argo creates all apps, finds the restored PVCs by name, and adopts the Longhorn Application.
Watch `kubectl -n argocd get applications` until it's all Synced/Healthy. Check that
`argocd-cmd-params-cm` has `server.insecure: "true"`, then `rollout restart deploy/argocd-server`.

### 7. Check
- Media apps open and see the NAS libraries; qBittorrent's gluetun tunnel passes traffic.
- `kubectl -n longhorn-system get volumes.longhorn.io`: all healthy (2 replicas = 2 storage nodes).
- Longhorn recurring `daily-backup` runs that night; the k0s backup timer shows a next run.

---

## Scenario C: one worker dead
Covered by the node-death and Longhorn dead-node cleanup notes. Short version: rebuild the VM
with Terraform, `k0sctl apply`, apply the node prep from B.1, delete the dead Longhorn node object,
and let Longhorn re-replicate. Restore from backup only if a volume had its only replica there.

## What is deliberately *not* backed up
- **VM images** (no PBS / vzdump of k8s VMs): cattle, rebuilt by Terraform.
- **Loki logs / Tempo traces**: 30d of observability data on Longhorn PVCs, rebuildable.
- CKA practice VMs (401–403), templates (9000/9102): rebuilt from cloud images.
- Home Assistant (VM 301): last weekly vzdump on the Synology `dump/` share is the archive copy.
