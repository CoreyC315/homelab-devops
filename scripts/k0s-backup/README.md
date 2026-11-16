# k0s controller backup

Nightly `k0s backup` of the controller (VM 201) to `192.168.1.210:/volume1/backups/k0s-controller/`
(keep 7). Replaces PBS backups of the master. See `Documentation/disaster-recovery.md`.

Install on a (re)built controller:
```bash
scp k0s-backup-to-nas.sh k0s-backup.service k0s-backup.timer ubuntu@192.168.1.201:/tmp/
ssh ubuntu@192.168.1.201 'sudo install -m 0750 /tmp/k0s-backup-to-nas.sh /usr/local/sbin/ &&
  sudo install -m 0644 /tmp/k0s-backup.{service,timer} /etc/systemd/system/ &&
  sudo systemctl daemon-reload && sudo systemctl enable --now k0s-backup.timer'
```
Run now: `sudo systemctl start k0s-backup.service && journalctl -u k0s-backup.service -n 5`
