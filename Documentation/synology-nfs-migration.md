# Synology NFS Migration

This runbook moves existing RWX media claims from the old `truenas-nfs`
backing volumes to the active `celestia-nfs` StorageClass on Synology
`Celestia` (`192.168.1.210`).

## Synology NFS rule

Create NFS permissions on the `media` shared folder for the worker nodes.

The safest option is one rule per worker:

- `192.168.1.211`
- `192.168.1.212`
- `192.168.1.213`

If DSM accepts CIDR notation and you trust the whole LAN, use one broader
rule with `192.168.1.0/24`.

Use these values in the NFS rule form:

- `Privilege`: `Read/Write`
- `Squash`: `No mapping`
- `Security`: `sys`
- `Enable asynchronous`: enabled
- `Allow connections from non-privileged ports`: enabled
- `Allow users to access mounted subfolders`: disabled
- `Cross-mount`: disabled

The StorageClass points at:

- Server: `192.168.1.210`
- Share: `/volume1/media`

## Why the old PVCs did not switch

Bound PVCs keep the StorageClass they were created with. Changing the
manifest later does not migrate the existing volume.

Live cluster state before migration:

- `irminsul-records-pvc` -> bound to `truenas-nfs`
- `suwayomi-manga-pvc` -> bound to `truenas-nfs`
- `celestia-nfs` exists and the NFS CSI driver is healthy

## Migration order

1. Scale down apps that write to the shared claim:
   - `jellyfin`
   - `qbittorrent`
   - `prowlarr`
   - `radarr`
   - `sonarr`
   - `suwayomi`
2. Apply [migration.yaml](/Users/ccampbell/dev/homelab-devops/kubernetes/manual/synology-nfs/migration.yaml).
3. Wait for the new PVCs to bind.
4. Run the copy jobs and watch their logs.
5. Verify files exist on the new claims.
6. Update deployments to reference the new claim names:
   - `irminsul-records-celestia-pvc`
   - `suwayomi-manga-celestia-pvc`
7. Scale apps back up and verify playback/download/import behavior.
8. Delete the old PVCs only after validation.

## Useful commands

```bash
kubectl get pvc -n default
kubectl get jobs -n default
kubectl logs -n default job/irminsul-records-copy -f
kubectl logs -n default job/suwayomi-manga-copy -f
```
