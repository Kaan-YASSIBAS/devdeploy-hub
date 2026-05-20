locals {
  platform_labels = {
    "app.kubernetes.io/managed-by" = "terraform"
    "devdeploy.io/platform"        = "true"
  }
}

resource "kubernetes_namespace_v1" "ingress_nginx" {
  metadata {
    name   = "ingress-nginx"
    labels = local.platform_labels
  }
}

resource "kubernetes_namespace_v1" "argocd" {
  metadata {
    name   = "argocd"
    labels = local.platform_labels
  }
}

resource "kubernetes_namespace_v1" "monitoring" {
  metadata {
    name   = "monitoring"
    labels = local.platform_labels
  }
}

resource "helm_release" "ingress_nginx" {
  count = var.install_ingress_nginx ? 1 : 0

  name       = "ingress-nginx"
  repository = "https://kubernetes.github.io/ingress-nginx"
  chart      = "ingress-nginx"
  version    = var.ingress_nginx_chart_version
  namespace  = kubernetes_namespace_v1.ingress_nginx.metadata[0].name

  create_namespace = false

  values = [
    yamlencode({
      controller = {
        service = {
          type = "NodePort"
        }
      }
    })
  ]

  depends_on = [
    kubernetes_namespace_v1.ingress_nginx
  ]
}

resource "helm_release" "argocd" {
  count = var.install_argocd ? 1 : 0

  name       = "argocd"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  version    = var.argocd_chart_version
  namespace  = kubernetes_namespace_v1.argocd.metadata[0].name

  create_namespace = false

  values = [
    yamlencode({
      server = {
        service = {
          type = "ClusterIP"
        }
      }
    })
  ]

  depends_on = [
    kubernetes_namespace_v1.argocd
  ]
}

resource "helm_release" "kube_prometheus_stack" {
  count = var.install_monitoring ? 1 : 0

  name       = "kube-prometheus-stack"
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "kube-prometheus-stack"
  version    = var.kube_prometheus_stack_chart_version
  namespace  = kubernetes_namespace_v1.monitoring.metadata[0].name

  create_namespace = false

  values = [
    yamlencode({
      grafana = {
        enabled       = true
        adminPassword = "admin"
        service = {
          type = "ClusterIP"
        }
      }

      prometheus = {
        enabled = true
        service = {
          type = "ClusterIP"
        }
        prometheusSpec = {
          retention = "6h"
          resources = {
            requests = {
              cpu    = "100m"
              memory = "256Mi"
            }
            limits = {
              cpu    = "500m"
              memory = "1Gi"
            }
          }
        }
      }

      alertmanager = {
        enabled = true
        service = {
          type = "ClusterIP"
        }
        alertmanagerSpec = {
          resources = {
            requests = {
              cpu    = "50m"
              memory = "128Mi"
            }
            limits = {
              cpu    = "200m"
              memory = "256Mi"
            }
          }
        }
      }
    })
  ]

  depends_on = [
    kubernetes_namespace_v1.monitoring
  ]
}
