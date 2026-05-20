# DevDeploy Hub Argo CD Bootstrap

## Purpose

Argo CD provides GitOps delivery for DevDeploy Hub. It watches Kubernetes manifests in Git and syncs the desired state into the local cluster.

## Architecture

Terraform installs the platform layer:

- `ingress-nginx`
- `argocd`
- Shared platform namespaces

Argo CD can sync the DevDeploy Hub application manifests from:

```text
infra/kubernetes/overlays/dev
infra/kubernetes/overlays/release
```

Kustomize remains the source for application manifests. Terraform does not manage the frontend, backend, PostgreSQL, services, or ingress resources for the app.

## Prerequisites

- kind or minikube cluster
- Terraform bootstrap applied
- For the dev Application, local images loaded into the cluster:
  - `devdeploy-backend:local`
  - `devdeploy-frontend:local`
- For the release Application, published GHCR images:
  - `ghcr.io/kaan-yassibas/devdeploy-backend:v1.0.0`
  - `ghcr.io/kaan-yassibas/devdeploy-frontend:v1.0.0`
- Repository pushed to the GitHub branch referenced by the Argo CD Application

The default Application manifest points to:

```text
https://github.com/Kaan-YASSIBAS/devdeploy-hub.git
```

If you are working from a fork or private repository, update `repoURL` in the Application manifest you are applying.

## Install Platform With Terraform

```powershell
cd infra/terraform/local
terraform init
terraform apply
```

## Check Argo CD

```powershell
kubectl get pods -n argocd
kubectl get svc -n argocd
```

## Access Argo CD UI

```powershell
kubectl port-forward svc/argocd-server -n argocd 8080:443
```

Open:

```text
https://localhost:8080
```

Get the initial admin password:

```powershell
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
```

Username:

```text
admin
```

## Apply Dev Argo CD Application

From the repository root:

```powershell
kubectl apply -f infra/argocd/applications/devdeploy-hub-dev.yaml
```

Check the Application:

```powershell
kubectl get applications -n argocd
kubectl describe application devdeploy-hub-dev -n argocd
```

## Apply Release Argo CD Application

Two Application manifests are available:

```text
devdeploy-hub-dev     -> infra/kubernetes/overlays/dev
devdeploy-hub-release -> infra/kubernetes/overlays/release
```

The release Application uses GHCR release images through the release overlay. The dev Application uses local kind or minikube images through the dev overlay.

Do not run both Applications against the same namespace at the same time unless you are intentionally testing takeover or resource ownership overlap. For clean testing, delete one before applying the other:

```powershell
kubectl delete application devdeploy-hub-dev -n argocd
kubectl apply -f infra/argocd/applications/devdeploy-hub-release.yaml
```

Check the release Application:

```powershell
kubectl get applications -n argocd
kubectl describe application devdeploy-hub-release -n argocd
```

Check DevDeploy Hub resources:

```powershell
kubectl get pods -n devdeploy
kubectl get svc -n devdeploy
```

## Access DevDeploy Hub

Use the port-forward first-test path:

```powershell
kubectl port-forward -n devdeploy svc/devdeploy-backend 8000:8000
kubectl port-forward -n devdeploy svc/devdeploy-frontend 5173:80
```

Then open:

```text
Frontend:       http://localhost:5173
Backend Health: http://localhost:8000/api/v1/health
Swagger:        http://localhost:8000/docs
```

## Notes

- This is a local GitOps bootstrap.
- The dev Application uses local kind or minikube images.
- The release Application uses GHCR release images.
- Later phases can add automated image promotion or Argo CD Image Updater.
- Secret values are local placeholders.
- Production should use external secret management, stricter RBAC, and a reviewed Argo CD project model.
