output "ingress_nginx_namespace" {
  description = "Namespace used by ingress-nginx."
  value       = kubernetes_namespace_v1.ingress_nginx.metadata[0].name
}

output "argocd_namespace" {
  description = "Namespace used by Argo CD."
  value       = kubernetes_namespace_v1.argocd.metadata[0].name
}

output "monitoring_namespace" {
  description = "Namespace used by the monitoring stack."
  value       = kubernetes_namespace_v1.monitoring.metadata[0].name
}

output "ingress_nginx_release_name" {
  description = "Helm release name for ingress-nginx when installed."
  value       = try(helm_release.ingress_nginx[0].name, null)
}

output "ingress_nginx_release_status" {
  description = "Helm release status for ingress-nginx when installed."
  value       = try(helm_release.ingress_nginx[0].status, null)
}

output "argocd_release_name" {
  description = "Helm release name for Argo CD when installed."
  value       = try(helm_release.argocd[0].name, null)
}

output "argocd_release_status" {
  description = "Helm release status for Argo CD when installed."
  value       = try(helm_release.argocd[0].status, null)
}

output "monitoring_release_name" {
  description = "Helm release name for kube-prometheus-stack when installed."
  value       = try(helm_release.kube_prometheus_stack[0].name, null)
}

output "monitoring_release_status" {
  description = "Helm release status for kube-prometheus-stack when installed."
  value       = try(helm_release.kube_prometheus_stack[0].status, null)
}

output "grafana_service_hint" {
  description = "Port-forward command for local Grafana access."
  value       = var.install_monitoring ? "kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80" : null
}

output "prometheus_service_hint" {
  description = "Port-forward command for local Prometheus access."
  value       = var.install_monitoring ? "kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090:9090" : null
}
