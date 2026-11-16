#!/usr/bin/env bash
# Nightly k0s controller backup (etcd + PKI + k0s config) -> Synology.
# Replaces PBS VM-level backups of the master (VM 201). Restore:
#   k0sctl apply --config terraform/k0sctl.yaml --restore-from <k0s_backup_*.tar.gz>
# The archive contains every cluster Secret in plaintext: the NAS dir is root-only (0700).
set -euo pipefail

NAS="192.168.1.210:/volume1/backups"
MNT="/mnt/k0s-bk"
DEST="$MNT/k0s-controller"
KEEP=7
TMP="$(mktemp -d /var/tmp/k0s-backup.XXXXXX)"

cleanup() {
  rm -rf "$TMP"
  mountpoint -q "$MNT" && umount "$MNT" || true
}
trap cleanup EXIT

mkdir -p "$MNT"
# soft mount, mounted only for the duration of the run: a hung NAS must not wedge the master
mount -t nfs -o soft,timeo=100,retrans=2,vers=4.1 "$NAS" "$MNT"
mkdir -p "$DEST"
chmod 0700 "$DEST"

k0s backup --save-path "$TMP"
f="$(ls -1 "$TMP"/k0s_backup_*.tar.gz)"
cp "$f" "$DEST/"
chmod 0600 "$DEST/$(basename "$f")"

# retention: newest $KEEP archives
ls -1t "$DEST"/k0s_backup_*.tar.gz | tail -n +$((KEEP + 1)) | xargs -r rm -f

echo "k0s backup OK: $(basename "$f") ($(du -h "$DEST/$(basename "$f")" | cut -f1)); kept $(ls -1 "$DEST"/k0s_backup_*.tar.gz | wc -l)"
