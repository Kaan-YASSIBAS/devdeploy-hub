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
