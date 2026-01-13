terraform {
  required_providers {
    proxmox = {
      source  = "telmate/proxmox"
      version = "3.0.2-rc04"
    }
  }
}

# Single Provider for the Cluster
# You can point this to either .100 or .101; the cluster handles the rest.
provider "proxmox" {
  pm_api_url          = "https://192.168.1.100:8006/api2/json"
  pm_api_token_id     = var.proxmox_api_token_id
  pm_api_token_secret = var.proxmox_api_token_secret
  pm_tls_insecure     = true
}

# Simplified Variables
variable "proxmox_api_token_id" { 
  type    = string 
  default = "terraform-prov@pve!terraform-token"
}

variable "proxmox_api_token_secret" { 
  type      = string 
  sensitive = true 
}

variable "ssh_key" { type = string }