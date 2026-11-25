terraform {
  required_version = ">= 1.9" # OpenTofu: providers with for_each

  required_providers {
    hm = {
      source  = "registry.terraform.io/hostman-cloud/hostman"
      version = "0.0.2"
    }
    http = {
      source  = "hashicorp/http"
      version = "3.6.3"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "3.5.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "3.3.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.7"
    }
  }
}

provider "hm" {
  token = var.hm_token
}
