################################################################################
# RAIDEN NODE (.101) - Master + 1 Worker
################################################################################

resource "proxmox_vm_qemu" "k3s_master" {
  vmid        = 201
  name        = "k3s-master-1"
  target_node = "raiden"
  clone       = "ubuntu-cloud-template-v2-raiden"
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
# AETHER NODE (.100) - 1 Worker 1 trueNAS
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

resource "proxmox_vm_qemu" "truenas" {
  name        = "truenas-scale"
  target_node = "aether"
  agent       = 1
  memory      = 16384

  cpu {
    cores   = 2
    sockets = 1
    type    = "host"
  }

  network {
    id     = 0
    model  = "virtio"
    bridge = "vmbr0"
  }

  disks {
    ide {
      ide2 {
        cdrom {
          iso = "local:iso/TrueNAS-SCALE-24.04.2.iso"
        }
      }
    }
    scsi {
      scsi0 {
        disk {
          size    = "32G"
          storage = "local-lvm"
          format  = "raw"
        }
      }
    }
    virtio {
      virtio1 {
        disk {
          size     = "32G"
          storage  = "local-lvm"
          format   = "raw"
          iothread = true
        }
      }
      virtio2 {
        disk {
          size     = "32G"
          storage  = "local-lvm"
          format   = "raw"
          iothread = true
        }
      }
    }
  }

  boot = "order=ide2;scsi0"

  lifecycle {
    ignore_changes = [disks, tags, bootdisk]
  }
}

################################################################################
# NAHIDA NODE (.104) - k0s worker & AI
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