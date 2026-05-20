# Dev Overlay

This overlay references the base local Kubernetes manifests with a small CORS patch for local testing.

It keeps the ingress setup and also allows `http://localhost:5173` as a backend CORS origin for the port-forward first-test path.

Apply from the repository root:

```powershell
kubectl apply -k infra/kubernetes/overlays/dev
```

Port-forward first-test path:

```powershell
kubectl port-forward -n devdeploy svc/devdeploy-backend 8000:8000
kubectl port-forward -n devdeploy svc/devdeploy-frontend 5173:80
```

Then open:

```text
Frontend: http://localhost:5173
Backend:  http://localhost:8000/api/v1/health
```
