resource "hm_vpc" "this" {
  name      = "kcd"
  location  = var.location
  subnet_v4 = var.vpc_subnet
}

data "hm_k8s_preset" "master" {
  type     = "master"
  cpu      = 2
  ram      = 2 * 1024
  location = var.location
}

data "hm_k8s_preset" "worker" {
  for_each = local.all_clusters

  type     = "worker"
  cpu      = each.value.worker_cpu
  ram      = each.value.worker_ram_gb * 1024
  location = var.location
}

resource "hm_k8s_cluster" "this" {
  for_each = local.all_clusters

  name              = each.key
  network_id        = hm_vpc.this.id
  preset_id         = data.hm_k8s_preset.master.id
  version           = var.kubernetes_version
  network_driver    = "cilium"
  high_availability = false
}

resource "hm_k8s_node_group" "workers" {
  for_each = local.all_clusters

  cluster_id     = hm_k8s_cluster.this[each.key].id
  name           = "workers"
  preset_id      = data.hm_k8s_preset.worker[each.key].id
  node_count     = 1
  is_autohealing = true

  lifecycle {
    # Provider 0.0.2 reads is_autohealing back as false, a diff on every plan.
    ignore_changes = [is_autohealing]
  }
}
