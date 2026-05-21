# DevDeploy Hub Logging

## Purpose

The local logging stack provides cluster-level log aggregation for DevDeploy Hub on kind or minikube.

It is installed by Terraform with Helm and runs in the `monitoring` namespace.

## Components

- Loki stores and queries logs.
- Grafana Alloy collects Kubernetes pod logs and forwards them to Loki.
- Grafana Explore is used to inspect logs through the Loki datasource.

Promtail is intentionally not used. Grafana Alloy is the modern collector path for Kubernetes logs.

## Architecture

```text
Kubernetes pod logs -> Grafana Alloy -> Loki -> Grafana Explore
```

Terraform installs:

- `helm_release.loki`
- `helm_release.alloy`
- A Grafana datasource ConfigMap for Loki

Loki uses ephemeral local filesystem storage under `/tmp/loki` for development. The chart mounts an `emptyDir` at that path so Loki can write while keeping persistence disabled.

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

## Access Logs

Port-forward Grafana:

```powershell
kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80
```

Open:

```text
http://localhost:3000
```

Then go to:

```text
Explore -> Loki
```

## Useful LogQL Queries

```logql
{namespace="devdeploy"}
{namespace="argocd"}
{namespace="monitoring"}
{namespace="devdeploy", app="devdeploy-hub"}
{namespace="devdeploy", component="backend"}
```

## Troubleshooting

```powershell
kubectl get pods -n monitoring
kubectl logs -n monitoring -l app.kubernetes.io/name=alloy
kubectl logs -n monitoring -l app.kubernetes.io/name=loki
kubectl get configmap -n monitoring | findstr grafana
kubectl get svc -n monitoring
```

If the Loki datasource does not appear in Grafana, restart the Grafana pod after verifying the datasource ConfigMap exists:

```powershell
kubectl rollout restart deployment/kube-prometheus-stack-grafana -n monitoring
```

## Future Work

- Structured application logs
- Application log correlation with deployment IDs
- Log retention policies
- Alerts from logs
- Production object storage
- Persistent Loki storage
- Environment-specific dashboards
