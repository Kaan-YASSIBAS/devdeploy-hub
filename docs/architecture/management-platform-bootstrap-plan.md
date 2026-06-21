# Management Platform Bootstrap Plan

## 1. Purpose

`devdeploy-mgmt` is the management cluster for DevDeploy Hub. It is where the platform itself will run: the UI, API, database, Argo CD, and management ingress.

This document defines the future platform bootstrap contract for `devdeploy-mgmt`. It is a planning document only. It does not implement installation automation, change manifests, or run cluster commands.

The normal workload deployment flow remains GitOps-only:

```text
UI -> Backend -> GitHub/GitOps Repository -> Argo CD -> Workload Kubernetes Cluster
```

Platform bootstrap is different from normal workload deployment. The Launcher may eventually perform explicit host-side bootstrap operations for the platform cluster, but it must not become a back door for deploying normal user workloads.

## 2. Bootstrap Ownership

### Launcher

The Launcher is the host-side bootstrap authority. In a future explicit mode, it may run controlled setup commands needed to install or verify platform components in `devdeploy-mgmt`.

The Launcher is responsible for:

- Verifying `devdeploy-mgmt` readiness.
- Running future explicit platform bootstrap commands.
- Keeping bootstrap operations idempotent where practical.
- Writing sanitized status and log artifacts under `.devdeploy/local`.
- Avoiding automatic destructive cleanup.
- Making failures actionable and recoverable.

The Launcher must not deploy normal user workloads.

### Backend

The backend is the platform API and state authority after the platform is running. It should expose setup/status APIs and consume Launcher status where appropriate.

The backend should not bootstrap itself from the host. An in-cluster backend must not assume access to host Docker, kind, kubectl, Helm, kubeconfigs, ports, or filesystem state.

### Setup Wizard

The Setup Wizard is the user-facing setup orchestrator. It should read backend and Launcher status, explain progress, and guide the user through setup steps.

The browser must not run host commands directly.

### Argo CD

Argo CD is installed in `devdeploy-mgmt`. After it is installed and configured, it becomes the Kubernetes applier for normal user workloads targeting `devdeploy-workload`.

### GitHub Actions

GitHub Actions is responsible for manifest generation, validation, and GitOps repository updates according to repository policy. It must not deploy directly to Kubernetes clusters.

## 3. Target Components in `devdeploy-mgmt`

Future platform bootstrap should install or verify these components:

- `ingress-nginx` for management HTTP/HTTPS routing.
- PostgreSQL for DevDeploy Hub platform data.
- DevDeploy backend.
- DevDeploy frontend.
- Argo CD.
- Optional metrics/logging components in a later phase.

User workloads must not run in `devdeploy-mgmt`.

## 4. Recommended Bootstrap Order

Recommended future order:

1. Verify `devdeploy-mgmt` exists and has Ready node capacity.
2. Install or verify management `ingress-nginx`.
3. Create or verify the `devdeploy` namespace.
4. Install or verify PostgreSQL.
5. Install or verify the DevDeploy backend.
6. Install or verify the DevDeploy frontend.
7. Install or verify Argo CD.
8. Expose the UI at `http://devdeploy.localhost:8080`.
9. Write `platform_bootstrap` status into `launcher-status.json`.

The order keeps the cluster, routing, data layer, API, UI, and GitOps controller checks separate. A later implementation can retry individual stages without assuming all prior work must be recreated.

## 5. Explicit Future Launcher Modes

Future launcher switches may include:

```powershell
.\scripts\launcher\devdeploy-launcher.ps1 -BootstrapManagementPlatform
.\scripts\launcher\devdeploy-launcher.ps1 -VerifyManagementPlatform
```

These modes must be explicit and idempotent.

Expected behavior:

- Default launcher mode remains read-only.
- `-GenerateKindConfigs` remains preview-only.
- `-CreateManagementCluster` only creates or verifies `devdeploy-mgmt`.
- `-CreateWorkloadCluster` only creates or verifies `devdeploy-workload`.
- `-BootstrapManagementPlatform` may install or verify platform components only in `devdeploy-mgmt`.
- `-VerifyManagementPlatform` should use read-only checks only.

These switches are not implemented yet.

## 6. Safety Boundaries

Future platform bootstrap must follow these boundaries:

- No platform bootstrap unless an explicit future mode is passed.
- No destructive cleanup by default.
- No automatic cluster deletion on failure.
- No `kubectl delete` cleanup unless a separate, explicit, destructive recovery mode is designed.
- No normal user workload deployment from the backend.
- No normal user workload deployment from GitHub Actions.
- No cluster credentials in GitHub Actions for normal app deployment.
- Argo CD remains the Kubernetes applier for normal user workloads.
- Generated workload manifests target `devdeploy-workload`, not `devdeploy-mgmt`.
- Secrets must not be written to Git or logs.

Bootstrap operations may initialize platform components, but they must not blur the boundary between platform setup and normal workload deployment.

## 7. Future Status Contract

Future launcher status should add a top-level `platform_bootstrap` object.

Suggested shape:

```yaml
platform_bootstrap:
  status: not_started | ready | degraded | failed | unknown
  checked_at: timestamp
  message: string
  components:
    ingress_nginx:
      installed: true | false | null
      ready: true | false | null
      namespace: ingress-nginx
      status: not_started | ready | degraded | failed | unknown
    postgres:
      installed: true | false | null
      ready: true | false | null
      namespace: devdeploy
      status: not_started | ready | degraded | failed | unknown
    backend:
      installed: true | false | null
      ready: true | false | null
      namespace: devdeploy
      status: not_started | ready | degraded | failed | unknown
    frontend:
      installed: true | false | null
      ready: true | false | null
      namespace: devdeploy
      status: not_started | ready | degraded | failed | unknown
    argocd:
      installed: true | false | null
      ready: true | false | null
      namespace: argocd
      status: not_started | ready | degraded | failed | unknown
```

Status meanings:

- `not_started`: no bootstrap attempt or verification result exists yet.
- `ready`: component is installed and ready.
- `degraded`: component exists but is not fully ready.
- `failed`: bootstrap or verification failed.
- `unknown`: status could not be determined safely.

The top-level status should be `ready` only when all required platform components are ready.

## 8. Future Verification Commands

Future implementation may use safe read-only commands such as:

```powershell
kubectl --context kind-devdeploy-mgmt get nodes
kubectl --context kind-devdeploy-mgmt get ns
kubectl --context kind-devdeploy-mgmt get pods -A
kubectl --context kind-devdeploy-mgmt get svc -A
kubectl --context kind-devdeploy-mgmt get ingress -A
```

Component-specific checks may include:

```powershell
kubectl --context kind-devdeploy-mgmt get pods -n ingress-nginx
kubectl --context kind-devdeploy-mgmt get pods -n devdeploy
kubectl --context kind-devdeploy-mgmt get svc -n devdeploy
kubectl --context kind-devdeploy-mgmt get pods -n argocd
```

This document does not add executable automation for these commands.

## 9. V1 Limitations

V1 platform bootstrap is local-only.

Known limitations:

- HTTP is the default user-facing path.
- TLS automation is postponed.
- PostgreSQL is not highly available.
- A production-grade secrets manager is not part of V1.
- Cloud cluster integration is postponed.
- Existing-cluster onboarding is postponed.
- Platform observability can remain minimal until the core multi-cluster path works.

## 10. Definition of Done for Future Bootstrap Implementation

Future Phase 2D implementation is complete when:

- `devdeploy-mgmt` is Ready.
- Management `ingress-nginx` is Ready.
- PostgreSQL is Ready.
- DevDeploy backend is Ready.
- DevDeploy frontend is Ready.
- Argo CD is Ready.
- DevDeploy frontend is reachable at `http://devdeploy.localhost:8080`.
- Backend health is reachable through management ingress or the intended localhost route.
- `launcher-status.json` includes a useful `platform_bootstrap` status.
- No user workloads are deployed to `devdeploy-mgmt`.
- `devdeploy-workload` remains a separate cluster for user applications.
- Normal app deployment remains GitOps-only through Argo CD.

## 11. Related Documents

- [Multi-Cluster Redesign](./multi-cluster-redesign.md)
- [Bootstrapper / Launcher Design](./bootstrapper-launcher-design.md)
- [Setup Wizard Multi-Cluster Lifecycle Design](./setup-wizard-multi-cluster-lifecycle.md)
- [GitOps Repository Layout and Argo CD Application Model](./gitops-repository-argocd-model.md)
- [Localhost Networking and Port Strategy](./localhost-networking-port-strategy.md)
- [Security Boundaries and Credentials Model](./security-credentials-boundaries.md)
