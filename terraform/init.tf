terraform {
  required_providers {
    proxmox = {
      source  = "telmate/proxmox"
      version = "3.0.2-rc04"
    }
  }
}

# Provider for Raiden (.101)
provider "proxmox" {
  pm_api_url          = "https://192.168.1.101:8006/api2/json"
  pm_api_token_id     = var.proxmox_api_token_id_raiden
  pm_api_token_secret = var.proxmox_api_token_secret_raiden
  pm_tls_insecure     = true
}

# Provider for Aether (.100)
provider "proxmox" {
  alias               = "aether"
  pm_api_url          = "https://192.168.1.100:8006/api2/json"
  pm_api_token_id     = var.proxmox_api_token_id_aether
  pm_api_token_secret = var.proxmox_api_token_secret_aether
  pm_tls_insecure     = true
}

# Variable Definitions
variable "proxmox_api_token_id_raiden" { type = string }
variable "proxmox_api_token_secret_raiden" { 
  type      = string 
  sensitive = true 
}

variable "proxmox_api_token_id_aether" { type = string }
variable "proxmox_api_token_secret_aether" { 
  type      = string 
  sensitive = true 
}

variable "ssh_key" { type = string }