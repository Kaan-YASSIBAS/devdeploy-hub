# DevDeploy Hub Monitoring

## Purpose

The local monitoring stack is installed by Terraform with the `kube-prometheus-stack` Helm chart.

It provides cluster-level observability for local kind or minikube development.

## Installed Components

- Prometheus
- Grafana
- Alertmanager
- kube-state-metrics
- node-exporter

## Install

From the repository root:

```powershell
cd infra/terraform/local
terraform init
terraform plan
terraform apply
```

## Check Resources

```powershell
kubectl get pods -n monitoring
kubectl get svc -n monitoring
```

## Access Grafana

Find the Grafana service:

```powershell
kubectl get svc -n monitoring
```

Port-forward:

```powershell
kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80
```

Open:

```text
http://localhost:3000
```

Local credentials:

```text
username: admin
password: admin
```

## Access Prometheus

```powershell
kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090:9090
```

Open:

```text
http://localhost:9090
```

## Useful Commands

```powershell
kubectl get pods -n monitoring
kubectl get svc -n monitoring
kubectl logs -n monitoring deployment/kube-prometheus-stack-operator
```

## Future Work

- FastAPI application metrics
- Custom DevDeploy Hub dashboards
- Alert rules and notification routes
- Loki-based log aggregation
- Production-grade persistence and secret management
