output "dns_front_ips" {
  description = "Each site cluster's k8gb nameserver address (empty until second_apply = true)."
  value       = { for name, ip in hm_server_ip.dns_front : name => ip.ip }
}

output "gateway_ips" {
  value = { for name, svc in data.kubernetes_service_v1.gateway : name => svc.status[0].load_balancer[0].ingress[0].ip }
}

output "grafana_url" {
  value = "https://${local.cluster_vars[local.control_name].GRAFANA_HOST}"
}

output "grafana_admin_password" {
  value     = random_password.grafana.result
  sensitive = true
}

output "kubeconfigs" {
  description = "Admin kubeconfig per cluster: tofu output -json kubeconfigs | jq -r .porto > porto.yaml"
  value       = { for name, c in local.kubeconfigs : name => yamlencode(c) }
  sensitive   = true
}
