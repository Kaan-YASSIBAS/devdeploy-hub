# Backend Bootstrap Launcher Design

## 1. Purpose

Phase 2D.9 defines the Launcher-side design for bootstrapping the DevDeploy backend into `devdeploy-mgmt`.

This phase consolidates the previously documented runtime, manifest, image, and Secret strategies into explicit future Launcher modes. It does not implement those modes, deploy the backend, create Secrets, build images, or mutate Kubernetes resources.

## 2. Relationship to Previous Phases

Backend bootstrap design has been developed in focused milestones:

- Phase 2D.4 defines backend runtime and configuration requirements.
- Phase 2D.5 defines the backend manifest layout and ownership model.
- Phase 2D.6 adds backend platform manifests under `platform/management/backend`.
- Phase 2D.7 defines local image build and kind load behavior.
- Phase 2D.8 defines backend runtime Secret creation, preservation, and verification.
- Phase 2D.9 combines those decisions into a coherent Launcher mode design.

The future implementation should preserve these boundaries rather than introducing one broad, implicit bootstrap command.

## 3. Scope and Non-Goals

Phase 2D.9:

- Documents future Launcher modes.
- Defines mode responsibilities and ordering.
- Defines verification and idempotency behavior.
- Defines status and sanitization contracts.
- Preserves management/workload cluster separation.

Phase 2D.9 does not:

- Implement Launcher code.
- Deploy the backend.
- Build or load container images.
- Create or update Kubernetes Secrets.
- Apply Kubernetes manifests.
- Install the frontend.
- Install Argo CD.
- Touch `devdeploy-workload`.
- Change the default read-only Launcher behavior.

## 4. Future Launcher Modes

### `-BuildManagementBackendImage`

Builds `devdeploy-backend:local` from `./backend` and verifies the image exists in the host Docker daemon. It does not interact with Kubernetes.

### `-LoadManagementBackendImage`

Loads the existing local image into `devdeploy-mgmt`. It does not apply Kubernetes resources or deploy the backend.

### `-EnsureManagementBackendSecret`

Creates or reconciles `devdeploy-backend-secret` in `devdeploy-mgmt/devdeploy` while preserving existing valid credentials and keeping values out of logs/status.

### `-VerifyManagementBackendSecret`

Performs read-only structural and semantic verification of the backend Secret without printing values.

### `-BootstrapManagementBackend`

Validates prerequisites, reconciles backend platform manifests in `devdeploy-mgmt`, waits for availability, and verifies health. This is the only future mode in this group allowed to apply backend platform manifests.

### `-VerifyManagementBackend`

Performs read-only verification of backend Deployment, Service, Ingress, image reference, and health.

All modes must remain opt-in. Supplying no explicit mutation mode must preserve the current read-only preflight behavior.

## 5. Mode Responsibilities

### Build Management Backend Image

`-BuildManagementBackendImage` should:

1. Verify Docker CLI availability.
2. Verify the Docker daemon is responsive.
3. Verify `backend/Dockerfile` exists.
4. Verify `backend/requirements.txt` and `backend/constraints.txt` exist.
5. Build `devdeploy-backend:local` from context `./backend`.
6. Verify the image exists locally.
7. Write sanitized build status.

It must not create clusters, load images into kind, deploy manifests, or apply Kubernetes resources.

### Load Management Backend Image

`-LoadManagementBackendImage` should:

1. Verify kind CLI availability.
2. Verify `devdeploy-mgmt` exists.
3. Verify the management API is reachable and a node is Ready.
4. Verify `devdeploy-backend:local` exists locally.
5. Load the image into `devdeploy-mgmt`.
6. Verify image availability on the management node where practical.
7. Write sanitized load status.

It must not apply Kubernetes resources or interact with `devdeploy-workload`.

### Ensure Management Backend Secret

`-EnsureManagementBackendSecret` should:

1. Verify `devdeploy-mgmt` exists, is reachable, and is Ready.
2. Verify namespace `devdeploy` exists.
3. Verify the PostgreSQL Helm release and runtime Secret exist.
4. Discover the PostgreSQL password key from actual release metadata.
5. Read the PostgreSQL password without printing it.
6. Construct the expected `DATABASE_URL` in memory.
7. Generate a secure `JWT_SECRET_KEY` when missing.
8. Preserve valid existing JWT and GitHub workflow token values.
9. Create or update `devdeploy-backend-secret` predictably.
10. Write sanitized status only.

It must not deploy backend manifests, build/load images, or create workload resources.

### Verify Management Backend Secret

`-VerifyManagementBackendSecret` should:

1. Verify `devdeploy-backend-secret` exists.
2. Verify required keys exist.
3. Verify `DATABASE_URL` targets the expected host and database without printing its password.
4. Verify `JWT_SECRET_KEY` meets the minimum length without printing it.
5. Report `GITHUB_WORKFLOW_TOKEN` as present, empty, or missing without printing it.
6. Write sanitized verification status.

This mode must be read-only.

### Bootstrap Management Backend

`-BootstrapManagementBackend` should:

1. Verify `devdeploy-mgmt` is Ready.
2. Verify namespace `devdeploy` exists.
3. Verify management ingress-nginx is Ready.
4. Verify PostgreSQL is Ready.
5. Ensure or verify `devdeploy-backend-secret`.
6. Verify `devdeploy-backend:local` is available locally and loaded into `devdeploy-mgmt`, or provide explicit guidance to run build/load modes.
7. Render and validate `platform/management/backend` with Kustomize.
8. Apply only the backend ConfigMap, Deployment, Service, and Ingress through this explicit mode.
9. Confirm `secret.example.yaml` is not rendered or applied.
10. Wait for Deployment `devdeploy-backend` to become Available.
11. Verify Service `devdeploy-backend` exists.
12. Verify Ingress `devdeploy-backend` exists.
13. Check `/api/v1/health` through the cluster Service or management ingress.
14. Write sanitized backend status.

It must not create user workloads, install frontend/Argo CD, or mutate `devdeploy-workload`.

### Verify Management Backend

`-VerifyManagementBackend` should:

1. Render backend Kustomize resources for structural comparison where useful.
2. Verify backend resources exist in namespace `devdeploy`.
3. Verify the Deployment is Available.
4. Verify the Service and Ingress exist and target expected ports/paths.
5. Verify the running image reference is expected.
6. Verify `/api/v1/health` is reachable where possible.
7. Report metrics endpoint configuration without exposing it externally unnecessarily.
8. Write sanitized verification status.

This mode must not apply, patch, restart, scale, or delete resources.

## 6. Recommended Execution Order

Recommended future flow:

1. `-BootstrapManagementPostgres`
2. `-BuildManagementBackendImage`
3. `-LoadManagementBackendImage`
4. `-EnsureManagementBackendSecret`
5. `-BootstrapManagementBackend`
6. `-VerifyManagementBackend`

Management ingress should already be Ready before backend ingress verification.

`-BootstrapManagementBackend` may eventually orchestrate prerequisite verification and call narrowly scoped helpers. It must not hide unexpected mutation. If a prerequisite requires an explicit user decision, the mode should fail with the exact next command rather than silently creating unrelated infrastructure.

## 7. Safety Boundaries

- All backend bootstrap mutation targets only `devdeploy-mgmt`.
- No backend bootstrap mode installs anything into `devdeploy-workload`.
- No backend bootstrap mode applies normal user workload manifests.
- No backend bootstrap mode performs `kubectl delete`.
- Verify modes remain read-only.
- Secret values are never logged or written to `launcher-status.json`.
- GitHub Actions do not receive cluster credentials and do not deploy backend resources.
- Argo CD does not own management backend bootstrap resources in V1.
- The backend does not apply or manage its own Kubernetes resources.
- Failed steps do not trigger automatic destructive cleanup.

Normal user workload deployment remains:

```text
UI -> Backend -> GitHub/GitOps Repository -> Argo CD -> devdeploy-workload
```

## 8. Status Contract Proposal

Future `launcher-status.json` should retain separate component objects for runtime, image, and Secret state.

### Backend

```json
{
  "installed": true,
  "ready": true,
  "namespace": "devdeploy",
  "deployment": "devdeploy-backend",
  "service": "devdeploy-backend",
  "ingress": "devdeploy-backend",
  "image": "devdeploy-backend:local",
  "health_endpoint": "/api/v1/health",
  "metrics_endpoint": "/metrics",
  "status": "ready",
  "message": "DevDeploy backend is installed and healthy.",
  "checked_at": "2026-01-01T00:00:00Z"
}
```

### Backend Image

```json
{
  "image": "devdeploy-backend:local",
  "local_image_present": true,
  "loaded_to_management_cluster": true,
  "target_cluster": "devdeploy-mgmt",
  "status": "ready",
  "message": "Backend image is available locally and loaded into devdeploy-mgmt.",
  "checked_at": "2026-01-01T00:00:00Z"
}
```

### Backend Secret

```json
{
  "exists": true,
  "ready": true,
  "namespace": "devdeploy",
  "secret_name": "devdeploy-backend-secret",
  "required_keys_present": true,
  "database_url_configured": true,
  "jwt_secret_configured": true,
  "github_workflow_token_configured": false,
  "status": "ready",
  "message": "Backend runtime Secret exists and required configuration is valid.",
  "checked_at": "2026-01-01T00:00:00Z"
}
```

These objects should live under:

```text
platform_bootstrap.components.backend
platform_bootstrap.components.backend_image
platform_bootstrap.components.backend_secret
```

Status must not contain actual Secret values, tokens, base64 data, or an unmasked `DATABASE_URL`.

## 9. Sanitization Rules

- Never print a raw `DATABASE_URL` containing a password.
- Never print `JWT_SECRET_KEY`.
- Never print `GITHUB_WORKFLOW_TOKEN`.
- Never include Kubernetes Secret data in `launcher-status.json`.
- Never log raw command arguments when they may contain credentials.
- Do not include kubectl Secret output in exceptions or diagnostics.
- Logs should contain only structural status, resource names, stage names, and actionable messages.

When a database target must be shown, use:

```text
postgresql://devdeploy:***@devdeploy-postgres-postgresql.devdeploy.svc.cluster.local:5432/devdeploy
```

## 10. Idempotency Rules

- Re-running build mode may rebuild the same `devdeploy-backend:local` tag.
- Re-running load mode may reload the same image into kind.
- Re-running ensure Secret mode preserves existing valid JWT and GitHub token values unless an explicit rotation/change mode is introduced.
- Re-running backend bootstrap reconciles deterministic manifests and waits for the Ready state.
- Re-running backend bootstrap must not delete resources as a shortcut to reconciliation.
- Re-running verify modes remains read-only.
- Existing healthy state should produce `ok`/`ready`, not an error requiring recreation.

## 11. Failure Handling

| Failure | Expected behavior |
| --- | --- |
| Docker missing | Fail build mode and instruct the user to install/start Docker. |
| Docker daemon unavailable | Fail build mode with Docker Desktop readiness guidance. |
| kind missing | Fail load mode and identify the missing CLI. |
| `devdeploy-mgmt` missing | Fail and suggest `-CreateManagementCluster`. |
| Namespace `devdeploy` missing | Fail and suggest the management PostgreSQL/namespace bootstrap step. |
| PostgreSQL missing or not Ready | Fail backend bootstrap and suggest `-BootstrapManagementPostgres`. |
| PostgreSQL Secret missing | Fail ensure Secret mode with Helm release verification guidance. |
| Backend image missing | Fail load/bootstrap and suggest `-BuildManagementBackendImage`. |
| Backend Secret missing/malformed | Fail bootstrap and suggest ensure/verify Secret mode. |
| Kustomize render fails | Stop before apply and report the affected manifest path. |
| Apply fails | Record failed status; do not delete resources automatically. |
| Deployment unavailable | Record degraded/failed status with rollout guidance. |
| Health check fails | Record degraded status and identify the safe endpoint checked. |

Every failure should stop the requested mode at a safe boundary and produce a concise sanitized message.

## 12. Implementation Notes for Future Code

- Prefer small helper functions for Docker, kind, kubectl, Kustomize, health checks, and status writing.
- Reuse the existing sanitized process execution conventions.
- Avoid printing full command arguments when credentials may be present.
- Keep Secret handling isolated from general command helpers.
- Reuse the existing cluster-aware preflight and top-level status structure.
- Preserve stable arrays and Windows PowerShell 5.1 compatibility.
- Keep every mutation mode opt-in.
- Keep default Launcher behavior read-only.
- Validate Kustomize output before apply.
- Confirm the selected context explicitly on every Kubernetes operation.
- Keep management backend operations separate from workload GitOps operations.

## 13. V1 Limitations

- Phase 2D.9 does not implement Launcher modes.
- The local image tag remains `devdeploy-backend:local`.
- V1 does not require an external image registry.
- Automatic database migrations are not designed yet.
- `/api/v1/ready` is not implemented yet.
- Management backend resources are not owned by Argo CD in V1.
- Secret rotation requires a future explicit design.
- Backend bootstrap targets one local management cluster and one backend replica.

## 14. Definition of Done

Phase 2D.9 is complete when:

- Backend Launcher modes are documented.
- Responsibilities for each mode are documented.
- Recommended execution order is documented.
- Safety and cluster ownership boundaries are documented.
- Backend, image, and Secret status contracts are documented.
- Sanitization rules are documented.
- Idempotency behavior is documented.
- Failure behavior is documented.
- Future implementation guidance is documented.
- No Launcher code or cluster mutation is added.

## 15. Related Documents

- [Backend Bootstrap Preparation](./backend-bootstrap-preparation.md)
- [Backend Bootstrap Manifest Strategy](./backend-bootstrap-manifest-strategy.md)
- [Backend Image Build and Load Strategy](./backend-image-build-load-strategy.md)
- [Backend Runtime Secret Strategy](./backend-secret-runtime-strategy.md)
- [Management Platform Bootstrap Plan](./management-platform-bootstrap-plan.md)
- [Bootstrapper / Launcher Design](./bootstrapper-launcher-design.md)
- [Security Boundaries and Credentials Model](./security-credentials-boundaries.md)
- [Phase 2 Implementation Roadmap](./phase-2-implementation-roadmap.md)
