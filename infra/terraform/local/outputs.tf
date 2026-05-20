output "ingress_nginx_namespace" {
  description = "Namespace used by ingress-nginx."
  value       = kubernetes_namespace_v1.ingress_nginx.metadata[0].name
}

output "argocd_namespace" {
  description = "Namespace reserved for the future Argo CD phase."
  value       = kubernetes_namespace_v1.argocd.metadata[0].name
}

output "monitoring_namespace" {
  description = "Namespace reserved for the future observability phase."
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
