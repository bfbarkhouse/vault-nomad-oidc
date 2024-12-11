terraform {
  required_providers {
    vault = {
      source  = "hashicorp/vault"
      version = "4.5.0"
    }
    nomad = {
      source  = "hashicorp/nomad"
      version = "2.4.0"
    }
  }
}

provider "vault" {
  # Configuration options
}