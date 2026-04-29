################################################################################
# RAIDEN NODE (.101) - 1 Worker
################################################################################

resource "proxmox_vm_qemu" "k3s_master" {
  vmid        = 201
  name        = "k3s-master-1"
  target_node = "aether"
  clone       = "ubuntu-cloud-template-v2"
  agent       = 1
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
    ignore_changes = [tags, bootdisk]
  }
}

resource "proxmox_vm_qemu" "k3s_worker_raiden" {
  vmid        = 211
  name        = "k3s-worker-1"
  target_node = "raiden"
  clone       = "ubuntu-cloud-template-v2-raiden"
  agent       = 1
  os_type     = "cloud-init"

  scsihw   = "virtio-scsi-pci"
  bootdisk = "scsi0"

  cpu {
    cores   = 4
    sockets = 1
    type    = "host"
  }
  memory = 10240

  disks {
    scsi {
      scsi0 {
        disk {
          storage = "local-lvm"
          size    = "40G"
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
    ignore_changes = [tags, bootdisk]
  }
}

################################################################################
# AETHER NODE (.100) - 1 Master (moved from Raiden) + 1 Worker
################################################################################

resource "proxmox_vm_qemu" "k3s_worker_aether" {
  count = 1
  vmid  = 112 + count.index
  name  = "k3s-worker-aether-${count.index}"

  target_node = "aether"
  clone       = "ubuntu-cloud-template-v2"
  agent       = 1
  os_type     = "cloud-init"

  scsihw   = "virtio-scsi-pci"
  bootdisk = "scsi0"

  cpu {
    cores   = 4
    sockets = 1
    type    = "host"
  }
  memory = 10000

  disks {
    scsi {
      scsi0 {
        disk {
          storage = "local-lvm"
          size    = "60G"
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
    ignore_changes = [tags, bootdisk]
  }
}


################################################################################
# NAHIDA NODE (.104) - k0s worker + Home Assistant + OpenClaw + PBS
################################################################################

resource "proxmox_vm_qemu" "nahida-worker" {
  vmid        = 303
  name        = "nahida-worker"
  target_node = "nahida"
  clone       = "ubuntu-cloud-template-v2-nahida"
  agent       = 1
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
          size    = "64G"
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
    ignore_changes = [tags, bootdisk]
  }
}

resource "proxmox_vm_qemu" "proxmox-backup-server" {
  vmid        = 304
  name        = "proxmox-backup-server"
  target_node = "nahida"
  agent       = 1
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

resource "proxmox_vm_qemu" "openclaw" {
  vmid        = 302
  name        = "openclaw"
  target_node = "nahida"
  clone       = "ubuntu-cloud-template-v2-nahida"
  agent       = 1
  os_type     = "cloud-init"

  scsihw   = "virtio-scsi-pci"
  bootdisk = "scsi0"

  cpu {
    cores   = 4
    sockets = 1
    type    = "host"
  }
  memory = 8192

  disks {
    scsi {
      scsi0 {
        disk {
          storage = "local-lvm"
          size    = "128G"
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

  ipconfig0 = "ip=192.168.1.214/24,gw=192.168.1.254"
  sshkeys   = var.ssh_key
  ciuser    = "ubuntu"

  lifecycle {
    ignore_changes = [tags, bootdisk]
  }
}
