# DevDeploy Hub Observability API

## Purpose

The backend exposes authenticated, read-only observability endpoints for Kubernetes resources, Prometheus metrics, and Loki logs.

These endpoints are intended to replace frontend mock cluster, monitoring, and log data incrementally. They do not deploy workloads or mutate Kubernetes resources.

The frontend Cluster, Monitoring, and Logs pages use these endpoints when the app is running against the backend API. If Kubernetes, Prometheus, or Loki are unavailable, the UI shows friendly unavailable states instead of falling back to raw errors.

## Runtime Configuration

Backend settings:

```text
KUBERNETES_IN_CLUSTER=true
KUBECONFIG_PATH=
PROMETHEUS_BASE_URL=http://kube-prometheus-stack-prometheus.monitoring.svc.cluster.local:9090
LOKI_BASE_URL=http://loki-gateway.monitoring.svc.cluster.local
```

In Docker Compose, `KUBERNETES_IN_CLUSTER=false` and the Prometheus/Loki URLs point at localhost. If those services are not reachable from the backend container, observability endpoints return `503` instead of crashing startup.

## Authentication

All observability routes require the existing bearer token auth.

Example:

```powershell
curl -H "Authorization: Bearer <token>" http://localhost:8000/api/v1/observability/health
```

## Endpoints

```text
GET /api/v1/observability/health
GET /api/v1/observability/cluster/summary
GET /api/v1/observability/kubernetes/namespaces
GET /api/v1/observability/kubernetes/pods?namespace=devdeploy
GET /api/v1/observability/kubernetes/deployments?namespace=devdeploy
GET /api/v1/observability/kubernetes/services?namespace=devdeploy
GET /api/v1/observability/metrics/cluster
GET /api/v1/observability/metrics/namespaces/devdeploy
GET /api/v1/observability/metrics/timeseries?namespace=devdeploy&range=15m
GET /api/v1/observability/logs?namespace=devdeploy&limit=100
GET /api/v1/observability/logs?namespace=devdeploy&pod=<pod-name>&limit=100
```

## Prometheus Time-Series

`GET /api/v1/observability/metrics/timeseries` returns real Prometheus range-query data for CPU, memory, pod restarts, request rate, and error rate.

Supported query parameters:

```text
namespace=devdeploy
range=5m | 15m | 1h | 6h | 24h | 7d
step=15s | 30s | 1m | 5m | 15m | 1h
metric=cpu_usage | memory_working_set | pod_restarts | request_rate | error_rate
```

When `step` is omitted, the backend chooses a Prometheus step from the selected range:

```text
5m  -> 15s
15m -> 30s
1h  -> 1m
6h  -> 5m
24h -> 15m
7d  -> 1h
```

If Prometheus is unreachable, the endpoint returns `503`. If Prometheus is reachable but a metric has no samples, that series is returned with `status: "empty"` and an empty `points` list. Request and error rate charts may be empty until application or ingress HTTP counters are exposed.

## Kubernetes RBAC

The backend pod uses the `devdeploy-backend` ServiceAccount.

It is bound to a read-only ClusterRole with:

```text
get
list
watch
```

Allowed resources:

```text
namespaces
nodes
pods
services
deployments.apps
```

No write verbs are granted.

## Local Kind Test Flow

Apply the platform and app first:

```powershell
cd infra/terraform/local
terraform apply

cd ../../..
kubectl apply -k infra/kubernetes/overlays/dev
```

Port-forward the backend:

```powershell
kubectl port-forward -n devdeploy svc/devdeploy-backend 8000:8000
```

Register/login through the frontend or Swagger, then call:

```powershell
curl -H "Authorization: Bearer <token>" http://localhost:8000/api/v1/observability/health
curl -H "Authorization: Bearer <token>" http://localhost:8000/api/v1/observability/cluster/summary
curl -H "Authorization: Bearer <token>" "http://localhost:8000/api/v1/observability/logs?namespace=devdeploy&limit=50"
```

## Graceful Unavailability

If Kubernetes, Prometheus, or Loki are not reachable, the API returns `503 Service Unavailable` with a concise reason.

The app still starts normally in Docker Compose even when no Kubernetes cluster is available.
