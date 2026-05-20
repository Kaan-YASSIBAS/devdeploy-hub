# DevDeploy Hub Local Kubernetes Manifests

## Purpose

These manifests deploy DevDeploy Hub to a local Kubernetes cluster such as kind or minikube. They are intended for local development and portfolio validation only.

This phase does not add Kubernetes automation inside the backend, Terraform, Argo CD, or observability infrastructure.

## Prerequisites

- Docker
- kubectl
- kind or minikube
- ingress-nginx if using the optional `devdeploy.local` ingress path

## Build Local Images

The manifests reference:

```text
devdeploy-backend:local
devdeploy-frontend:local
```

### Port-Forward First-Test Path

Use this path first. It avoids ingress setup and serves the frontend at `http://localhost:5173` while the backend API is port-forwarded at `http://localhost:8000`.

```powershell
docker build -t devdeploy-backend:local ./backend
docker build --build-arg VITE_API_BASE_URL=http://localhost:8000/api/v1 -t devdeploy-frontend:local ./frontend
```

For kind:

```powershell
kind load docker-image devdeploy-backend:local
kind load docker-image devdeploy-frontend:local
```

For minikube:

```powershell
minikube image load devdeploy-backend:local
minikube image load devdeploy-frontend:local
```

You can also build directly into the minikube Docker daemon:

```powershell
minikube docker-env | Invoke-Expression
docker build -t devdeploy-backend:local ./backend
docker build --build-arg VITE_API_BASE_URL=http://localhost:8000/api/v1 -t devdeploy-frontend:local ./frontend
```

### Optional Ingress devdeploy.local Path

If you want to access the app through `http://devdeploy.local`, build the frontend with the ingress API URL instead:

```powershell
docker build -t devdeploy-backend:local ./backend
docker build --build-arg VITE_API_BASE_URL=http://devdeploy.local/api/v1 -t devdeploy-frontend:local ./frontend
```

Then load the images into kind or minikube as shown above.

## Apply Manifests

```powershell
kubectl apply -k infra/kubernetes/overlays/dev
```

The base ConfigMap keeps `FRONTEND_ORIGIN=http://devdeploy.local` for ingress. The dev overlay allows both `http://devdeploy.local` and `http://localhost:5173` so the port-forward first-test path works without changing application code.

The backend Deployment uses an initContainer to wait for PostgreSQL before running Alembic migrations and starting Uvicorn. This reduces startup restarts when the database pod is running but not ready yet.

## Check Resources

```powershell
kubectl get all -n devdeploy
kubectl get ingress -n devdeploy
kubectl logs -n devdeploy deployment/devdeploy-backend
kubectl logs -n devdeploy deployment/devdeploy-frontend
```

## Access App

### Port-Forward First-Test Path

Run these in separate terminals:

```powershell
kubectl port-forward -n devdeploy svc/devdeploy-backend 8000:8000
kubectl port-forward -n devdeploy svc/devdeploy-frontend 5173:80
```

Then open:

```text
Frontend: http://localhost:5173
Backend:  http://localhost:8000/api/v1/health
Swagger:  http://localhost:8000/docs
```

### Optional Ingress devdeploy.local Path

Add a local hosts entry:

```text
127.0.0.1 devdeploy.local
```

For ingress-nginx on kind, your cluster may need port mappings for ports 80 and 443 when the cluster is created. Depending on your local setup, you may also need to port-forward the ingress-nginx controller service.

Then open:

```text
Frontend: http://devdeploy.local
Backend:  http://devdeploy.local/api/v1/health
Swagger:  http://devdeploy.local/docs
```

## Test Flow

1. Register a user.
2. Login.
3. Create an application.
4. Create a deployment.
5. Check the dashboard summary.

## Troubleshooting

```powershell
kubectl get pods -n devdeploy
kubectl describe pod -n devdeploy <pod-name>
kubectl logs -n devdeploy deployment/devdeploy-backend
kubectl logs -n devdeploy deployment/postgres
kubectl rollout status deployment/devdeploy-backend -n devdeploy
kubectl get events -n devdeploy --sort-by=.lastTimestamp
```

If the backend is slow to become ready, check the initContainer status and Postgres logs first:

```powershell
kubectl describe pod -n devdeploy -l app.kubernetes.io/component=backend
kubectl logs -n devdeploy deployment/postgres
```

## Cleanup

```powershell
kubectl delete -k infra/kubernetes/overlays/dev
```

## Notes

- Secret values are local-only and intentionally simple.
- PostgreSQL runs as a simple Deployment for local development.
- A production setup should use managed PostgreSQL or a proper StatefulSet/operator.
- Kubernetes deployment automation is not implemented yet.
- Terraform, GitOps, and monitoring infrastructure will be added later.
