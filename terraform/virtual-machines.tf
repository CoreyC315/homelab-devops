resource "proxmox_vm_qemu" "k3s_server" {
  count = 1
  name  = "k3s-server-1"
  target_node = "pve-01"
  clone = "ubuntu-cloud-template"

  agent    = 1
  os_type  = "cloud-init"
  
  # LIGHTWEIGHT MASTER
  cores    = 2
  sockets  = 1
  #cpu      = "host" 
  memory   = 2048   # 2GB RAM is plenty for just k3s control plane
  
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

  # Static IP for Server
  ipconfig0 = "ip=192.168.1.201/24,gw=192.168.1.254"
  sshkeys   = var.ssh_key
  ciuser    = "ubuntu"
}

resource "proxmox_vm_qemu" "k3s_agent" {
  count = 1
  name  = "k3s-agent-1"
  target_node = "pve-01"
  clone       = "ubuntu-cloud-template"

  agent    = 1
  os_type  = "cloud-init"

  # JUICED WORKER NODE
  cores    = 4      # Give it more CPU power
  sockets  = 1
  #cpu      = "host" # Passes host CPU flags for better performance
  memory   = 10240  # 10GB RAM (Leaves 4GB for Proxmox + 2GB for Server)
  
  scsihw   = "virtio-scsi-pci"
  bootdisk = "scsi0"

  disks {
    scsi {
      scsi0 {
        disk {
          storage = "local-lvm"
          size    = "40G" # Bumped disk size for apps/logs
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

  # Static IP for Agent
  ipconfig0 = "ip=192.168.1.211/24,gw=192.168.1.254"
  sshkeys   = var.ssh_key
  ciuser    = "ubuntu"
}