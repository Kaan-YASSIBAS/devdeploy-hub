# Release Overlay

This overlay deploys DevDeploy Hub with GHCR release images instead of local kind or minikube images.

It references the shared base manifests and replaces:

```text
devdeploy-backend:local  -> ghcr.io/kaan-yassibas/devdeploy-backend:v1.0.0
devdeploy-frontend:local -> ghcr.io/kaan-yassibas/devdeploy-frontend:v1.0.0
```

Use this overlay after the `v1.0.0` backend and frontend images have been published to GitHub Container Registry.

## Render

```powershell
kubectl kustomize infra/kubernetes/overlays/release
```

## Apply

```powershell
kubectl apply -k infra/kubernetes/overlays/release
```

## Port-Forward Test

The current frontend release image is built with:

```text
VITE_API_BASE_URL=http://localhost:8000/api/v1
```

Run these in separate terminals:

```powershell
kubectl port-forward -n devdeploy svc/devdeploy-backend 8000:8000
kubectl port-forward -n devdeploy svc/devdeploy-frontend 5173:80
```

Then open:

```text
Frontend: http://localhost:5173
Backend:  http://localhost:8000/api/v1/health
```

## Notes

- The dev overlay still uses local images.
- The release overlay is intended for registry-based GitOps testing.
- Do not run the dev and release Argo CD Applications against the same namespace at the same time unless you are intentionally testing resource ownership overlap.
