# Frontend Bootstrap Preparation

## 1. Purpose

Phase 2E.1 prepares the DevDeploy frontend for deployment into the local management cluster. It records the current frontend build and API behavior, defines the intended Kubernetes resources and Launcher modes, and establishes the status and security contracts for later implementation.

This phase is documentation-only. It does not add frontend manifests, modify frontend code, build or load an image, update the Launcher, or mutate either Kubernetes cluster.

## 2. Current Frontend Findings

The frontend is a React 18 and TypeScript application built with Vite. The relevant project files are:

- `frontend/package.json`: build, lint, development, and preview scripts.
- `frontend/package-lock.json`: npm lockfile used by `npm ci`.
- `frontend/vite.config.ts`: React plugin, package aliases, and production chunk grouping.
- `frontend/src/api/client.ts`: shared Axios client and bearer-token handling.
- `frontend/src/vite-env.d.ts`: `VITE_API_BASE_URL` typing.
- `frontend/Dockerfile`: multi-stage Node build and unprivileged Nginx runtime.
- `frontend/nginx.conf`: static asset caching and SPA fallback.
- `frontend/.env.example`: local development API URL example.

The frontend build command is:

```text
npm run build
```

It runs TypeScript validation with `tsc --noEmit` before `vite build`.

The Docker image uses:

- Build stage: `node:22-alpine`.
- Runtime stage: `nginxinc/nginx-unprivileged:1.29-alpine`.
- Runtime user: UID `101`.
- Container HTTP port: `8080`.
- SPA fallback: unknown browser routes are served from `index.html`.

## 3. Current API Configuration

The shared Axios client currently resolves its base URL as:

```typescript
import.meta.env.VITE_API_BASE_URL ?? "http://localhost:8000/api/v1"
```

`VITE_API_BASE_URL` is a Vite build-time value. It is embedded into the static JavaScript bundle during `npm run build`; setting a Kubernetes environment variable on the running Nginx container would not change it.

The current Dockerfile also declares this build-time default:

```text
VITE_API_BASE_URL=http://localhost:8000/api/v1
```

That value is suitable for the existing local development workflow, but it is not the intended management-cluster value. The management image should be built with:

```text
VITE_API_BASE_URL=/api/v1
```

The frontend can then call the backend through the browser's current origin. No backend host, node address, or cluster-internal service name needs to be exposed to browser code.

## 4. Runtime Target

The V1 frontend target is:

| Field | Value |
| --- | --- |
| Cluster | `devdeploy-mgmt` |
| Context | `kind-devdeploy-mgmt` |
| Namespace | `devdeploy` |
| Image | `devdeploy-frontend:local` |
| Deployment | `devdeploy-frontend` |
| Service | `devdeploy-frontend` |
| Ingress | `devdeploy-frontend` |
| Container port | `8080` |
| Service port | `80` |
| Ingress path | `/` |
| Primary local URL | `http://devdeploy.localhost:8080/` |

The frontend is a management platform component. It must never be deployed to `devdeploy-workload`.

## 5. Local URL and Routing Strategy

The management kind cluster maps host port `8080` to cluster HTTP ingress. The intended browser routes are:

```text
http://devdeploy.localhost:8080/        -> devdeploy-frontend
http://devdeploy.localhost:8080/api/... -> devdeploy-backend
```

The frontend Ingress should use path `/` with `pathType: Prefix`. The existing backend Ingress uses `/api`, so ingress-nginx should route the more specific backend path before the frontend catch-all path.

The initial platform manifests should remain hostless if that is consistent with the backend manifest. A hostless rule supports both `devdeploy.localhost:8080` and direct `localhost:8080` access while the documented UI URL remains `devdeploy.localhost:8080`.

Same-origin API requests provide three practical benefits:

- Browser code does not need a cluster-specific backend URL.
- Authentication headers continue to use the existing Axios client.
- The deployed UI does not require a separate CORS origin for a browser-visible backend port.

## 6. Image Build and Load Strategy

The management frontend image contract is:

```text
Image:       devdeploy-frontend:local
Context:     ./frontend
Dockerfile:  ./frontend/Dockerfile
Build arg:   VITE_API_BASE_URL=/api/v1
Target:      devdeploy-mgmt
```

The future Launcher build command should be equivalent to:

```powershell
docker build `
  --build-arg VITE_API_BASE_URL=/api/v1 `
  -t devdeploy-frontend:local `
  ./frontend
```

The future load command should be equivalent to:

```powershell
kind load docker-image devdeploy-frontend:local --name devdeploy-mgmt
```

Proposed explicit Launcher modes:

- `-BuildManagementFrontendImage`: verify Docker and frontend build inputs, build the local image, and verify it exists.
- `-LoadManagementFrontendImage`: verify the local image and management cluster, then load only that image into `devdeploy-mgmt`.

Neither mode should deploy Kubernetes resources or interact with `devdeploy-workload`.

## 7. Proposed Kubernetes Resources

Future manifests should live under:

```text
platform/management/frontend/
```

The initial directory should contain:

```text
kustomization.yaml
deployment.yaml
service.yaml
ingress.yaml
```

### ConfigMap Decision

A ConfigMap is not required for the initial static frontend. The API base URL is compiled into the bundle, and `nginx.conf` is already included in the image.

Runtime configuration through a ConfigMap would require an explicit runtime configuration mechanism, such as a generated JavaScript configuration file or Nginx template processing. That should not be implied by setting `VITE_API_BASE_URL` on the Deployment because Vite does not read container environment variables after build time.

### Deployment

The proposed Deployment should:

- Use one replica for V1.
- Use `devdeploy-frontend:local` with `imagePullPolicy: IfNotPresent`.
- Expose named container port `http` on `8080`.
- Use HTTP readiness and liveness probes on `/`.
- Use stable DevDeploy platform labels.
- Avoid mounting Secrets.

Recommended security settings:

- Pod `runAsNonRoot: true`.
- Pod `seccompProfile.type: RuntimeDefault`.
- Container `runAsUser: 101` and `runAsGroup: 101`.
- `allowPrivilegeEscalation: false`.
- Drop all Linux capabilities.
- `readOnlyRootFilesystem: true`.
- Writable `emptyDir` mounts only for required Nginx paths such as `/tmp`, `/var/cache/nginx`, and `/var/run`.

Recommended initial resources:

```yaml
requests:
  cpu: 50m
  memory: 64Mi
limits:
  cpu: 250m
  memory: 256Mi
```

### Service

The proposed ClusterIP Service should expose port `80` and target the named container port `http` on `8080`.

### Ingress

The proposed Ingress should:

- Use `ingressClassName: nginx`.
- Route `/` with `pathType: Prefix` to `devdeploy-frontend` port `80`.
- Remain hostless for the V1 local environment if the backend remains hostless.
- Avoid redefining or proxying `/api`; the backend Ingress already owns that path.

## 8. Bootstrap and Verify Modes

### `-BootstrapManagementFrontend`

The future explicit bootstrap mode should:

1. Verify `devdeploy-mgmt`, namespace `devdeploy`, and management ingress readiness.
2. Verify `devdeploy-frontend:local` is available to the management cluster, or fail with guidance to run the build/load modes.
3. Render `platform/management/frontend` before applying it.
4. Apply only the frontend Kustomize directory to `devdeploy-mgmt`.
5. Wait for Deployment `devdeploy-frontend` to become Available.
6. Verify the Service and Ingress.
7. Perform an HTTP page check through a temporary port-forward or management ingress.
8. Write sanitized component status.

It must not install frontend resources in `devdeploy-workload` or modify backend, PostgreSQL, Secrets, or Argo CD resources.

### `-VerifyManagementFrontend`

The future verification mode should be read-only and should verify:

- Deployment existence, image, desired replicas, and available replicas.
- At least one Running and Ready frontend Pod.
- Service port `80` and target port `8080`.
- Ingress class `nginx` and path `/`.
- HTTP `200` from the page check.
- Presence of expected static application markup where practical.

The temporary port-forward process must always be cleaned up.

## 9. Frontend Status Contract

The Launcher should write frontend state under:

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

The frontend image may use a separate component object later if build/load state needs to be represented independently from deployment state.

`platform_bootstrap.status` should remain `partial` after the frontend becomes Ready because Argo CD is not installed yet.

## 10. Security Boundaries

- Do not include Kubernetes Secrets in frontend manifests.
- Do not bake GitHub credentials or workflow tokens into the image or Vite variables.
- Do not expose `DATABASE_URL`, database credentials, or JWT signing keys to browser code.
- Do not expose kubeconfig, ServiceAccount tokens, or Kubernetes API credentials.
- The frontend communicates with DevDeploy only through the backend `/api` route.
- The frontend must not communicate directly with PostgreSQL or the Kubernetes API.
- Only variables intended to be public may use the `VITE_` prefix; Vite embeds these values into client assets.
- Keep the runtime container unprivileged and its writable filesystem surface minimal.
- Keep frontend bootstrap mutation scoped to `devdeploy-mgmt` and `platform/management/frontend`.

## 11. Failure and Idempotency Rules

- Missing Docker or image inputs should fail build mode before a build starts.
- Missing local image should fail load mode with the exact build command guidance.
- Missing management cluster, namespace, or ingress should fail bootstrap before apply.
- A failed Kustomize render must prevent apply.
- Rollout or page-check failures should produce sanitized actionable status without automatic deletion.
- Re-running build may rebuild the same local tag.
- Re-running load may reload the same image into kind.
- Re-running bootstrap should reconcile deterministic manifests.
- Re-running verify must remain read-only.

## 12. V1 Limitations

- Local HTTP only; TLS automation is postponed.
- Hostless ingress is used while local host routing remains simple.
- The image is local to Docker/kind and is not published to a registry.
- Vite configuration remains build-time rather than runtime configurable.
- No production CDN or external asset hosting.
- One frontend replica.
- No Argo CD ownership for management frontend resources in V1.
- No production cache invalidation or release-channel design beyond hashed Vite assets.

## 13. Implementation Sequence

Recommended next milestones:

1. Add deterministic manifests under `platform/management/frontend`.
2. Validate Kustomize output and container security settings.
3. Implement `-BuildManagementFrontendImage` with `/api/v1` as the build argument.
4. Implement `-LoadManagementFrontendImage` targeting only `devdeploy-mgmt`.
5. Implement `-BootstrapManagementFrontend`.
6. Implement read-only `-VerifyManagementFrontend`.
7. Confirm `http://devdeploy.localhost:8080/` loads the UI and authenticated API calls use `/api/v1`.

## 14. Definition of Done

Phase 2E.1 is complete when:

- Current frontend build, Docker, Nginx, and API configuration are documented.
- The management runtime target and URL strategy are defined.
- The build-time `/api/v1` requirement is explicit.
- Proposed Kubernetes resources and security settings are defined.
- Future image, bootstrap, and verify modes are defined.
- The frontend status contract is defined.
- Security boundaries and V1 limitations are documented.
- No runtime code, manifests, images, or cluster resources are changed.

## 15. Related Documents

- [Management Platform Bootstrap Plan](./management-platform-bootstrap-plan.md)
- [Backend Bootstrap Preparation](./backend-bootstrap-preparation.md)
- [Localhost Networking and Port Strategy](./localhost-networking-port-strategy.md)
- [Security Boundaries and Credentials Model](./security-credentials-boundaries.md)
- [Phase 2 Implementation Roadmap](./phase-2-implementation-roadmap.md)
