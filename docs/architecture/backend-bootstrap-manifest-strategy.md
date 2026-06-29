# Backend Bootstrap Manifest Strategy

## 1. Purpose

This document defines the repository layout and manifest management strategy for a future DevDeploy backend deployment in `devdeploy-mgmt`.

Phase 2D.5 established where backend platform resources should live, what each resource should contain, who owns their lifecycle, and how an explicit Launcher mode should use them. Phase 2D.6 adds the first manifest set under `platform/management/backend`, but it does not deploy the backend.

## 2. Relationship to Phase 2D.4

[Backend Bootstrap Preparation](./backend-bootstrap-preparation.md) defines the backend runtime, configuration, secret, database, image, Service, ingress, and health contracts.

Phase 2D.5 translates those contracts into a repository layout and manifest management strategy. Phase 2D.6 implements that initial repository-side manifest structure without adding deployment automation.

The two documents serve different purposes:

- Phase 2D.4 defines what the backend needs to run.
- Phase 2D.5 defines how future Kubernetes resources will represent and manage those requirements.

## 3. Proposed Repository Layout

Implemented Phase 2D.6 layout:

```text
platform/
  management/
    backend/
      kustomization.yaml
      configmap.yaml
      secret.example.yaml
      deployment.yaml
      service.yaml
      ingress.yaml
```

File responsibilities:

| File | Responsibility |
| --- | --- |
| `kustomization.yaml` | Groups the backend platform resources into one deterministic Kustomize target. |
| `configmap.yaml` | Defines non-sensitive backend environment configuration. |
| `secret.example.yaml` | Documents required Secret keys using placeholders only. It is not a deployable source of real credentials. |
| `deployment.yaml` | Defines the backend container, security context, probes, ports, and environment references. |
| `service.yaml` | Exposes the backend internally through a `ClusterIP` Service on port `8000`. |
| `ingress.yaml` | Routes the management ingress path to the backend Service. |

Real Secret material must not be added to this directory or referenced through committed plaintext files.

## 4. Why `platform/management/backend`

The backend is a DevDeploy platform component, not a user workload.

The proposed path makes these boundaries explicit:

- `platform/management` contains platform resources intended for `devdeploy-mgmt`.
- `platform/management/backend` contains only the DevDeploy backend bootstrap resources.
- These resources are not generated workload application manifests.
- These resources are not intended for `devdeploy-workload`.
- These resources remain separate from `infra/kubernetes/generated/workloads`, which is owned by the user workload GitOps flow.

This separation reduces the risk of Argo CD targeting management resources as user workloads or the Launcher applying generated workload resources to the wrong cluster.

## 5. Manifest Ownership Model

V1 ownership should remain simple and explicit.

### Launcher

The host-side Launcher owns applying and verifying backend platform manifests through a future explicit mode. It may initialize platform resources in `devdeploy-mgmt`, but it must not use this authority for normal user workloads.

### Backend

The backend must not apply, patch, or delete its own Kubernetes manifests. It must not use its in-cluster identity to bootstrap itself.

### Argo CD

Argo CD does not initially own management platform bootstrap resources in V1. Argo CD remains the Kubernetes applier for normal user workloads in `devdeploy-workload`.

A future design may move management platform resources under GitOps ownership, but that is not required for the first local bootstrap implementation.

### GitHub Actions

GitHub Actions must not directly deploy these manifests to Kubernetes. It must not receive management cluster credentials for this purpose.

Normal application deployment remains separate:

```text
UI -> Backend -> GitHub/GitOps Repository -> Argo CD -> devdeploy-workload
```

## 6. Kustomize Strategy

Kustomize should be the repository-side grouping layer for backend platform resources.

V1 guidance:

- Use one base-like directory at `platform/management/backend`.
- Keep all backend resources in the `devdeploy` namespace.
- List resources explicitly in `kustomization.yaml`.
- Keep resource names and labels deterministic.
- Avoid overlays until a real environment-specific requirement exists.
- Validate rendered output before mutation.
- Keep generated output reviewable and stable.
- Do not generate or commit real Secret values through Kustomize.

The future Launcher should render or validate this directory before applying it. Validation failures must stop the backend bootstrap step before cluster mutation.

## 7. ConfigMap Manifest Strategy

`configmap.yaml` should contain only non-sensitive backend settings.

Expected keys:

- `ENVIRONMENT`
- `JWT_ALGORITHM`
- `ACCESS_TOKEN_EXPIRE_MINUTES`
- `FRONTEND_ORIGIN`
- `KUBERNETES_IN_CLUSTER`
- `PROMETHEUS_BASE_URL`
- `LOKI_BASE_URL`
- `GRAFANA_BASE_URL`
- `GITOPS_ENABLED`
- `GITHUB_OWNER`
- `GITHUB_REPO`
- `GITOPS_WORKFLOW_FILE`
- `GITOPS_DELETE_WORKFLOW_FILE`
- `GITOPS_TARGET_REF`

Likely V1 values include:

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

Unavailable integrations must remain explicitly disabled or not configured. The backend must not report fake connectivity.

## 8. Secret Manifest Strategy

The runtime lifecycle is defined in [Backend Runtime Secret Strategy](./backend-secret-runtime-strategy.md).

The future backend Secret is expected to contain:

- `DATABASE_URL`
- `JWT_SECRET_KEY`
- `GITHUB_WORKFLOW_TOKEN`

Rules:

- Do not commit real Secret values.
- `secret.example.yaml` may contain placeholder values only.
- `secret.example.yaml` should be clearly marked as documentation and must not be included in deployable Kustomize resources.
- A future explicit Launcher mode should create or verify the real Secret at runtime.
- `GITHUB_WORKFLOW_TOKEN` may remain unset while GitOps automation is disabled.
- Secret values must not be written to `launcher-status.json`.
- Secret values must not be printed in Launcher logs.
- Secret values must not be returned through setup/status APIs.

The future implementation should avoid writing a rendered Secret with real values to the repository or a persistent local plaintext file.

## 9. Deployment Manifest Strategy

`deployment.yaml` should define:

- Deployment name: `devdeploy-backend`
- Namespace: `devdeploy`
- Container image: `devdeploy-backend:local`
- Image pull policy: `IfNotPresent`
- Container port: `8000`
- ConfigMap and Secret environment references
- Liveness and readiness probes
- Resource requests and limits
- Non-root security settings

Stable labels should include:

```yaml
app.kubernetes.io/name: devdeploy-backend
app.kubernetes.io/part-of: devdeploy-hub
app.kubernetes.io/component: backend
app.kubernetes.io/managed-by: devdeploy-launcher
```

The pod and container security context should preserve the current non-root runtime contract, including UID/GID `10001` where compatible. It should also retain established hardening such as disabled privilege escalation, dropped Linux capabilities, and a runtime-default seccomp profile.

Environment loading should use explicit references:

- Non-sensitive settings from the backend ConfigMap.
- Sensitive settings from the runtime-created backend Secret.

Initial probes may use:

```text
/api/v1/health
```

When a DB-aware `/api/v1/ready` endpoint exists, readiness should move to that endpoint while liveness can continue using `/api/v1/health`.

## 10. Service Manifest Strategy

`service.yaml` should define:

- Service name: `devdeploy-backend`
- Namespace: `devdeploy`
- Type: `ClusterIP`
- Port: `8000`
- Target port: `8000`
- Selector matching the backend Deployment labels

Internal cluster DNS:

```text
http://devdeploy-backend.devdeploy.svc.cluster.local:8000
```

The Service should remain cluster-internal. External access belongs to management ingress-nginx.

## 11. Ingress Manifest Strategy

`ingress.yaml` should target management ingress-nginx in `devdeploy-mgmt`.

V1 guidance:

- Use hostless, localhost-friendly path routing.
- Recommended path: `/api`
- Preserve the backend's existing `/api/v1` prefix.
- Route to Service `devdeploy-backend` on port `8000`.
- Use ingress class `nginx` explicitly.
- Do not require TLS for the V1 local setup.

Expected external health URL:

```text
http://localhost:8080/api/v1/health
```

The ingress should not rewrite `/api/v1` into an incompatible path. It should also reserve room for a future frontend route, likely `/`, without overlapping or shadowing backend API paths.

The `/metrics` endpoint should remain cluster-internal unless external metrics exposure is deliberately required.

## 12. Local Image Availability Strategy

The detailed build/load contract is defined in [Backend Image Build and Load Strategy](./backend-image-build-load-strategy.md).

The future backend bootstrap should require or perform:

```powershell
docker build -t devdeploy-backend:local ./backend
kind load docker-image devdeploy-backend:local --name devdeploy-mgmt
```

The Deployment should use:

```yaml
image: devdeploy-backend:local
imagePullPolicy: IfNotPresent
```

If the first Launcher implementation does not build images, it must verify that `devdeploy-backend:local` exists and fail with an actionable message when it is unavailable.

No external registry is required for the V1 local-first workflow. The Launcher must not silently pull or substitute an unrelated image.

## 13. Future Launcher Integration

Future explicit mode:

```powershell
.\scripts\launcher\devdeploy-launcher.ps1 -BootstrapManagementBackend
```

The mode should eventually:

1. Verify `devdeploy-mgmt` is Ready.
2. Verify namespace `devdeploy` is Ready.
3. Verify PostgreSQL is installed and Ready.
4. Verify or generate the backend Secret without exposing values.
5. Verify the local backend image, or build and load it according to the chosen implementation.
6. Render and validate `platform/management/backend` with Kustomize.
7. Apply or reconcile only the backend management resources.
8. Wait for Deployment `devdeploy-backend` to become Available.
9. Verify the Service and ingress route.
10. Check `/api/v1/health` through the cluster Service or management ingress.
11. Write backend component status to `launcher-status.json` without secrets.

This is an explicit platform bootstrap exception. It must not be added to default preflight behavior and must not be generalized into a user workload deployment path.

Future verification mode:

```powershell
.\scripts\launcher\devdeploy-launcher.ps1 -VerifyManagementBackend
```

`-VerifyManagementBackend` should be read-only. It should not build or load images, create Secrets, apply resources, restart workloads, or otherwise mutate the cluster unless a later design explicitly changes that contract.

## 14. Proposed Status Contract

Future `launcher-status.json` should extend `platform_bootstrap.components.backend`:

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

Allowed status values:

- `not_started`
- `ready`
- `degraded`
- `failed`
- `unknown`

The status contract must not include database passwords, JWT secrets, GitHub tokens, complete connection strings, Secret data, or raw command output.

## 15. V1 Limitations

- Phase 2D.6 adds the initial Kubernetes manifests but does not deploy them.
- Backend deployment remains a future explicit Launcher step.
- This phase does not run database migrations.
- `/api/v1/ready` is not implemented yet.
- Frontend and Argo CD are not installed yet.
- GitOps automation is not enabled yet.
- Runtime Secret generation is not implemented yet.
- Image build/load automation is not implemented yet.
- Management platform manifests are not initially owned by Argo CD.

## 16. Definition of Done

Phase 2D.5 is complete when:

- The backend manifest repository layout is documented.
- The manifest ownership model is documented.
- The ConfigMap strategy is documented.
- The Secret strategy is documented.
- The Deployment strategy is documented.
- The Service strategy is documented.
- The ingress strategy is documented.
- The local image availability strategy is documented.
- Future Launcher bootstrap and verification integration is documented.
- The proposed backend status contract is documented.
- No actual Kubernetes manifests are added.
- No backend deployment behavior is added.
- No Launcher, backend, frontend, workflow, or cluster runtime changes are made.

## 17. Related Documents

- [Backend Bootstrap Preparation](./backend-bootstrap-preparation.md)
- [Management Platform Bootstrap Plan](./management-platform-bootstrap-plan.md)
- [Bootstrapper / Launcher Design](./bootstrapper-launcher-design.md)
- [Multi-Cluster Redesign](./multi-cluster-redesign.md)
- [Localhost Networking and Port Strategy](./localhost-networking-port-strategy.md)
- [Security Boundaries and Credentials Model](./security-credentials-boundaries.md)
- [Phase 2 Implementation Roadmap](./phase-2-implementation-roadmap.md)
