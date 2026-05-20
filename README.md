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

These workflows do not deploy the application. Publishing uses the built-in `GITHUB_TOKEN` and does not require custom repository secrets.

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
- Later, update the GitOps manifest or overlay to the release tag.

The local kind and minikube workflow still uses local images:

```text
devdeploy-backend:local
devdeploy-frontend:local
```

The frontend image is currently built with `VITE_API_BASE_URL=http://localhost:8000/api/v1` to preserve the local port-forward workflow. Future phases will add environment-specific overlays, image tags, or Argo CD Image Updater for GitOps deployment.

The registry-based release overlay lives at `infra/kubernetes/overlays/release`. It uses GHCR images tagged `v1.0.0` and is intended for registry-based GitOps testing.

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

It manages local platform add-ons and namespaces, such as `ingress-nginx`, Argo CD, and `monitoring`. Application manifests stay in `infra/kubernetes` and are applied with Kustomize or synced by Argo CD.

Quick commands:

```powershell
cd infra/terraform/local
terraform init
terraform plan
terraform apply
```

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
