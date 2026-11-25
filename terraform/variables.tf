variable "hm_token" {
  description = "Hostman API token."
  type        = string
  sensitive   = true
}

variable "cloudflare_api_token" {
  description = "Cloudflare API token with Zone:DNS:Edit and Zone:Zone:Read on parent_zone. Used by cert-manager, external-dns and k8gb."
  type        = string
  sensitive   = true
}

variable "location" {
  description = "Hostman location for the VPC, the clusters and the DNS fronts."
  type        = string
  default     = "de-1"
}

variable "vpc_subnet" {
  type    = string
  default = "10.50.0.0/16"
}

variable "kubernetes_version" {
  description = "Exact Hostman Kubernetes version, including its +k0s.N suffix."
  type        = string
  default     = "v1.37.2+k0s.1"
}

variable "clusters" {
  description = "The two site clusters, by name. geo_tag identifies each one to k8gb; message and color are what the phone page shows. min_replicas is what podinfo keeps while the other cluster is healthy (the pilot light), failover_replicas what it scales to when the other one fails."
  type = map(object({
    geo_tag           = string
    message           = string
    color             = string
    min_replicas      = optional(number, 1)
    failover_replicas = optional(number, 6)
    worker_cpu        = optional(number, 2)
    worker_ram_gb     = optional(number, 4)
  }))

  validation {
    condition     = length(var.clusters) == 2
    error_message = "The demo has exactly two site clusters: each one's failover floor watches the other."
  }
}

variable "control" {
  description = "The control cluster: Prometheus and Grafana to watch the failover, Chaos Mesh to cause it."
  type = object({
    name          = optional(string, "control")
    worker_cpu    = optional(number, 2)
    worker_ram_gb = optional(number, 4)
  })
  default = {}
}

variable "primary_geo_tag" {
  description = "The cluster that serves the site while it is healthy (failover strategy)."
  type        = string
}

variable "parent_zone" {
  description = "Cloudflare zone that holds every name, for example example.com."
  type        = string
}

variable "cloudflare_zone_id" {
  description = "ID of parent_zone in Cloudflare (zone Overview page). external-dns needs it because each cluster's domain is a subdomain of the zone."
  type        = string
}

variable "site_host" {
  description = "The address people open, for example kcd.example.com."
  type        = string
}

variable "acme_email" {
  description = "Contact address for Let's Encrypt."
  type        = string
}

variable "git_url" {
  description = "Public Git repository Flux syncs (this repository or a fork)."
  type        = string
}

variable "git_branch" {
  type    = string
  default = "main"
}

variable "second_apply" {
  description = "Wire the clusters together: a dnsdist DNS front per site cluster, metrics and the failover floor to the control cluster, and Chaos Mesh's access to the site clusters. Set to true once every Gateway has a load balancer IP and Flux has finished on all three clusters."
  type        = bool
  default     = false
}
