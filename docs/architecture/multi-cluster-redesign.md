# DevDeploy Hub Multi-Cluster Architecture Redesign

## 1. Overview

DevDeploy Hub is evolving from a single local Kubernetes deployment UI into a local-first multi-cluster GitOps platform.

The target architecture separates the platform control plane from user workloads:

- `devdeploy-mgmt` is the management cluster.
- `devdeploy-workload` is the workload cluster.
- DevDeploy Hub platform components run in `devdeploy-mgmt`.
- User applications run only in `devdeploy-workload`.
- Argo CD runs in `devdeploy-mgmt` and applies desired state to `devdeploy-workload`.

The normal user application deployment flow remains:

```text
UI -> Backend -> GitHub/GitOps Repository -> Argo CD -> Workload Kubernetes Cluster
```

The backend must not directly `kubectl apply` or delete normal user workloads. GitHub Actions must not deploy directly to any Kubernetes cluster. Argo CD remains the only Kubernetes applier for normal user workloads.

## 2. Architecture Goals

- Provide a local-first platform that users can start without manually creating clusters or installing platform add-ons.
- Separate platform services from user workloads.
- Keep workload deployment GitOps-native and PR/repository driven.
- Make localhost access predictable without requiring routine `kubectl port-forward`.
- Preserve a clear boundary between bootstrap automation and normal application deployment.
- Keep the first serious version focused on self-managed local clusters created by DevDeploy Hub.
- Postpone existing-cluster onboarding until the local management/workload model is stable.
- Keep the Argo CD model simple initially while leaving room for App of Apps and per-app Argo CD Applications.

## 3. High-Level End-User Architecture

Target user flow:

1. The user downloads and starts DevDeploy Hub.
2. A local DevDeploy Bootstrapper or Launcher runs on the user's machine.
3. The Bootstrapper creates a management kind cluster named `devdeploy-mgmt`.
4. DevDeploy frontend, backend, PostgreSQL, Argo CD, ingress, monitoring, logging, and other platform components run inside `devdeploy-mgmt`.
5. The user opens the DevDeploy Hub web UI.
6. The Setup Wizard creates a separate workload kind cluster named `devdeploy-workload`.
7. User applications are deployed only to `devdeploy-workload`.
8. Argo CD runs in `devdeploy-mgmt` and is configured with credentials to deploy to `devdeploy-workload`.
9. The user creates deployment requests from the UI.
10. The backend triggers GitOps repository updates through GitHub/GitOps automation.
11. Argo CD syncs the generated workload manifests to `devdeploy-workload`.

Logical view:

```text
User machine
  |
  |-- DevDeploy Bootstrapper / Launcher
  |
  |-- kind cluster: devdeploy-mgmt
  |     |-- DevDeploy frontend
  |     |-- DevDeploy backend
  |     |-- PostgreSQL
  |     |-- Argo CD
  |     |-- ingress-nginx
  |     |-- monitoring/logging platform components
  |
  |-- kind cluster: devdeploy-workload
        |-- generated user workloads
        |-- workload ingress
        |-- workload observability agents as needed
```

## 4. Management Cluster Responsibilities

`devdeploy-mgmt` owns platform control-plane concerns:

- Running the DevDeploy frontend.
- Running the DevDeploy backend.
- Running the DevDeploy PostgreSQL database.
- Running Argo CD.
- Running platform ingress for DevDeploy Hub itself.
- Running platform monitoring and logging components where appropriate.
- Holding Argo CD cluster credentials for `devdeploy-workload`.
- Storing platform-local Kubernetes Secrets, ConfigMaps, and ServiceAccounts.
- Providing the web UI endpoint for the user.

The management cluster should not run normal user applications.

Exceptions may exist for tightly scoped platform demo components, but normal user-created deployment requests must target the workload cluster.

## 5. Workload Cluster Responsibilities

`devdeploy-workload` owns user runtime concerns:

- Running generated user application Deployments.
- Running generated user application Services.
- Running generated user application Ingress resources.
- Running workload-specific namespaces such as `devdeploy-workloads`.
- Exposing user applications through localhost-friendly ingress.
- Providing Kubernetes status, logs, and metrics for deployed workloads.

The workload cluster should not run DevDeploy Hub control-plane services such as the backend, frontend, PostgreSQL, or Argo CD.

## 6. Bootstrapper / Launcher Responsibilities

The local Bootstrapper or Launcher is the host-side component that can safely inspect and prepare the user's local machine.

Responsibilities:

- Check host prerequisites:
  - Docker
  - kind
  - kubectl
  - Git
  - available localhost ports
- Generate safe kind configs.
- Create `devdeploy-mgmt`.
- Install management-cluster platform components.
- Build or pull DevDeploy platform images as required.
- Load local images into kind clusters when needed.
- Start or verify DevDeploy Hub access through localhost.
- Create `devdeploy-workload` when requested by the Setup Wizard.
- Configure Argo CD in `devdeploy-mgmt` to reach `devdeploy-workload`.
- Recover gracefully from partial setup failures.

The Bootstrapper may perform cluster bootstrap operations because it is a local environment initializer. That is separate from normal user workload deployment.

The Bootstrapper should not bypass the GitOps flow for normal user applications.

## 7. Backend Responsibility Boundaries

The backend is responsible for platform API behavior:

- Authentication and user/session handling.
- Service catalog records.
- Deployment request records.
- Observability API aggregation.
- Settings and integration status.
- Setup Wizard state and orchestration.
- Triggering GitOps workflow dispatch when configured.

The backend may coordinate setup operations through explicit setup APIs and a controlled Bootstrapper/Launcher contract, but it must not directly apply or delete normal user workload manifests in Kubernetes. An in-cluster backend must not assume direct access to the user's host Docker daemon, kind binary, kubectl binary, kubeconfig, local ports, or filesystem state.

Allowed backend behavior:

- Validate deployment requests.
- Store deployment request state.
- Trigger GitHub/GitOps workflows.
- Read Kubernetes state for observability.
- Read Argo CD state for sync/health.
- Report setup status and preflight results.

Disallowed backend behavior for normal user workloads:

- `kubectl apply`
- `kubectl delete`
- Kubernetes API write calls that create, update, or delete user workloads.
- Direct cluster mutation that bypasses GitOps.

## 8. Setup Wizard Lifecycle

The Setup Wizard should become the main guided path for preparing a local environment.

Target lifecycle:

1. **Welcome**
   - Explain the management/workload split.
   - Explain the GitOps deployment boundary.

2. **Environment type**
   - First serious version defaults to creating isolated local clusters.
   - Existing cluster support is postponed.

3. **Pre-flight checks**
   - Verify host prerequisites through the local Bootstrapper or local backend mode.
   - If the backend is running inside Kubernetes, clearly explain that host tools cannot be verified from the backend pod.

4. **Management cluster**
   - Create or verify `devdeploy-mgmt`.
   - Install platform components.

5. **GitHub / GitOps repository**
   - Connect to the GitOps repository.
   - Repository creation automation is postponed unless explicitly added later.

6. **Workload cluster**
   - Create or verify `devdeploy-workload`.
   - Configure predictable ingress ports.

7. **Argo CD setup**
   - Register `devdeploy-workload` as a target cluster in Argo CD.
   - Create the parent workload Application.

8. **Health check**
   - Verify DevDeploy UI, backend, PostgreSQL, Argo CD, management cluster, workload cluster, and ingress access.

9. **Demo app deploy**
   - Trigger the normal GitOps deployment flow for a safe demo image.
   - Confirm Argo CD sync and workload availability.

## 9. GitOps Deployment Flow

Normal application deployment flow:

```text
User
  -> DevDeploy UI
  -> DevDeploy backend
  -> GitHub Actions / GitOps automation
  -> GitOps repository manifest change
  -> Repository update according to policy
  -> Argo CD in devdeploy-mgmt
  -> devdeploy-workload Kubernetes cluster
```

Key rules:

- The UI creates an intent.
- The backend validates and records the intent.
- GitHub Actions generates or updates manifests.
- GitHub Actions validates manifests.
- GitHub Actions updates the GitOps repository according to repository policy.
- MVP/local flows may use direct commits.
- Stricter flows may require pull requests, checks, and review before merge.
- In all cases, GitHub Actions must not deploy directly to Kubernetes.
- Argo CD applies the desired state from the GitOps repository to `devdeploy-workload`.

Deletion follows the same model:

```text
UI delete request -> Backend -> GitHub Actions -> remove manifests in Git -> repository update -> Argo CD sync -> workload removed
```

## 10. Argo CD Multi-Cluster Model

Argo CD runs in `devdeploy-mgmt`.

Argo CD deploys to `devdeploy-workload`.

Target design should be close to an App of Apps model, but the initial implementation should stay simple.

Initial implementation:

- One parent Argo CD Application:

```text
devdeploy-workloads
```

- The parent Application tracks:

```text
infra/kubernetes/generated/workloads
```

- Generated workload folders remain under:

```text
infra/kubernetes/generated/workloads/apps/<app-name>
```

This keeps the first multi-cluster implementation understandable and minimizes Argo CD object management complexity.

Future App of Apps model:

- Each user app can get its own Argo CD Application.
- The parent Application can track child Application manifests.
- Per-app Argo CD Applications enable cleaner:
  - health status
  - sync status
  - rollback
  - app lifecycle management
  - per-app history
  - per-app deletion

The initial repository layout should remain compatible with this future model.

## 11. GitOps Repository Layout

Current generated workload layout remains a good base:

```text
infra/kubernetes/generated/workloads/
├── namespace.yaml
├── kustomization.yaml
└── apps/
    └── <app-name>/
        ├── deployment.yaml
        ├── service.yaml
        ├── ingress.yaml
        └── kustomization.yaml
```

In V1, `ingress.yaml` is generated only when ingress is enabled.

The parent workload kustomization lists generated app folders:

```yaml
resources:
  - namespace.yaml
  - apps/my-app
```

Future App of Apps compatible layout:

```text
infra/argocd/applications/workloads/
├── devdeploy-workloads.yaml
└── apps/
    └── my-app-application.yaml
```

The first implementation does not need per-app Application manifests, but the generated workload structure should not prevent that migration.

## 12. Localhost Networking Strategy

New local environments should use stable localhost access.

Recommended kind ports:

Management cluster:

```text
devdeploy-mgmt API server: 127.0.0.1:<mgmt-api-port>
DevDeploy UI ingress:     http://devdeploy.localhost:<mgmt-http-port>
```

Workload cluster:

```text
devdeploy-workload API server: 127.0.0.1:<workload-api-port>
User app ingress:             http://<app-name>.localhost:<workload-http-port>
```

The exact ports should be selected by the Bootstrapper after checking availability.

Recommended initial defaults:

```text
Management API server: 58080
Management HTTP:       8080
Management HTTPS:      8443
```

If both clusters expose ingress locally, the workload cluster should use a distinct HTTP/HTTPS pair to avoid collisions, for example:

```text
Workload API server: 58081
Workload HTTP:       8081
Workload HTTPS:      8444
```

For user app URLs, prefer host-based routing:

```text
http://<app-name>.localhost:<workload-http-port>
```

Host-based routing is preferred because it avoids path rewrite complexity and lets applications serve from `/`.

## 13. Observability Model

Observability should support both clusters:

Management cluster observability:

- DevDeploy backend/frontend health.
- PostgreSQL health.
- Argo CD health.
- Platform add-on health.

Workload cluster observability:

- User workload Deployments.
- Pods.
- Services.
- Ingress.
- Logs.
- Metrics.

Initial implementation can keep observability simple:

- The backend reads Kubernetes state from both clusters using read-only credentials.
- Prometheus and Loki may initially live in `devdeploy-mgmt`.
- Workload logs and metrics can be forwarded or scraped from `devdeploy-workload`.

Future improvements:

- Per-cluster observability status.
- Per-app Argo CD health.
- Workload cluster log forwarding.
- Workload cluster metrics federation or remote write.
- Clear UI filters for management vs workload cluster.

## 14. Security Boundaries

Security boundaries:

- Management and workload clusters are separate.
- User workloads do not run in the management cluster.
- Argo CD is the only normal workload applier.
- GitHub Actions never deploys directly to clusters.
- Backend does not directly apply/delete user workloads.
- Bootstrapper permissions are local setup permissions, not normal deployment permissions.
- GitHub tokens must not be stored in Git.
- Sensitive tokens must not be stored in browser localStorage.
- Kubeconfigs and cluster credentials should be stored only where required and protected by local OS permissions or Kubernetes Secrets.
- Argo CD cluster credentials should be scoped to the workload cluster.
- Read-only observability access should remain separate from write/apply permissions.

The first serious version should favor explicit local-only constraints over broad automation.

## 15. V1 Limitations

Postponed for the first serious version:

- Existing cluster onboarding.
- Cloud provider cluster creation.
- Multi-tenant/team RBAC.
- Production-grade secret management.
- Full App of Apps with per-app Argo CD Applications.
- Automated GitHub repository creation.
- Automatic DNS beyond `*.localhost`.
- TLS automation.
- Rollback UI.
- Complex environment promotion across dev/staging/prod.
- External database provisioning.
- Enterprise SSO.

The first serious version should create its own isolated local management and workload clusters. This reduces ambiguity, limits support burden, and gives DevDeploy Hub a predictable environment to manage.

## 16. Implementation Roadmap

Recommended implementation sequence:

0. **Completed baseline**
   - GitOps deployment flow.
   - Setup Wizard foundation.
   - Setup preflight endpoint.
   - Runtime-aware preflight.
   - Security and dependency hardening.
   - Green CI.

1. **Bootstrapper design and command contract**
   - Define host-side launcher responsibilities.
   - Define local API or IPC between UI/backend and launcher.
   - Define safe command execution boundaries.

2. **Kind config preview**
   - Generate management and workload kind configs.
   - Show selected ports before creation.
   - Do not create clusters yet.

3. **Management cluster creation**
   - Create `devdeploy-mgmt`.
   - Install DevDeploy platform components.
   - Expose UI through localhost ingress.

4. **Workload cluster creation**
   - Create `devdeploy-workload`.
   - Install workload ingress.
   - Verify app URL routing.

5. **Argo CD workload cluster registration**
   - Register `devdeploy-workload` in Argo CD.
   - Create parent Application `devdeploy-workloads`.

6. **GitOps workload deployment smoke test**
   - Deploy a safe demo app through the existing GitOps flow.
   - Confirm Argo CD sync and browser access through localhost.

7. **Observability across clusters**
   - Read workload cluster resources.
   - Surface management/workload health separately.

8. **Future App of Apps migration**
   - Add per-app Argo CD Applications when the parent model is stable.

9. **Existing cluster support**
   - Add later after local two-cluster lifecycle is reliable.
