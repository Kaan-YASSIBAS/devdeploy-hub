# Backend Bootstrap Preparation

## 1. Purpose

This document defines the preparation plan for deploying the DevDeploy backend into `devdeploy-mgmt` during a later Phase 2D implementation step.

Phase 2D.4 does not deploy the backend. It documents the runtime contract, configuration boundaries, database connection strategy, local image workflow, Kubernetes placement, and future Launcher responsibilities needed for a controlled implementation.

Normal user workload deployment remains GitOps-only:

```text
UI -> Backend -> GitHub/GitOps Repository -> Argo CD -> devdeploy-workload
```

The backend platform component belongs in `devdeploy-mgmt`. No backend platform component should be installed in `devdeploy-workload`.

## 2. Current Backend Runtime Contract

The current backend runtime contract is:

- Source directory: `backend/`
- Container base: `python:3.12-alpine`
- Working directory: `/app`
- Container user: non-root UID `10001`
- Container port: `8000`
- FastAPI application entrypoint: `app.main:app`
- API prefix: `/api/v1`
- Health endpoint: `GET /api/v1/health`
- Metrics endpoint: `GET /metrics`

The current container command is:

```text
uvicorn app.main:app --host 0.0.0.0 --port 8000
```

The health endpoint currently returns:

```json
{
  "status": "ok",
  "service": "devdeploy-backend"
}
```

Required environment variables include:

- `DATABASE_URL`
- `JWT_SECRET_KEY`, with a minimum length of 32 characters

SQLAlchemy creates its engine from `settings.database_url` and enables `pool_pre_ping`:

```text
create_engine(settings.database_url, pool_pre_ping=True)
```

## 3. Target Kubernetes Placement

The future backend placement is:

| Field | Value |
| --- | --- |
| Cluster | `devdeploy-mgmt` |
| Namespace | `devdeploy` |
| Deployment | `devdeploy-backend` |
| Service | `devdeploy-backend` |
| Service type | `ClusterIP` |
| Container port | `8000` |

The backend is a DevDeploy platform component. It must not be installed into `devdeploy-workload`, which is reserved for user applications.

## 4. PostgreSQL Connection Strategy

PostgreSQL is installed in namespace `devdeploy` with the following service endpoint:

```text
devdeploy-postgres-postgresql.devdeploy.svc.cluster.local:5432
```

The target application database settings are:

- Database: `devdeploy`
- Username: `devdeploy`

The Kubernetes `DATABASE_URL` shape is:

```text
postgresql://devdeploy:<POSTGRES_PASSWORD>@devdeploy-postgres-postgresql.devdeploy.svc.cluster.local:5432/devdeploy
```

The PostgreSQL password must come from a Kubernetes Secret or a controlled local secret-generation step. The password must not be:

- Committed to Git.
- Printed to Launcher logs.
- Written to `launcher-status.json`.
- Returned through setup/status API responses.

The future bootstrap implementation should verify that the PostgreSQL release and service are Ready before creating or starting the backend Deployment.

## 5. ConfigMap and Secret Strategy

V1 should separate non-sensitive configuration from credentials.

### ConfigMap Candidate

Proposed non-sensitive values:

```text
ENVIRONMENT=development
JWT_ALGORITHM=HS256
ACCESS_TOKEN_EXPIRE_MINUTES=60
FRONTEND_ORIGIN=http://localhost:8080
KUBERNETES_IN_CLUSTER=true
PROMETHEUS_BASE_URL=http://kube-prometheus-stack-prometheus.monitoring.svc.cluster.local:9090
LOKI_BASE_URL=http://loki-gateway.monitoring.svc.cluster.local
GRAFANA_BASE_URL=
GITOPS_ENABLED=false
GITHUB_OWNER=Kaan-YASSIBAS
GITHUB_REPO=devdeploy-hub
GITOPS_WORKFLOW_FILE=gitops-workload-request.yml
GITOPS_DELETE_WORKFLOW_FILE=gitops-workload-delete.yml
GITOPS_TARGET_REF=main
```

These values may be stored in a ConfigMap because they do not contain credentials. Empty or unavailable integration URLs must result in explicit unavailable or not-configured states rather than fake connectivity.

### Secret Candidate

Proposed sensitive values:

- `DATABASE_URL`
- `JWT_SECRET_KEY`
- `GITHUB_WORKFLOW_TOKEN`

`GITHUB_WORKFLOW_TOKEN` may remain unset until GitOps and Argo CD integration are enabled. Its absence must not prevent the backend from starting; GitOps automation endpoints should fail gracefully with a configuration error when the token is required.

Secret values must not appear in Git, Launcher logs, `launcher-status.json`, or frontend storage.

## 6. Health, Readiness, and Metrics

The existing endpoint can serve as the initial liveness and readiness probe:

```text
GET /api/v1/health
```

Initial probe behavior may use:

- Liveness path: `/api/v1/health`
- Readiness path: `/api/v1/health`
- Container port: `8000`

Prometheus-compatible metrics are exposed at:

```text
GET /metrics
```

A future improvement should add a DB-aware readiness endpoint:

```text
GET /api/v1/ready
```

That endpoint should verify critical dependencies such as PostgreSQL without exposing connection details. Phase 2D.4 does not require or implement `/api/v1/ready`.

## 7. Local Image Build and kind Load Strategy

V1 should use a host-built local image rather than requiring an external registry.

Proposed commands:

```powershell
docker build -t devdeploy-backend:local ./backend
kind load docker-image devdeploy-backend:local --name devdeploy-mgmt
```

The future Deployment should use:

```yaml
image: devdeploy-backend:local
imagePullPolicy: IfNotPresent
```

This approach keeps the local-first setup self-contained:

- No registry credentials are required.
- Local development does not depend on GHCR availability.
- The Launcher can verify that the image exists locally before loading it.
- `IfNotPresent` allows the kind node to use the loaded image instead of trying to pull it from an external registry.

The Launcher should fail with an actionable message if the image build or kind image load step fails. It must not silently fall back to an unrelated remote image.

## 8. Service and Ingress Plan

The future backend Service should be a `ClusterIP` Service on port `8000`.

Internal cluster address:

```text
http://devdeploy-backend.devdeploy.svc.cluster.local:8000
```

Management ingress-nginx already exposes the management cluster through host HTTP port `8080`. The proposed external API route is:

```text
http://localhost:8080/api/v1/...
```

The ingress can route `/api` or `/api/v1` to Service `devdeploy-backend` on port `8000`. The recommended V1 path is `/api`, preserving the backend's existing `/api/v1` prefix without application-level URL rewriting.

The future ingress implementation should verify path handling with at least:

- `/api/v1/health`
- One authenticated `/api/v1` endpoint.
- `/metrics` only if metrics exposure through ingress is intentionally allowed.

Metrics may remain cluster-internal and be scraped through the Service rather than exposed publicly.

## 9. Future Launcher Modes

Future explicit backend bootstrap mode:

```powershell
.\scripts\launcher\devdeploy-launcher.ps1 -BootstrapManagementBackend
```

This mode should eventually:

1. Verify `devdeploy-mgmt` exists and is Ready.
2. Verify namespace `devdeploy` exists.
3. Verify PostgreSQL is installed and Ready.
4. Verify management ingress-nginx status without making it a hidden host dependency.
5. Verify the backend image is locally available or build it through an explicit, documented step.
6. Load `devdeploy-backend:local` into `devdeploy-mgmt`.
7. Create or verify the backend ConfigMap.
8. Create or verify backend Secrets without exposing their values.
9. Create or verify Deployment `devdeploy-backend`.
10. Create or verify Service `devdeploy-backend`.
11. Create or verify the management ingress route.
12. Wait for rollout and health verification.
13. Update `launcher-status.json` with backend component status.

The mode must be explicit and idempotent. It must not install anything into `devdeploy-workload` or deploy normal user applications.

Future read-only verification mode:

```powershell
.\scripts\launcher\devdeploy-launcher.ps1 -VerifyManagementBackend
```

The verification mode should inspect existing resources and health only. It should not build images, load images, create resources, or mutate the cluster.

## 10. Proposed Status Contract

Future `launcher-status.json` should extend `platform_bootstrap.components.backend` without including secret values:

```json
{
  "platform_bootstrap": {
    "status": "partial",
    "components": {
      "backend": {
        "installed": true,
        "ready": true,
        "namespace": "devdeploy",
        "deployment": "devdeploy-backend",
        "service": "devdeploy-backend",
        "image": "devdeploy-backend:local",
        "health_endpoint": "/api/v1/health",
        "metrics_endpoint": "/metrics",
        "ingress_path": "/api",
        "status": "ready",
        "message": "DevDeploy backend is installed and healthy."
      }
    }
  }
}
```

Allowed backend status values should remain consistent with other platform components:

- `not_started`
- `ready`
- `degraded`
- `failed`
- `unknown`

Status details must not include:

- Database passwords.
- JWT secret values.
- GitHub tokens.
- Full `DATABASE_URL` values.
- Kubernetes Secret contents.

## 11. V1 Limitations

- The backend is not deployed in Phase 2D.4.
- Database migrations and their bootstrap ordering are not finalized in this phase.
- `/api/v1/ready` is not implemented yet.
- GitOps automation is not enabled yet.
- Argo CD is not installed yet.
- The frontend is not installed yet.
- An external image registry is not required for the V1 local-first setup.
- V1 uses one local backend replica unless a later implementation explicitly changes the design.
- Production-grade secret management remains a future enhancement.

## 12. Definition of Done

Phase 2D.4 is complete when:

- The backend runtime contract is documented.
- The PostgreSQL connection strategy is documented.
- The ConfigMap and Secret split is documented.
- The local image build and kind load strategy is documented.
- The Service and ingress strategy is documented.
- Future Launcher backend bootstrap and verification modes are documented.
- The proposed backend status contract is documented.
- No backend deployment or installation behavior is added.
- No backend, frontend, Launcher, Kubernetes manifest, or workflow code is modified.

## 13. Related Documents

- [Multi-Cluster Redesign](./multi-cluster-redesign.md)
- [Bootstrapper / Launcher Design](./bootstrapper-launcher-design.md)
- [Management Platform Bootstrap Plan](./management-platform-bootstrap-plan.md)
- [Localhost Networking and Port Strategy](./localhost-networking-port-strategy.md)
- [Security Boundaries and Credentials Model](./security-credentials-boundaries.md)
- [Phase 2 Implementation Roadmap](./phase-2-implementation-roadmap.md)
