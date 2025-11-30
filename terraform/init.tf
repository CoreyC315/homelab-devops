terraform {
  required_providers {
    proxmox = {
      source  = "telmate/proxmox"
      version = "3.0.2-rc04"
    }
  }
}

provider "proxmox" {
  # Your Proxmox URL
  pm_api_url = "https://192.168.1.200:8006/api2/json"

  # We will put the actual secrets in credentials.auto.tfvars
  pm_api_token_id     = var.proxmox_api_token_id
  pm_api_token_secret = var.proxmox_api_token_secret

  # Ignore certificate errors for homelab
  pm_tls_insecure = true
}

variable "proxmox_api_token_id" {
  type = string
}

variable "proxmox_api_token_secret" {
  type = string
  sensitive = true
}

variable "ssh_key" {
  type = string
}