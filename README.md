# DevDeploy Hub

A full-stack DevOps platform for self-service Kubernetes deployments, GitOps workflows, observability, and infrastructure automation.

## Vision

DevDeploy Hub aims to provide a modern internal developer platform experience where teams can deploy, monitor, and manage applications across Kubernetes environments.

## Current Phase

Phase 1: Full-stack local development foundation with Docker Compose, FastAPI, PostgreSQL, and the premium React frontend.

## Docker Compose

Run the full stack from the repository root:

```powershell
docker compose up --build
```

Services:

```text
Frontend:     http://localhost:5173
Backend API:  http://localhost:8000
Swagger Docs: http://localhost:8000/docs
Health:       http://localhost:8000/api/v1/health
```

Stop the stack:

```powershell
docker compose down
```

Reset the database volume:

```powershell
docker compose down -v
```

In development mode, the first registered user becomes `admin`; later users are created as `developer`.

## Local Development

The Docker setup does not replace local workflows. You can still run the backend with `uvicorn app.main:app --reload` from `backend/`, and the frontend with `npm run dev` from `frontend/`.

## Continuous Integration

GitHub Actions workflows live in `.github/workflows`:

- `frontend-ci.yml` validates the React/Vite frontend with `npm ci`, `npm run lint`, and `npm run build`.
- `backend-ci.yml` validates the FastAPI backend by installing Python dependencies, compiling modules, running Alembic migrations against PostgreSQL, importing the app, and smoke testing `/api/v1/health`.
- `docker-ci.yml` validates `docker-compose.yml` and builds the backend and frontend Docker images.
- `kubernetes-ci.yml` validates Kustomize rendering and Kubernetes manifest schemas for the local dev overlay.
- `terraform-ci.yml` validates Terraform formatting, initialization, and configuration for the local platform bootstrap layer.
- `argocd-ci.yml` validates the Argo CD Application manifests used for local GitOps sync.
- `container-publish.yml` publishes backend and frontend container images to GitHub Container Registry on pushes to `main` or manual dispatch.
- `gitops-promotion.yml` updates the release Kustomize overlay image tags and opens a promotion pull request.
- `gitops-workload-request.yml` generates workload manifests and opens a GitOps deployment pull request.
- `security-ci.yml` scans backend dependencies, frontend dependencies, repository files, IaC, and Docker images.

These workflows do not deploy the application directly. Publishing and promotion use the built-in `GITHUB_TOKEN` and do not require custom repository secrets.

## DevSecOps / Security

Security scanning runs through `.github/workflows/security-ci.yml`.

It includes:

```text
Python dependency scanning with pip-audit
npm dependency scanning with npm audit
Trivy filesystem, secret, and IaC scanning
Trivy backend and frontend image scanning
```

High and critical Trivy findings fail CI. Frontend dependency advisories at moderate severity or higher fail CI. The workflow does not push images, deploy workloads, or run automatic fixes.

Detailed local commands and scope notes live in `docs/security.md`.

## Container Registry

Backend and frontend images are published to GitHub Container Registry on pushes to `main`, and on semantic release tags that match `v*.*.*`.

Images:

```text
Backend:  ghcr.io/kaan-yassibas/devdeploy-backend
Frontend: ghcr.io/kaan-yassibas/devdeploy-frontend
```

Main branch builds produce:

```text
main
latest
sha-<shortsha>
```

Release tag builds produce:

```text
v1.0.0
sha-<shortsha>
```

The workflow can also be started manually with `workflow_dispatch`.

Create and push a release tag:

```powershell
git tag v1.0.0
git push origin v1.0.0
```

Pushing a `v*.*.*` Git tag triggers `container-publish.yml` and publishes release-tagged backend and frontend images to GHCR.

Recommended deployment tags:

- Use `sha-<shortsha>` for exact traceability.
- Use `v1.0.0` style tags for stable release deployments.
- Avoid `latest` for GitOps production-like deployments.

Release checklist:

- Ensure CI is green on `main`.
- Create a semantic version tag.
- Push the tag.
- Verify the `Container Publish` workflow.
- Verify the GHCR backend and frontend packages.
- Run the `GitOps Promotion` workflow for the same tag.
- Review and merge the generated promotion pull request.

The local kind and minikube workflow still uses local images:

```text
devdeploy-backend:local
devdeploy-frontend:local
```

The frontend image is currently built with `VITE_API_BASE_URL=http://localhost:8000/api/v1` to preserve the local port-forward workflow. Future phases will add environment-specific overlays, image tags, or Argo CD Image Updater for GitOps deployment.

The registry-based release overlay lives at `infra/kubernetes/overlays/release`. It uses GHCR images tagged `v1.0.0` and is intended for registry-based GitOps testing.

## GitOps Image Promotion

Release image promotion is PR-based. CI does not deploy directly to Kubernetes.

Promotion flow:

```powershell
git tag v1.1.0
git push origin v1.1.0
```

After `container-publish.yml` publishes both GHCR images, run:

```text
Actions -> GitOps Promotion -> Run workflow -> image_tag = v1.1.0
```

The workflow updates:

```text
infra/kubernetes/overlays/release/kustomization.yaml
```

It opens a pull request named:

```text
chore: promote release images to v1.1.0
```

After the PR checks pass and the PR is merged, Argo CD syncs the release overlay and deploys the promoted image tag.

The workflow uses `GITHUB_TOKEN` by default. If your repository policy requires workflows to run from bot-created promotion PRs, configure an optional `GITOPS_PROMOTION_TOKEN` secret with the same repository write scope.

Local script validation:

```powershell
python scripts/promote-release-images.py v1.1.0
kubectl kustomize infra/kubernetes/overlays/release
```

## Kubernetes Local Manifests

Local Kubernetes manifests live in `infra/kubernetes`.

Quick commands:

```powershell
kubectl apply -k infra/kubernetes/overlays/dev
kubectl get all -n devdeploy
```

The detailed guide in `infra/kubernetes/README.md` covers local image builds for kind/minikube, the first-test port-forward path, and the optional `devdeploy.local` ingress path.

## Terraform Local Bootstrap

Terraform local platform bootstrap lives in `infra/terraform/local`.

It manages local platform add-ons and namespaces, such as `ingress-nginx`, Argo CD, and kube-prometheus-stack in `monitoring`. Application manifests stay in `infra/kubernetes` and are applied with Kustomize or synced by Argo CD.

Quick commands:

```powershell
cd infra/terraform/local
terraform init
terraform plan
terraform apply
```

## Monitoring

The local monitoring stack is installed by Terraform from `infra/terraform/local` using the `kube-prometheus-stack` Helm chart.

It includes:

```text
Prometheus
Grafana
Alertmanager
kube-state-metrics
node-exporter
```

Access is local-only through port-forwarding:

```powershell
kubectl get svc -n monitoring
kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80
kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090:9090
```

Grafana uses `admin` / `admin` for local development. This is cluster-level monitoring; application-level FastAPI metrics will be added later.

## Logging

Cluster-level log aggregation is installed by Terraform from `infra/terraform/local`.

It uses:

```text
Loki
Grafana Alloy
Grafana Explore
```

Loki stores and queries logs. Grafana Alloy runs as the collector and forwards Kubernetes pod logs to Loki. Promtail is intentionally avoided because Alloy is the modern collector path.

View logs through Grafana:

```powershell
kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80
```

Open `http://localhost:3000`, then use `Explore -> Loki`.

Example LogQL queries:

```logql
{namespace="devdeploy"}
{namespace="argocd"}
{namespace="monitoring"}
```

## Backend Observability API

The backend exposes authenticated, read-only APIs for real cluster and observability data.

Capabilities:

```text
Kubernetes resource summary, namespaces, pods, deployments, and services
Prometheus cluster and namespace metrics
Loki namespace and pod logs
```

Routes live under:

```text
/api/v1/observability
```

The backend pod uses in-cluster Kubernetes config and a read-only `devdeploy-backend` ServiceAccount. RBAC allows only `get`, `list`, and `watch` on namespaces, nodes, pods, services, and deployments. No write permissions are granted.

The frontend Cluster, Monitoring, and Logs pages now consume these authenticated endpoints. In Kubernetes, those pages show live Kubernetes resources, Prometheus summary metrics, and Loki log lines; the monitoring time-series charts remain preview/demo data until range-query charts are connected.

In Docker Compose, observability integrations may return `503` unless the backend can reach a local Kubernetes API, Prometheus, and Loki. The app still starts normally.

Detailed endpoint examples live in `docs/observability-api.md`.

## GitOps / Argo CD

Argo CD is installed by Terraform as a local platform add-on. It can sync the dev overlay at `infra/kubernetes/overlays/dev` or the GHCR-backed release overlay at `infra/kubernetes/overlays/release`.

The dev Argo CD Application manifest lives at:

```text
infra/argocd/applications/devdeploy-hub-dev.yaml
```

A release Application is also available for the GHCR-backed release overlay:

```text
infra/argocd/applications/devdeploy-hub-release.yaml
```

Quick commands:

```powershell
cd infra/terraform/local
terraform apply

kubectl apply -f infra/argocd/applications/devdeploy-hub-dev.yaml
kubectl get applications -n argocd
```

Kustomize remains the source of application manifests; Terraform manages the platform bootstrap, and Argo CD performs the app sync. Use either the dev or release Application in the `devdeploy` namespace at a time unless you are intentionally testing overlap.

## GitOps Deployment Request Engine

DevDeploy Hub can now create deployment requests that generate Kubernetes workload manifests through GitHub Actions and pull requests.

The backend does not deploy directly to Kubernetes and does not run `kubectl apply`. It stores the request, optionally dispatches `.github/workflows/gitops-workload-request.yml`, and returns manual workflow inputs when GitHub dispatch is not configured.

Generated workload manifests live under:

```text
infra/kubernetes/generated/workloads/apps/<app-name>
```

The release overlay includes `infra/kubernetes/generated/workloads`, so after a generated workload PR is merged, Argo CD can sync the workload from Git.

Automatic dispatch is controlled with:

```text
GITOPS_ENABLED=true
GITHUB_WORKFLOW_TOKEN=<token>
```

Local development can leave `GITOPS_ENABLED=false` and run the workflow manually:

```text
Actions -> GitOps Workload Request -> Run workflow
```

Detailed architecture and local examples live in `docs/gitops-deployment-engine.md`.
