resource "proxmox_vm_qemu" "k3s_server" {
  count = 1
  name  = "k3s-server-${count.index + 1}"
  target_node = "pve-01"
  clone = "ubuntu-cloud-template"

  agent    = 1
  os_type  = "cloud-init"
  cores    = 2
  sockets  = 1
#  cpu      = "host"
  memory   = 4096
  scsihw   = "virtio-scsi-pci"
  bootdisk = "scsi0"

  disks {
    scsi {
      scsi0 {
        disk {
          storage = "local-lvm"
          size    = "20G"
        }
      }
    }
    # THIS IS THE MISSING PIECE
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

  ipconfig0 = "ip=192.168.1.20${count.index + 1}/24,gw=192.168.1.254"
  sshkeys   = var.ssh_key
  ciuser    = "ubuntu"
}

resource "proxmox_vm_qemu" "k3s_agent" {
  count = 2
  name  = "k3s-agent-${count.index + 1}"
  target_node = "pve-01"
  clone       = "ubuntu-cloud-template"

  agent    = 1
  os_type  = "cloud-init"
  cores    = 2
  sockets  = 1
#  cpu      = "host"
  memory   = 4096
  scsihw   = "virtio-scsi-pci"
  bootdisk = "scsi0"

  disks {
    scsi {
      scsi0 {
        disk {
          storage = "local-lvm"
          size    = "20G"
        }
      }
    }
    # THIS IS THE MISSING PIECE
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

  ipconfig0 = "ip=192.168.1.21${count.index + 1}/24,gw=192.168.1.254"
  sshkeys   = var.ssh_key
  ciuser    = "ubuntu"
}