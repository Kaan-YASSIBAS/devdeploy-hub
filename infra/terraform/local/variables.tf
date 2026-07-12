variable "kubeconfig_path" {
  description = "Path to the local kubeconfig file used for kind or minikube."
  type        = string
  default     = "~/.kube/config"
}

variable "kube_context" {
  description = "Optional kubeconfig context. When null, Terraform uses the current context."
  type        = string
  default     = null
}

variable "ingress_nginx_chart_version" {
  description = "Optional ingress-nginx chart version. Null uses the provider's latest resolvable chart version."
  type        = string
  default     = null
}

variable "install_ingress_nginx" {
  description = "Whether to install ingress-nginx through Helm."
  type        = bool
  default     = true
}

variable "argocd_chart_version" {
  description = "Optional Argo CD chart version. Null uses the provider's latest resolvable chart version."
  type        = string
  default     = null
}

variable "install_argocd" {
  description = "Whether to install Argo CD through Helm."
  type        = bool
  default     = true
}

variable "kube_prometheus_stack_chart_version" {
  description = "Optional kube-prometheus-stack chart version. Null uses the provider's latest resolvable chart version for local development."
  type        = string
  default     = null
}

variable "install_monitoring" {
  description = "Deprecated. Whether to install kube-prometheus-stack through Terraform. Phase 2 local-first flows use scripts/launcher/devdeploy-launcher.ps1 -BootstrapWorkloadObservability instead."
  type        = bool
  default     = false
}

variable "loki_chart_version" {
  description = "Optional Loki chart version. Null uses the provider's latest resolvable chart version for local development."
  type        = string
  default     = null
}

variable "alloy_chart_version" {
  description = "Optional Grafana Alloy chart version. Null uses the provider's latest resolvable chart version for local development."
  type        = string
  default     = null
}

variable "install_logging" {
  description = "Deprecated. Whether to install Loki and Grafana Alloy through Terraform. Phase 2 local-first flows use scripts/launcher/devdeploy-launcher.ps1 -BootstrapWorkloadObservability instead."
  type        = bool
  default     = false
}
