# DevDeploy Hub Local Terraform Bootstrap

## Purpose

This Terraform layer bootstraps local Kubernetes platform add-ons for DevDeploy Hub on kind or minikube.

Application resources remain in `infra/kubernetes` and are applied with Kustomize directly or synced by Argo CD.

## Real-World Separation

Terraform manages platform and cluster-level concerns:

- Platform namespaces
- ingress-nginx
- Argo CD
- kube-prometheus-stack monitoring
- Loki and Grafana Alloy logging

Kustomize or GitOps manages application concerns:

- DevDeploy Hub frontend
- DevDeploy Hub backend
- Local PostgreSQL app dependency
- Application services and ingress routes

This separation keeps infrastructure ownership realistic and avoids turning application manifests into Terraform state.

## Prerequisites

- Terraform
- kubectl
- Docker Desktop
- kind or minikube
- Active kubeconfig context

## Usage

```powershell
cd infra/terraform/local
terraform init
terraform fmt
terraform validate
terraform plan
terraform apply
```

By default Terraform uses:

```text
~/.kube/config
```

To target a specific kubeconfig context:

```powershell
terraform plan -var="kube_context=kind-devdeploy"
terraform apply -var="kube_context=kind-devdeploy"
```

## Verify ingress-nginx

```powershell
kubectl get ns
kubectl get pods -n ingress-nginx
kubectl get svc -n ingress-nginx
```

## Verify Argo CD

```powershell
kubectl get pods -n argocd
kubectl get svc -n argocd
kubectl port-forward svc/argocd-server -n argocd 8080:443
```

Open `https://localhost:8080` and sign in as `admin`.

Get the initial password:

```powershell
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
```

## Monitoring Stack

Terraform observability installation is deprecated for the Phase 2 local-first flow. The Launcher is the end-user entry point for workload observability:

```powershell
.\scripts\launcher\devdeploy-launcher.ps1 -BootstrapWorkloadObservability
```

The Terraform resources remain as historical local-development reference only and are disabled by default through `install_monitoring=false` and `install_logging=false`. Do not let Terraform and the Launcher own the same `monitoring` Helm releases at the same time.

When explicitly enabled for historical local development, Terraform installs `kube-prometheus-stack` into the `monitoring` namespace. The stack includes Prometheus, Grafana, Alertmanager, kube-state-metrics, and node-exporter.

This setup is for local development only. Grafana reads its admin credentials from the `devdeploy-grafana-admin` Kubernetes Secret, and the stack is not exposed publicly.

Apply the platform bootstrap:

```powershell
cd infra/terraform/local
terraform init
terraform plan
terraform apply
```

Check monitoring resources:

```powershell
kubectl get pods -n monitoring
kubectl get svc -n monitoring
```

Find service names:

```powershell
kubectl get svc -n monitoring
```

Access Grafana:

```powershell
kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80
```

Open `http://localhost:3000`.

Grafana login uses the credentials stored in `monitoring/devdeploy-grafana-admin`. Do not commit, paste, or print the password in shared logs.

Access Prometheus:

```powershell
kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090:9090
```

Open `http://localhost:9090`.

For production, use proper secret management, persistence, reviewed dashboards, alert routes, ingress, and TLS.

## Logging Stack

Terraform logging installation is also deprecated for the Phase 2 local-first flow. Use the Launcher command above so Prometheus, Loki, Alloy, Grafana, datasources, and backend Service proxy credentials are configured together.

When explicitly enabled for historical local development, Terraform installs Loki and Grafana Alloy into the `monitoring` namespace.

- Loki stores and queries logs.
- Grafana Alloy collects Kubernetes pod logs and forwards them to Loki.
- Grafana gets a Loki datasource through a Terraform-managed ConfigMap watched by the kube-prometheus-stack Grafana sidecar.

Loki uses ephemeral local filesystem storage under `/tmp/loki` for development. Persistence remains disabled, and the chart mounts a writable `emptyDir` at that path.

Promtail is intentionally not used because Grafana Alloy is the modern collector path for Kubernetes logs.

Apply the platform bootstrap:

```powershell
cd infra/terraform/local
terraform init
terraform plan
terraform apply
```

Check logging resources:

```powershell
kubectl get pods -n monitoring
kubectl get svc -n monitoring
```

Access Grafana:

```powershell
kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80
```

Open `http://localhost:3000`, then go to:

```text
Explore -> Loki
```

Example LogQL queries:

```logql
{namespace="devdeploy"}
{namespace="argocd"}
{namespace="monitoring"}
```

This logging setup is local development only. Production logging should add durable object storage, persistence, retention policy, alerting, RBAC review, secret management, and environment-specific Grafana dashboards.

## Deploy App After Platform Bootstrap

From the repository root, build local images for the port-forward first-test path:

```powershell
docker build -t devdeploy-backend:local ./backend
docker build --build-arg VITE_API_BASE_URL=http://localhost:8000/api/v1 -t devdeploy-frontend:local ./frontend
```

For kind:

```powershell
kind load docker-image devdeploy-backend:local --name devdeploy
kind load docker-image devdeploy-frontend:local --name devdeploy
```

Apply the application manifests:

```powershell
kubectl apply -k infra/kubernetes/overlays/dev
```

Or let Argo CD sync the same Kustomize overlay:

```powershell
kubectl apply -f infra/argocd/applications/devdeploy-hub-dev.yaml
kubectl get applications -n argocd
```

For minikube, load the images with:

```powershell
minikube image load devdeploy-backend:local
minikube image load devdeploy-frontend:local
```

## Cleanup

Destroy platform add-ons:

```powershell
cd infra/terraform/local
terraform destroy
```

Remove application manifests:

```powershell
kubectl delete -k infra/kubernetes/overlays/dev
```

## Notes

- This is local development only.
- Secrets in the local Kubernetes app manifests are not production-grade.
- In production, Terraform would manage cloud clusters, IAM, networking, DNS, and platform services.
- Argo CD is installed locally with a ClusterIP service and is intended to be accessed with port-forwarding.
- Application manifests remain outside Terraform state and are managed from `infra/kubernetes`.
