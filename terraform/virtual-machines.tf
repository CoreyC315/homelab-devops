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

  # Updated CPU block per documentation
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
}

################################################################################
# AETHER NODE (.100) - 1 Worker 1 trueNAS
################################################################################

resource "proxmox_vm_qemu" "k3s_worker_aether" {
  # provider = proxmox.aether  <-- REMOVED: The cluster now uses the default provider
  count = 1

  # vmid must be unique; count.index ensures 112 and 113
  vmid = 112 + count.index

  # name must be unique; results in k3s-worker-aether-0 and k3s-worker-aether-1
  name = "k3s-worker-aether-${count.index}"

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

  # IP must be unique; results in .212 and .213
  ipconfig0 = "ip=192.168.1.${212 + count.index}/24,gw=192.168.1.254"
  sshkeys   = var.ssh_key
  ciuser    = "ubuntu"
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

    # Added existing TrueNAS VirtIO disks here
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

  # Prevents Terraform from attempting to recreate or modify disks on future applies
  lifecycle {
    ignore_changes = [disks]
  }
}
################################################################################
# NAHIDA NODE (.104) - Home Assistant
################################################################################

resource "proxmox_vm_qemu" "home_assistant" {
  vmid        = 101
  name        = "home-assistant"
  target_node = "nahida"
  clone       = "ubuntu-cloud-template-v2-nahida"
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

  ipconfig0 = "ip=192.168.1.221/24,gw=192.168.1.254"
  sshkeys   = var.ssh_key
  ciuser    = "ubuntu"
}
