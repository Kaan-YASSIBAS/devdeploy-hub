# DevDeploy Hub Argo CD Bootstrap

## Purpose

Argo CD provides GitOps delivery for DevDeploy Hub. It watches Kubernetes manifests in Git and syncs the desired state into the local cluster.

## Architecture

Terraform installs the platform layer:

- `ingress-nginx`
- `argocd`
- Shared platform namespaces

Argo CD syncs the DevDeploy Hub application manifests from:

```text
infra/kubernetes/overlays/dev
```

Kustomize remains the source for application manifests. Terraform does not manage the frontend, backend, PostgreSQL, services, or ingress resources for the app.

## Prerequisites

- kind or minikube cluster
- Terraform bootstrap applied
- Local images loaded into the cluster:
  - `devdeploy-backend:local`
  - `devdeploy-frontend:local`
- Repository pushed to the GitHub branch referenced by the Argo CD Application

The default Application manifest points to:

```text
https://github.com/Kaan-YASSIBAS/devdeploy-hub.git
```

If you are working from a fork or private repository, update `repoURL` in `infra/argocd/applications/devdeploy-hub-dev.yaml`.

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

## Apply Argo CD Application

From the repository root:

```powershell
kubectl apply -f infra/argocd/applications/devdeploy-hub-dev.yaml
```

Check the Application:

```powershell
kubectl get applications -n argocd
kubectl describe application devdeploy-hub-dev -n argocd
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
- Images are still local kind or minikube images.
- Later phases can add GHCR or Docker Hub publishing and Argo CD Image Updater.
- Secret values are local placeholders.
- Production should use external secret management, stricter RBAC, and a reviewed Argo CD project model.
