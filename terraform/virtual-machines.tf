################################################################################
# RAIDEN NODE (.101) - Master + 1 Worker
################################################################################

resource "proxmox_vm_qemu" "k3s_master" {
  name        = "k3s-master-1"
  target_node = "raiden"
  clone       = "ubuntu-cloud-template-v2"
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
    id    = 0
    model = "virtio"
    bridge = "vmbr0"
  }

  ipconfig0 = "ip=192.168.1.201/24,gw=192.168.1.254"
  sshkeys   = var.ssh_key
  ciuser    = "ubuntu"
}

resource "proxmox_vm_qemu" "k3s_worker_raiden" {
  name        = "k3s-worker-1"
  target_node = "raiden"
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
    id    = 0
    model = "virtio"
    bridge = "vmbr0"
  }

  ipconfig0 = "ip=192.168.1.211/24,gw=192.168.1.254"
  sshkeys   = var.ssh_key
  ciuser    = "ubuntu"
}

################################################################################
# AETHER NODE (.100) - 2 Workers
################################################################################

resource "proxmox_vm_qemu" "k3s_worker_aether" {
  provider    = proxmox.aether
  count       = 2
  name        = "k3s-worker-aether-${count.index + 1}"
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
  memory = 12288

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
      ide2{
        cloudinit{
          storage = "local-lvm"
        }
      }
    }
  }

  network {
    id    = 0
    model = "virtio"
    bridge = "vmbr0"
  }

  ipconfig0 = "ip=192.168.1.${212 + count.index}/24,gw=192.168.1.254"
  sshkeys   = var.ssh_key
  ciuser    = "ubuntu"
}