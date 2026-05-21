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
        sidecar = {
          datasources = {
            enabled    = true
            label      = "grafana_datasource"
            labelValue = "1"
          }
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

resource "helm_release" "loki" {
  count = var.install_logging ? 1 : 0

  name       = "loki"
  repository = "https://grafana.github.io/helm-charts"
  chart      = "loki"
  version    = var.loki_chart_version
  namespace  = kubernetes_namespace_v1.monitoring.metadata[0].name

  create_namespace = false

  values = [
    yamlencode({
      deploymentMode = "SingleBinary"

      loki = {
        auth_enabled = false
        commonConfig = {
          path_prefix        = "/tmp/loki"
          replication_factor = 1
        }
        schemaConfig = {
          configs = [
            {
              from         = "2024-04-01"
              store        = "tsdb"
              object_store = "filesystem"
              schema       = "v13"
              index = {
                prefix = "loki_index_"
                period = "24h"
              }
            }
          ]
        }
        storage = {
          type = "filesystem"
          filesystem = {
            chunks_directory = "/tmp/loki/chunks"
            rules_directory  = "/tmp/loki/rules"
          }
        }
        storage_config = {
          filesystem = {
            directory = "/tmp/loki/chunks"
          }
          tsdb_shipper = {
            active_index_directory = "/tmp/loki/tsdb-index"
            cache_location         = "/tmp/loki/tsdb-cache"
          }
        }
        limits_config = {
          allow_structured_metadata = true
          retention_period          = "24h"
          volume_enabled            = true
        }
        rulerConfig = {
          enable_api = true
          rule_path  = "/tmp/loki/rules-temp"
          wal = {
            dir = "/tmp/loki/ruler-wal"
          }
          storage = {
            type = "local"
            local = {
              directory = "/tmp/loki/rules"
            }
          }
        }
        compactor = {
          working_directory = "/tmp/loki/compactor"
        }
      }

      singleBinary = {
        replicas = 1
        persistence = {
          enabled = false
        }
        resources = {
          requests = {
            cpu    = "100m"
            memory = "256Mi"
          }
          limits = {
            cpu    = "500m"
            memory = "768Mi"
          }
        }
        extraVolumes = [
          {
            name     = "loki-tmp"
            emptyDir = {}
          }
        ]
        extraVolumeMounts = [
          {
            name      = "loki-tmp"
            mountPath = "/tmp/loki"
          }
        ]
      }

      backend = {
        replicas = 0
      }
      read = {
        replicas = 0
      }
      write = {
        replicas = 0
      }
      ingester = {
        replicas = 0
      }
      querier = {
        replicas = 0
      }
      queryFrontend = {
        replicas = 0
      }
      queryScheduler = {
        replicas = 0
      }
      distributor = {
        replicas = 0
      }
      compactor = {
        replicas = 0
      }
      indexGateway = {
        replicas = 0
      }
      bloomPlanner = {
        replicas = 0
      }
      bloomBuilder = {
        replicas = 0
      }
      bloomGateway = {
        replicas = 0
      }

      gateway = {
        enabled = true
        service = {
          type = "ClusterIP"
        }
      }

      minio = {
        enabled = false
      }
      chunksCache = {
        enabled = false
      }
      resultsCache = {
        enabled = false
      }
      lokiCanary = {
        enabled = false
      }
      test = {
        enabled = false
      }
    })
  ]

  depends_on = [
    kubernetes_namespace_v1.monitoring
  ]
}

resource "helm_release" "alloy" {
  count = var.install_logging ? 1 : 0

  name       = "alloy"
  repository = "https://grafana.github.io/helm-charts"
  chart      = "alloy"
  version    = var.alloy_chart_version
  namespace  = kubernetes_namespace_v1.monitoring.metadata[0].name

  create_namespace = false

  values = [
    yamlencode({
      controller = {
        type = "daemonset"
      }

      service = {
        type = "ClusterIP"
      }

      alloy = {
        clustering = {
          enabled = true
        }
        extraEnv = [
          {
            name = "NODE_NAME"
            valueFrom = {
              fieldRef = {
                fieldPath = "spec.nodeName"
              }
            }
          }
        ]
        resources = {
          requests = {
            cpu    = "50m"
            memory = "128Mi"
          }
          limits = {
            cpu    = "250m"
            memory = "256Mi"
          }
        }
        configMap = {
          content = <<-EOT
            logging {
              level  = "info"
              format = "logfmt"
            }

            discovery.kubernetes "pod" {
              role = "pod"

              selectors {
                role  = "pod"
                field = "spec.nodeName=" + sys.env("NODE_NAME")
              }
            }

            discovery.relabel "pod_logs" {
              targets = discovery.kubernetes.pod.targets

              rule {
                source_labels = ["__meta_kubernetes_namespace"]
                action        = "replace"
                target_label  = "namespace"
              }

              rule {
                source_labels = ["__meta_kubernetes_pod_name"]
                action        = "replace"
                target_label  = "pod"
              }

              rule {
                source_labels = ["__meta_kubernetes_pod_container_name"]
                action        = "replace"
                target_label  = "container"
              }

              rule {
                source_labels = ["__meta_kubernetes_pod_label_app_kubernetes_io_name"]
                action        = "replace"
                target_label  = "app"
              }

              rule {
                source_labels = ["__meta_kubernetes_pod_label_app_kubernetes_io_component"]
                action        = "replace"
                target_label  = "component"
              }

              rule {
                source_labels = ["__meta_kubernetes_namespace", "__meta_kubernetes_pod_container_name"]
                action        = "replace"
                target_label  = "job"
                separator     = "/"
                replacement   = "$1"
              }
            }

            loki.source.kubernetes "pod_logs" {
              targets    = discovery.relabel.pod_logs.output
              forward_to = [loki.process.pod_logs.receiver]

              clustering {
                enabled = true
              }
            }

            loki.process "pod_logs" {
              stage.static_labels {
                values = {
                  cluster = "devdeploy-local",
                }
              }

              forward_to = [loki.write.local.receiver]
            }

            loki.write "local" {
              endpoint {
                url = "http://loki-gateway.monitoring.svc.cluster.local/loki/api/v1/push"
              }
            }
          EOT
        }
      }
    })
  ]

  depends_on = [
    helm_release.loki
  ]
}

resource "kubernetes_config_map_v1" "grafana_loki_datasource" {
  count = var.install_monitoring && var.install_logging ? 1 : 0

  metadata {
    name      = "grafana-loki-datasource"
    namespace = kubernetes_namespace_v1.monitoring.metadata[0].name
    labels = merge(local.platform_labels, {
      grafana_datasource = "1"
    })
  }

  data = {
    "loki-datasource.yaml" = yamlencode({
      apiVersion = 1
      datasources = [
        {
          name      = "Loki"
          type      = "loki"
          access    = "proxy"
          url       = "http://loki-gateway.monitoring.svc.cluster.local"
          isDefault = false
          jsonData = {
            maxLines = 1000
          }
        }
      ]
    })
  }

  depends_on = [
    helm_release.kube_prometheus_stack,
    helm_release.loki
  ]
}
