# Provider 0.0.2 leaves the cluster's kubeconfig empty, so fetch it from Hostman's API.
data "http" "kubeconfig" {
  for_each = local.all_clusters

  url = "https://hostman.com/api/v1/k8s/clusters/${hm_k8s_cluster.this[each.key].id}/kubeconfig"
  request_headers = {
    Authorization = "Bearer ${var.hm_token}"
    Accept        = "application/yaml"
  }
  retry {
    attempts     = 4
    min_delay_ms = 1000
    max_delay_ms = 10000
  }

  lifecycle {
    postcondition {
      condition     = self.status_code == 200
      error_message = "Hostman must return the kubeconfig (HTTP 200) before the Kubernetes providers can connect."
    }
  }
}

locals {
  # The API has returned the kubeconfig as plain YAML, as a quoted string and as base64.
  kubeconfigs = {
    for name, response in data.http.kubeconfig : name => sensitive(try(
      merge(yamldecode(sensitive(response.response_body))),
      merge(yamldecode(yamldecode(sensitive(response.response_body)))),
      merge(yamldecode(base64decode(yamldecode(sensitive(response.response_body))))),
    ))
  }
  contexts = { for name, c in local.kubeconfigs : name => one([for x in c.contexts : x.context if x.name == c["current-context"]]) }
  servers  = { for name, c in local.kubeconfigs : name => one([for x in c.clusters : x.cluster if x.name == local.contexts[name].cluster]) }
  users    = { for name, c in local.kubeconfigs : name => one([for x in c.users : x.user if x.name == local.contexts[name].user]) }
}

provider "kubernetes" {
  alias    = "clusters"
  for_each = local.all_clusters

  host                   = local.servers[each.key].server
  cluster_ca_certificate = base64decode(local.servers[each.key]["certificate-authority-data"])
  client_certificate     = try(base64decode(local.users[each.key]["client-certificate-data"]), null)
  client_key             = try(base64decode(local.users[each.key]["client-key-data"]), null)
  token                  = try(local.users[each.key].token, null)
}

provider "helm" {
  alias    = "clusters"
  for_each = local.all_clusters

  kubernetes = {
    host                   = local.servers[each.key].server
    cluster_ca_certificate = base64decode(local.servers[each.key]["certificate-authority-data"])
    client_certificate     = try(base64decode(local.users[each.key]["client-certificate-data"]), null)
    client_key             = try(base64decode(local.users[each.key]["client-key-data"]), null)
    token                  = try(local.users[each.key].token, null)
  }
}
