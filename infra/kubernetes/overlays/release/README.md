# Release Overlay

This overlay deploys DevDeploy Hub with GHCR release images instead of local kind or minikube images.

It references the shared base manifests, includes generated workloads from `infra/kubernetes/generated/workloads`, and replaces:

```text
devdeploy-backend:local  -> ghcr.io/kaan-yassibas/devdeploy-backend:v1.0.0
devdeploy-frontend:local -> ghcr.io/kaan-yassibas/devdeploy-frontend:v1.0.0
```

Use this overlay after the `v1.0.0` backend and frontend images have been published to GitHub Container Registry.

Generated application workloads are kept separate from the DevDeploy Hub platform resources:

```text
Platform namespace:  devdeploy
Workload namespace:  devdeploy-workloads
Generated path:      infra/kubernetes/generated/workloads/apps/<app-name>
```

## GitOps Image Promotion

Release image tags are promoted by updating this overlay and merging the change through a pull request. CI does not deploy directly to the cluster.

Recommended flow:

```powershell
git tag v1.1.0
git push origin v1.1.0
```

Wait for the `Container Publish` workflow to publish:

```text
ghcr.io/kaan-yassibas/devdeploy-backend:v1.1.0
ghcr.io/kaan-yassibas/devdeploy-frontend:v1.1.0
```

Then run:

```text
Actions -> GitOps Promotion -> Run workflow -> image_tag = v1.1.0
```

The workflow updates this overlay and opens a PR. After merge, the `devdeploy-hub-release` Argo CD Application syncs the new image tags.

Local validation for the promotion script:

```powershell
python scripts/promote-release-images.py v1.1.0
kubectl kustomize infra/kubernetes/overlays/release
```

If you run the script locally only as a test, restore the overlay tag before committing unless you intend to promote that release.

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
