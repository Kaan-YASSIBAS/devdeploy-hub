# DevDeploy Hub Local Terraform Bootstrap

## Purpose

This Terraform layer bootstraps local Kubernetes platform add-ons for DevDeploy Hub on kind or minikube.

Application resources remain in `infra/kubernetes` and are applied with Kustomize directly or synced by Argo CD.

## Real-World Separation

Terraform manages platform and cluster-level concerns:

- Platform namespaces
- ingress-nginx
- Argo CD
- Future monitoring bootstrap

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
