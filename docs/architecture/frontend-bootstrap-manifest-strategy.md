# Frontend Bootstrap Manifest Strategy

## 1. Purpose

Phase 2E.2 defines the Kubernetes manifest layout, routing model, runtime boundaries, and future Launcher contract for the DevDeploy frontend in the management cluster.

This phase is documentation-only. It does not create manifests, modify frontend or Launcher code, build an image, or mutate Kubernetes resources.

## 2. Target Placement

The frontend is a DevDeploy management component with the following target:

| Field | Value |
| --- | --- |
| Cluster | `devdeploy-mgmt` |
| Context | `kind-devdeploy-mgmt` |
| Namespace | `devdeploy` |
| Component | `frontend` |
| Deployment | `devdeploy-frontend` |
| Service | `devdeploy-frontend` |
| Ingress | `devdeploy-frontend` |

Frontend bootstrap must never create or modify resources in `devdeploy-workload`.

## 3. Manifest Directory Layout

Future frontend platform manifests should live under:

```text
platform/management/frontend/
  kustomization.yaml
  deployment.yaml
  service.yaml
  ingress.yaml
```

`configmap.yaml` should be added only if a concrete Nginx runtime configuration need appears. It is not required for the initial V1 design.

No Kubernetes Secret is expected for frontend V1. There should be no `secret.yaml`, `secret.example.yaml`, or Secret reference in the frontend Deployment.

The future `kustomization.yaml` should list only the resources that exist and should apply namespace `devdeploy` deterministically.

## 4. Image Contract

The frontend image contract is:

| Field | Value |
| --- | --- |
| Image | `devdeploy-frontend:local` |
| Pull policy | `IfNotPresent` |
| Docker context | `./frontend` |
| Dockerfile | `./frontend/Dockerfile` |
| Build-time API URL | `VITE_API_BASE_URL=/api/v1` |
| Runtime HTTP port | `8080` |

The management image should be built with an explicit build argument:

```powershell
docker build `
  --build-arg VITE_API_BASE_URL=/api/v1 `
  -t devdeploy-frontend:local `
  ./frontend
```

The image is loaded only into `devdeploy-mgmt` in V1. Frontend manifests should not reference an external registry or `latest` tag.

## 5. Runtime Configuration Strategy

Vite replaces `VITE_*` values during the build. The resulting Nginx container serves static files and does not reevaluate `VITE_API_BASE_URL` from container environment variables.

For V1:

- Treat `VITE_API_BASE_URL` as build-time configuration.
- Build the management image with `/api/v1`.
- Do not add `VITE_API_BASE_URL` to a Kubernetes ConfigMap or Deployment environment block.
- Keep the existing Nginx configuration inside the image.
- Do not add runtime JavaScript configuration or Nginx template processing.

A ConfigMap may be introduced later only for actual runtime Nginx configuration, such as headers or routing behavior that must vary without rebuilding the image. It must not contain credentials.

## 6. Deployment Strategy

The future Deployment should use:

- Name: `devdeploy-frontend`.
- Namespace: `devdeploy`.
- Replicas: `1` for local V1.
- Image: `devdeploy-frontend:local`.
- `imagePullPolicy: IfNotPresent`.
- Named container port `http` on `8080`.
- Labels including:
  - `app.kubernetes.io/name: devdeploy-frontend`
  - `app.kubernetes.io/component: frontend`
  - `app.kubernetes.io/part-of: devdeploy-hub`
  - `app.kubernetes.io/managed-by: devdeploy-launcher`

Readiness and liveness probes should use HTTP GET `/` on the named `http` port. A successful static root response is sufficient for the V1 container health contract.

Recommended resources:

```yaml
resources:
  requests:
    cpu: 50m
    memory: 64Mi
  limits:
    cpu: 250m
    memory: 256Mi
```

Recommended pod and container security settings:

- `runAsNonRoot: true`.
- `runAsUser: 101` and `runAsGroup: 101`, consistent with the runtime image.
- `seccompProfile.type: RuntimeDefault`.
- `allowPrivilegeEscalation: false`.
- Drop all Linux capabilities.
- `readOnlyRootFilesystem: true`.

Nginx needs limited writable paths even with a read-only root filesystem. Use dedicated `emptyDir` volumes for:

- `/tmp`
- `/var/cache/nginx`
- `/var/run`

Do not mount a ServiceAccount token unless a future requirement explicitly needs Kubernetes API access. The frontend container itself should have no Kubernetes API responsibilities.

## 7. Service Strategy

The future Service should use:

- Name: `devdeploy-frontend`.
- Type: `ClusterIP`.
- Service port: `80`.
- Target port: named container port `http`, resolving to `8080`.

Service port `80` is preferred over exposing `8080` at the Service boundary because it presents a conventional HTTP interface to ingress-nginx while preserving the unprivileged container port internally.

Proposed shape:

```yaml
ports:
  - name: http
    port: 80
    targetPort: http
    protocol: TCP
    appProtocol: http
```

## 8. Ingress and Routing Strategy

The future frontend Ingress should use:

- Name: `devdeploy-frontend`.
- `ingressClassName: nginx`.
- Path: `/`.
- `pathType: Prefix`.
- Backend Service: `devdeploy-frontend` port `80`.
- No TLS for V1.

The existing backend Ingress owns `/api`. The frontend bundle should call the relative `/api/v1` base URL, so browser traffic follows this routing model:

```text
http://devdeploy.localhost:8080/         -> frontend Service
http://devdeploy.localhost:8080/api/v1/* -> backend Service
```

### V1 Host Decision

Use a hostless frontend Ingress for V1, matching the existing hostless backend Ingress.

This is the cleaner initial choice because:

- Frontend and backend rules accept the same Host header.
- `/api` remains more specific than the frontend `/` catch-all.
- Both `devdeploy.localhost:8080` and direct `localhost:8080` can work.
- No backend manifest change is required during frontend bootstrap.
- The browser has no dependency on `localhost:8000`.

If host-specific routing is introduced later, both frontend `/` and backend `/api` rules should be changed together to `devdeploy.localhost`. A host-specific frontend combined with a hostless backend is technically workable, but it creates an unnecessary mixed ownership model and is not recommended as the steady state.

## 9. Status Contract

The Launcher should report frontend deployment state under:

```text
platform_bootstrap.components.frontend
```

Proposed shape:

```json
{
  "deployed": true,
  "ready": true,
  "namespace": "devdeploy",
  "deployment": "devdeploy-frontend",
  "service": "devdeploy-frontend",
  "ingress": "devdeploy-frontend",
  "image": "devdeploy-frontend:local",
  "manifests_path": "platform/management/frontend",
  "rollout_succeeded": true,
  "page_check_succeeded": true,
  "status": "ready",
  "message": "DevDeploy frontend is deployed and reachable in devdeploy-mgmt.",
  "checked_at": "2026-01-01T00:00:00Z"
}
```

No Secret values, browser tokens, HTML response bodies, or noisy command output should be written to Launcher status or logs.

After frontend readiness, `platform_bootstrap.status` remains `partial` until Argo CD is installed and verified.

## 10. Build, Load, Bootstrap, and Verify Flow

Future explicit Launcher modes should be implemented in this order:

1. `-BuildManagementFrontendImage`
2. `-LoadManagementFrontendImage`
3. `-BootstrapManagementFrontend`
4. `-VerifyManagementFrontend`

### Build Mode

The build mode verifies Docker, `frontend/Dockerfile`, `package.json`, `package-lock.json`, and `nginx.conf`; builds with `VITE_API_BASE_URL=/api/v1`; and verifies `devdeploy-frontend:local` exists.

### Load Mode

The load mode verifies the local image and a Ready `devdeploy-mgmt`, then runs the equivalent of:

```powershell
kind load docker-image devdeploy-frontend:local --name devdeploy-mgmt
```

### Bootstrap Mode

The bootstrap mode verifies management ingress and namespace readiness, renders `platform/management/frontend`, applies only that directory, waits for Deployment availability, verifies Service and Ingress, and performs a page check.

### Verify Mode

The verify mode remains read-only. It checks Deployment replicas and image, Running/Ready Pods, Service ports, Ingress routing, and an HTTP page response. Any temporary port-forward must be terminated in a `finally` path.

## 11. Safety Boundaries

- Do not place credentials or Kubernetes Secrets in the frontend image or manifests.
- Do not expose `DATABASE_URL`, database credentials, or JWT signing keys.
- Do not expose `GITHUB_WORKFLOW_TOKEN` or other GitHub credentials.
- Do not store cluster credentials or kubeconfig in frontend assets.
- The frontend communicates only with the backend through `/api`.
- The backend remains the authentication, data, GitOps, and Kubernetes boundary.
- The frontend never connects directly to PostgreSQL or the Kubernetes API.
- Only public values may use the `VITE_` prefix because they are embedded into browser assets.
- Frontend image and bootstrap operations target only `devdeploy-mgmt`.
- No frontend mode mutates `devdeploy-workload`.

## 12. V1 Limitations

- Local HTTP only.
- No TLS automation.
- Hostless management ingress.
- Local image only; no registry publication requirement.
- One frontend replica.
- No CDN.
- No production-grade cache invalidation beyond Vite's hashed assets and current Nginx cache headers.
- No runtime environment injection.
- No Argo CD ownership for management frontend resources.

## 13. Definition of Done for Future Implementation

Frontend manifest and Launcher implementation is complete when:

- `platform/management/frontend` contains deterministic Deployment, Service, Ingress, and Kustomization resources.
- `kubectl kustomize platform/management/frontend` succeeds.
- No frontend Secret or example Secret is needed.
- `devdeploy-frontend:local` builds with `VITE_API_BASE_URL=/api/v1`.
- The image loads only into `devdeploy-mgmt`.
- Deployment `devdeploy-frontend` becomes Available.
- Service `devdeploy-frontend` exposes port `80` to target port `8080`.
- Ingress `devdeploy-frontend` routes `/` through ingress-nginx.
- The frontend page check succeeds.
- `http://devdeploy.localhost:8080/api/v1/health` reaches the backend through ingress.
- `platform_bootstrap.components.frontend.status` is `ready`.
- `platform_bootstrap.status` remains `partial` until Argo CD is installed.
- No resource in `devdeploy-workload` is created or changed.

## 14. Related Documents

- [Frontend Bootstrap Preparation](./frontend-bootstrap-preparation.md)
- [Management Platform Bootstrap Plan](./management-platform-bootstrap-plan.md)
- [Localhost Networking and Port Strategy](./localhost-networking-port-strategy.md)
- [Security Boundaries and Credentials Model](./security-credentials-boundaries.md)
- [Phase 2 Implementation Roadmap](./phase-2-implementation-roadmap.md)
