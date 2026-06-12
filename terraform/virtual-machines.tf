# Proxmox VM definitions for the Teyvat k0s cluster.
#
# Topology (post raiden recovery, 2026-06-12):
#   aether (.100) : k0s_master (201) + k0s-worker-aether (112)
#   raiden (.101) : raiden-worker (211)   <- big worker, master no longer lives here
#   nahida (.104) : nahida-worker (303) + PBS (304) + home-assistant (301)
#
# The control-plane master (VM 201) was restored onto aether from PBS after
# raiden died; it stays on aether. Every VM sets onboot=true so the cluster
# self-recovers after a host power-cycle (a missing onboot is what made the
# raiden outage look like a total loss).

################################################################################
# AETHER NODE (.100) - control-plane master + 1 worker
################################################################################

resource "proxmox_vm_qemu" "k0s_master" {
  vmid        = 201
  name        = "k0s-master-1"
  target_node = "aether" # restored here from PBS 2026-06-12; do not move back to raiden
  clone       = "ubuntu-cloud-template-v2-raiden"
  agent       = 1
  onboot      = true
  os_type     = "cloud-init"

  scsihw   = "virtio-scsi-pci"
  bootdisk = "scsi0"

  cpu {
    cores   = 2
    sockets = 1
    type    = "host"
  }
  memory = 2048

  disks {
    scsi {
      scsi0 {
        disk {
          storage = "local-lvm"
          size    = "20G"
        }
      }
    }
    ide {
      ide2 {
        cloudinit {
          storage = "local-lvm"
        }
      }
    }
  }

  network {
    id     = 0
    model  = "virtio"
    bridge = "vmbr0"
  }

  ipconfig0 = "ip=192.168.1.201/24,gw=192.168.1.254"
  sshkeys   = var.ssh_key
  ciuser    = "ubuntu"

  lifecycle {
    # clone/full_clone drift because the live VM was rebuilt out-of-band (PBS
    # restore), not cloned by Terraform. prevent_destroy guards the control plane.
    ignore_changes  = [tags, bootdisk, name, clone, full_clone]
    prevent_destroy = true
  }
}

resource "proxmox_vm_qemu" "k0s_worker_aether" {
  count = 1
  vmid  = 112 + count.index
  name  = "k0s-worker-aether-${count.index}"

  target_node = "aether"
  clone       = "ubuntu-cloud-template-v2"
  agent       = 1
  onboot      = true
  os_type     = "cloud-init"

  scsihw   = "virtio-scsi-pci"
  bootdisk = "scsi0"

  cpu {
    cores   = 8
    sockets = 1
    type    = "host"
  }
  memory = 16384

  disks {
    scsi {
      scsi0 {
        disk {
          storage = "local-lvm"
          size    = "200G" # grown from 100G online (qm resize + growpart/resize2fs) to relieve disk pressure
        }
      }
    }
    ide {
      ide2 {
        cloudinit {
          storage = "local-lvm"
        }
      }
    }
  }

  network {
    id     = 0
    model  = "virtio"
    bridge = "vmbr0"
  }

  ipconfig0 = "ip=192.168.1.${212 + count.index}/24,gw=192.168.1.254"
  sshkeys   = var.ssh_key
  ciuser    = "ubuntu"

  lifecycle {
    # hostpci + machine are managed out-of-band on Proxmox (AMD Vega iGPU
    # passthrough for Jellyfin VAAPI: `qm set 112 -machine q35 -hostpci0
    # 0000:04:00.0,pcie=1`). The Telmate provider is destructive with these
    # fields, so we ignore drift here rather than let it recreate the VM.
    ignore_changes = [bootdisk, machine, hostpci, tags]
  }
}

################################################################################
# RAIDEN NODE (.101) - 1 big worker (master no longer here)
################################################################################

resource "proxmox_vm_qemu" "k0s_worker_raiden" {
  vmid        = 211
  name        = "raiden-worker"
  target_node = "raiden"
  clone       = "ubuntu-cloud-template-v2-raiden"
  agent       = 1
  onboot      = true
  os_type     = "cloud-init"

  scsihw   = "virtio-scsi-pci"
  bootdisk = "scsi0"

  # Sized big now that the master moved off raiden: i7-4770 (4c/8t), 16 GiB RAM.
  # 6 vCPU + 12 GiB leaves ~2 threads / ~4 GiB for the PVE host.
  cpu {
    cores   = 6
    sockets = 1
    type    = "host"
  }
  memory = 12288

  disks {
    scsi {
      scsi0 {
        disk {
          storage = "local-lvm"
          size    = "250G"
        }
      }
    }
    ide {
      ide2 {
        cloudinit {
          storage = "local-lvm"
        }
      }
    }
  }

  network {
    id     = 0
    model  = "virtio"
    bridge = "vmbr0"
  }

  ipconfig0 = "ip=192.168.1.211/24,gw=192.168.1.254"
  sshkeys   = var.ssh_key
  ciuser    = "ubuntu"

  lifecycle {
    ignore_changes = [tags, bootdisk, name]
  }
}

################################################################################
# NAHIDA NODE (.104) - k0s worker + PBS + Home Assistant
################################################################################

resource "proxmox_vm_qemu" "nahida-worker" {
  vmid        = 303
  name        = "nahida-worker"
  target_node = "nahida"
  clone       = "ubuntu-cloud-template-v2-nahida"
  agent       = 1
  onboot      = true
  os_type     = "cloud-init"

  scsihw   = "virtio-scsi-pci"
  bootdisk = "scsi0"

  cpu {
    cores   = 8
    sockets = 1
    type    = "host"
  }
  memory = 10240

  disks {
    scsi {
      scsi0 {
        disk {
          storage = "local-lvm"
          size    = "200G" # grown from 100G online (qm resize + growpart/resize2fs) 2026-06-12 to give Longhorn replicas room
        }
      }
    }
    ide {
      ide2 {
        cloudinit {
          storage = "local-lvm"
        }
      }
    }
  }

  network {
    id     = 0
    model  = "virtio"
    bridge = "vmbr0"
  }

  ipconfig0 = "ip=192.168.1.213/24,gw=192.168.1.254"
  sshkeys   = var.ssh_key
  ciuser    = "ubuntu"

  lifecycle {
    ignore_changes = [tags, bootdisk, name]
  }
}

resource "proxmox_vm_qemu" "proxmox-backup-server" {
  vmid        = 304
  name        = "proxmox-backup-server"
  target_node = "nahida"
  agent       = 1
  onboot      = true
  os_type     = "cloud-init"

  scsihw   = "virtio-scsi-pci"
  bootdisk = "scsi0"

  cpu {
    cores   = 2
    sockets = 1
    type    = "host"
  }
  memory = 4096

  disks {
    scsi {
      scsi0 {
        disk {
          storage = "local-lvm"
          size    = "64G"
        }
      }
      # Datastore disk for the PBS chunk store (datastore "local-backups",
      # mounted at /mnt/datastore/local-backups). Local-disk datastore chosen
      # over the Synology NFS path because the NAS "backups" shared folder has
      # Windows ACLs (admin-group only) that block PBS's backup uid (34).
      # backup=false: don't include the chunk store in PVE VM backups.
      scsi1 {
        disk {
          storage = "local-lvm"
          size    = "450G"
          backup  = false
        }
      }
    }
    ide {
      ide0 {
        cdrom {
          iso = "local:iso/proxmox-backup-server_4.1-1.iso"
        }
      }
    }
  }

  network {
    id     = 0
    model  = "virtio"
    bridge = "vmbr0"
  }

  ipconfig0 = "ip=192.168.1.105/24,gw=192.168.1.254"
  sshkeys   = var.ssh_key
  ciuser    = "ubuntu"

  lifecycle {
    ignore_changes = [tags, bootdisk]
  }
}

variable "haos_version" {
  type        = string
  default     = "14.2"
  description = "Home Assistant OS version to download and import"
}

resource "proxmox_vm_qemu" "home_assistant" {
  vmid        = 301
  name        = "home-assistant"
  target_node = "nahida"
  agent       = 1
  bios        = "ovmf"
  machine     = "q35"
  onboot      = true

  scsihw = "virtio-scsi-single"

  cpu {
    cores   = 2
    sockets = 1
    type    = "x86-64-v2-AES"
  }
  memory = 4096

  # Disk is managed by the haos_image null_resource below.
  # Terraform only owns the network; disks are ignored after initial import.
  disks {
    scsi {
      scsi0 {
        disk {
          storage  = "local-lvm"
          size     = "32G"
          discard  = true
          iothread = true
        }
      }
    }
  }

  network {
    id       = 0
    model    = "virtio"
    bridge   = "vmbr0"
    firewall = true
  }

  lifecycle {
    ignore_changes  = all
    prevent_destroy = true
  }
}

# Downloads the HAOS qcow2 image to the Proxmox node and imports it as the
# VM's boot disk. Re-runs only when haos_version changes.
resource "null_resource" "haos_image" {
  triggers = {
    haos_version = var.haos_version
    vmid         = proxmox_vm_qemu.home_assistant.vmid
  }

  connection {
    type        = "ssh"
    host        = "192.168.1.104"
    user        = "root"
    private_key = file("~/.ssh/id_rsa")
  }

  provisioner "remote-exec" {
    inline = [
      "set -e",
      "VMID=301",
      "VERSION=${var.haos_version}",
      "STORAGE=local-lvm",
      "IMAGE_DIR=/var/lib/vz/images/haos",
      "IMAGE_FILE=$IMAGE_DIR/haos_generic-x86-64-$VERSION.qcow2",
      "URL=https://github.com/home-assistant/operating-system/releases/download/$VERSION/haos_generic-x86-64-$VERSION.qcow2.xz",
      "if qm config $VMID 2>/dev/null | grep -q '^scsi0:'; then",
      "  echo \">>> Disk already attached to VMID $VMID, skipping import\"",
      "  exit 0",
      "fi",
      "mkdir -p $IMAGE_DIR",
      "if [ ! -f \"$IMAGE_FILE\" ]; then",
      "  echo \">>> Downloading HAOS $VERSION...\"",
      "  curl -fsSL -o \"$IMAGE_FILE.xz\" \"$URL\"",
      "  echo \">>> Decompressing...\"",
      "  xz -d \"$IMAGE_FILE.xz\"",
      "  echo \">>> Download complete\"",
      "else",
      "  echo \">>> Image already present: $IMAGE_FILE\"",
      "fi",
      "echo \">>> Removing placeholder disk (if any)...\"",
      "qm set $VMID --delete scsi0 2>/dev/null || true",
      "echo \">>> Importing HAOS disk into $STORAGE...\"",
      "qm importdisk $VMID \"$IMAGE_FILE\" $STORAGE --format raw",
      "echo \">>> Attaching imported disk (reads unused0 to avoid hardcoding disk number)...\"",
      "UNUSED=$(qm config $VMID | grep '^unused0:' | awk '{print $2}')",
      "qm set $VMID --scsi0 \"$UNUSED,discard=on,iothread=1\"",
      "qm set $VMID --boot order=scsi0",
      "echo \">>> HAOS $VERSION ready on VMID $VMID\"",
    ]
  }

  depends_on = [proxmox_vm_qemu.home_assistant]
}
