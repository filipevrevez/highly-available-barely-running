locals {
  site_label = split(".", var.site_host)[0]
  gslb_zone  = "gslb.${var.parent_zone}"

  control_name = var.control.name
  all_clusters = merge(
    { for name, c in var.clusters : name => { role = "site", worker_cpu = c.worker_cpu, worker_ram_gb = c.worker_ram_gb } },
    { (local.control_name) = { role = "control", worker_cpu = var.control.worker_cpu, worker_ram_gb = var.control.worker_ram_gb } },
  )
  primary = one([for name, c in var.clusters : name if c.geo_tag == var.primary_geo_tag])
  standby = one([for name, c in var.clusters : name if c.geo_tag != var.primary_geo_tag])

  # Shared by every cluster: gitops/infrastructure and gitops/config.
  common_vars = {
    for name in keys(local.all_clusters) : name => {
      CLUSTER_NAME   = name
      PARENT_ZONE    = var.parent_zone
      CLUSTER_DOMAIN = "${name}.${var.parent_zone}"
      SITE_HOST      = var.site_host
      ACME_EMAIL     = var.acme_email
      DNS_ZONE_ID    = var.cloudflare_zone_id
    }
  }

  # Everything Flux substitutes in gitops/ for one cluster (Kustomizations use substituteFrom).
  cluster_vars = merge(
    {
      for name, c in var.clusters : name => merge(local.common_vars[name], {
        GEO_TAG           = c.geo_tag
        PEER_GEO_TAGS     = join(",", [for other, o in var.clusters : o.geo_tag if other != name])
        PRIMARY_GEO_TAG   = var.primary_geo_tag
        GSLB_ZONE         = local.gslb_zone
        GSLB_HOST         = "${local.site_label}.${local.gslb_zone}"
        CLUSTER_HOST      = "${local.site_label}.${name}.${var.parent_zone}"
        APP_MESSAGE       = c.message
        APP_COLOR         = trimprefix(c.color, "#")
        APP_REPLICAS      = tostring(c.min_replicas)
        APP_MIN_REPLICAS  = tostring(c.min_replicas)
        FAILOVER_REPLICAS = tostring(c.failover_replicas)
        PEER_CLUSTER      = one([for other in keys(var.clusters) : other if other != name])
        PODINFO_METRICS   = "true"
      })
    },
    {
      (local.control_name) = merge(local.common_vars[local.control_name], {
        GRAFANA_HOST    = "grafana.${local.control_name}.${var.parent_zone}"
        CHAOS_HOST      = "chaos.${local.control_name}.${var.parent_zone}"
        PRIMARY_CLUSTER = local.primary
        PRIMARY_URL     = "https://${local.site_label}.${local.primary}.${var.parent_zone}/api/info"
        STANDBY_CLUSTER = local.standby
        STANDBY_URL     = "https://${local.site_label}.${local.standby}.${var.parent_zone}/api/info"
      })
    },
  )
}

# Flux Operator and a FluxInstance syncing this repository: gitops/cluster on the site clusters,
# gitops/control-cluster on the control cluster.
module "flux" {
  source   = "controlplaneio-fluxcd/flux-operator-bootstrap/kubernetes"
  version  = "0.10.0"
  for_each = local.all_clusters

  providers = {
    kubernetes = kubernetes.clusters[each.key]
    helm       = helm.clusters[each.key]
  }
  depends_on       = [hm_k8s_node_group.workers]
  revision         = 1
  timeout          = "10m"
  debug_on_failure = false
  # Chart downloads must not depend on cluster DNS while the CNI starts.
  job = { host_network = true }

  gitops_resources = {
    operator_chart = { version = "0.62.1" }
    instance_yaml = yamlencode({
      apiVersion = "fluxcd.controlplane.io/v1"
      kind       = "FluxInstance"
      metadata   = { name = "flux", namespace = "flux-system" }
      spec = {
        distribution = { version = "2.10.0", registry = "ghcr.io/fluxcd" }
        components   = ["source-controller", "kustomize-controller", "helm-controller", "notification-controller"]
        cluster      = { type = "kubernetes", networkPolicy = true, multitenant = false, domain = "cluster.local" }
        sync = {
          name = "flux-system"
          kind = "GitRepository"
          url  = var.git_url
          ref  = "refs/heads/${var.git_branch}"
          path = each.value.role == "control" ? "gitops/control-cluster" : "gitops/cluster"
        }
      }
    })
  }
}

resource "kubernetes_config_map_v1" "cluster_vars" {
  for_each = local.all_clusters
  provider = kubernetes.clusters[each.key]

  metadata {
    name      = "cluster-vars"
    namespace = "flux-system"
  }
  data       = local.cluster_vars[each.key]
  depends_on = [module.flux]
}

# The Cloudflare token, where cert-manager, external-dns and (site clusters) k8gb read it.
resource "kubernetes_namespace_v1" "dns" {
  for_each = merge([
    for name, c in local.all_clusters : {
      for ns in(c.role == "site" ? ["cert-manager", "external-dns", "k8gb"] : ["cert-manager", "external-dns"]) :
      "${name}/${ns}" => { cluster = name, namespace = ns }
    }
  ]...)
  provider = kubernetes.clusters[each.value.cluster]

  metadata {
    name = each.value.namespace
  }
  depends_on = [hm_k8s_node_group.workers]
}

resource "kubernetes_secret_v1" "cloudflare" {
  for_each = kubernetes_namespace_v1.dns
  provider = kubernetes.clusters[split("/", each.key)[0]]

  metadata {
    name      = "cloudflare-api-token"
    namespace = each.value.metadata[0].name
  }
  data = { token = var.cloudflare_api_token }
}

# Hostman installs Cilium (a Helm release) with Gateway API off. Turn it on once, keeping Hostman's
# values, after Flux has installed the Gateway API CRDs; the operator only registers them at start.
resource "kubernetes_service_account_v1" "cilium_gateway" {
  for_each = local.all_clusters
  provider = kubernetes.clusters[each.key]

  metadata {
    name      = "cilium-gateway-api"
    namespace = "kube-system"
  }
  depends_on = [hm_k8s_node_group.workers]
}

resource "kubernetes_cluster_role_binding_v1" "cilium_gateway" {
  for_each = local.all_clusters
  provider = kubernetes.clusters[each.key]

  metadata {
    name = "cilium-gateway-api"
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = "cluster-admin"
  }
  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account_v1.cilium_gateway[each.key].metadata[0].name
    namespace = "kube-system"
  }
}

resource "kubernetes_job_v1" "cilium_gateway" {
  for_each = local.all_clusters
  provider = kubernetes.clusters[each.key]

  metadata {
    name      = "cilium-gateway-api"
    namespace = "kube-system"
  }
  spec {
    backoff_limit              = 3
    active_deadline_seconds    = 1800
    ttl_seconds_after_finished = 86400
    template {
      metadata {}
      spec {
        service_account_name = kubernetes_service_account_v1.cilium_gateway[each.key].metadata[0].name
        restart_policy       = "OnFailure"
        host_network         = true
        container {
          name    = "enable"
          image   = "alpine/k8s:1.32.3"
          command = ["sh", "-ec", file("${path.module}/templates/cilium-gateway-api.sh")]
        }
      }
    }
  }
  wait_for_completion = true
  timeouts {
    create = "30m"
  }
  depends_on = [kubernetes_cluster_role_binding_v1.cilium_gateway, module.flux]
}
