# The control cluster: Grafana's admin login, and (second apply) what connects it to the site clusters.

resource "random_password" "grafana" {
  length  = 32
  special = false
}

# gitops/control installs Prometheus and Grafana into this namespace; Grafana reads its login here.
resource "kubernetes_namespace_v1" "monitoring" {
  provider = kubernetes.clusters[local.control_name]

  metadata {
    name = "monitoring"
  }
  depends_on = [hm_k8s_node_group.workers]
}

resource "kubernetes_secret_v1" "grafana_admin" {
  provider = kubernetes.clusters[local.control_name]

  metadata {
    name      = "grafana-admin"
    namespace = kubernetes_namespace_v1.monitoring.metadata[0].name
  }
  data = {
    admin-user     = "admin"
    admin-password = random_password.grafana.result
  }
}

# The site clusters remote-write metrics to Prometheus's NodePort 30090 on the control node's private
# address (Cilium serves node ports only on the private interface).
data "kubernetes_nodes" "control" {
  count    = var.second_apply ? 1 : 0
  provider = kubernetes.clusters[local.control_name]
}

locals {
  control_private_ip = var.second_apply ? one([
    for a in data.kubernetes_nodes.control[0].nodes[0].status[0].addresses : a.address if a.type == "InternalIP"
  ]) : null
}

# Chaos Mesh here drives experiments in the site clusters (gitops/control/remote-clusters.yaml). Each
# site cluster's gitops/chaos-target creates a cluster-admin ServiceAccount and a token for it; this
# turns that token into the kubeconfig the RemoteCluster reads.
data "kubernetes_secret_v1" "chaos_remote" {
  for_each = local.site_clusters_wired
  provider = kubernetes.clusters[each.key]

  metadata {
    name      = "chaos-remote"
    namespace = "kube-system"
  }

  lifecycle {
    postcondition {
      condition     = try(self.data.token, "") != ""
      error_message = "The chaos-remote token is not there yet: wait for Flux's chaos-target Kustomization, then apply again."
    }
  }
}

resource "kubernetes_secret_v1" "chaos_kubeconfig" {
  for_each = local.site_clusters_wired
  provider = kubernetes.clusters[local.control_name]

  metadata {
    name      = "${each.key}-kubeconfig"
    namespace = "chaos-mesh" # created by gitops/control
  }
  data = {
    kubeconfig = yamlencode({
      apiVersion = "v1"
      kind       = "Config"
      clusters = [{ name = each.key, cluster = {
        server                     = local.servers[each.key].server
        certificate-authority-data = base64encode(data.kubernetes_secret_v1.chaos_remote[each.key].data["ca.crt"])
      } }]
      users           = [{ name = "chaos-remote", user = { token = data.kubernetes_secret_v1.chaos_remote[each.key].data.token } }]
      contexts        = [{ name = each.key, context = { cluster = each.key, user = "chaos-remote" } }]
      current-context = each.key
    })
  }
}
