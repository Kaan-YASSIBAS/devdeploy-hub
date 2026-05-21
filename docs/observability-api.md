# DevDeploy Hub Observability API

## Purpose

The backend exposes authenticated, read-only observability endpoints for Kubernetes resources, Prometheus metrics, and Loki logs.

These endpoints are intended to replace frontend mock cluster, monitoring, and log data incrementally. They do not deploy workloads or mutate Kubernetes resources.

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
GET /api/v1/observability/logs?namespace=devdeploy&limit=100
GET /api/v1/observability/logs?namespace=devdeploy&pod=<pod-name>&limit=100
```

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
