# Hostman load balancers carry no UDP, and resolvers query a delegated zone over UDP. Each site
# cluster gets a small server running dnsdist on public 53/UDP+TCP. It forwards only the k8gb zone,
# over TCP, to port 53 on that cluster's Gateway load balancer, where a TCPRoute reaches k8gb's
# CoreDNS. Each k8gb publishes its own front as its nameserver, so either cluster can answer alone.
# Second apply (second_apply = true): the Gateways need their load balancer IPs first.
locals {
  site_clusters_wired = var.second_apply ? var.clusters : {}
}

data "kubernetes_service_v1" "gateway" {
  for_each = local.site_clusters_wired
  provider = kubernetes.clusters[each.key]

  metadata {
    name      = "cilium-gateway-public"
    namespace = "gateway-system"
  }

  lifecycle {
    postcondition {
      condition     = try(self.status[0].load_balancer[0].ingress[0].ip, "") != ""
      error_message = "The public Gateway has no load balancer IP yet: wait for Flux and Hostman, then apply again."
    }
  }
}

data "hm_os" "dns_front" {
  count = var.second_apply ? 1 : 0

  name    = "ubuntu"
  version = "24.04"
}

data "hm_presets" "dns_front" {
  count = var.second_apply ? 1 : 0

  location = var.location
  cpu      = 2
  ram      = 2048
}

resource "hm_server" "dns_front" {
  for_each = local.site_clusters_wired

  name      = "gslb-dns-${each.key}"
  os_id     = data.hm_os.dns_front[0].id
  preset_id = data.hm_presets.dns_front[0].id
  cloud_init = templatefile("${path.module}/templates/dnsdist-cloud-init.yaml.tftpl", {
    zone    = local.gslb_zone
    name    = each.key
    address = data.kubernetes_service_v1.gateway[each.key].status[0].load_balancer[0].ingress[0].ip
  })
}

# The public IPv4 that this cluster's k8gb publishes as its nameserver (glue record).
resource "hm_server_ip" "dns_front" {
  for_each = local.site_clusters_wired

  source_server_id = hm_server.dns_front[each.key].id
  type             = "ipv4"
}

# k8gb, the agent, the site and the failover floor wait for this (substituteFrom, not optional).
resource "kubernetes_config_map_v1" "gslb_vars" {
  for_each = local.site_clusters_wired
  provider = kubernetes.clusters[each.key]

  metadata {
    name      = "gslb-vars"
    namespace = "flux-system"
  }
  data = {
    GSLB_DNS_IP = hm_server_ip.dns_front[each.key].ip
    GATEWAY_IP  = data.kubernetes_service_v1.gateway[each.key].status[0].load_balancer[0].ingress[0].ip
    # The control cluster's Prometheus, over the private network (control.tf).
    METRICS_REMOTE_WRITE_URL = "http://${local.control_private_ip}:30090/api/v1/write"
    PROMETHEUS_URL           = "http://${local.control_private_ip}:30090"
  }
}
