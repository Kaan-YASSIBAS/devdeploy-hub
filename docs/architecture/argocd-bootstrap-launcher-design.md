# Argo CD Bootstrap Launcher Design

## 1. Purpose

This document defines the future DevDeploy Launcher contracts for:

```text
-BootstrapManagementArgoCD
-VerifyManagementArgoCD
```

The higher-level installation, access, credential, workload registration, and GitOps decisions are defined in [Argo CD Bootstrap Preparation](./argocd-bootstrap-preparation.md).

Argo CD is the GitOps reconciler for the DevDeploy Hub multi-cluster architecture. It runs in `devdeploy-mgmt` and will later reconcile accepted Git state into `devdeploy-workload`.

This launcher milestone is limited to installing and verifying Argo CD in the management cluster. It does not register `devdeploy-workload`, create the root Application, configure a GitOps repository, or deploy user workloads.

The normal user workload path remains:

```text
UI -> Backend -> GitHub/GitOps Repository -> Argo CD -> devdeploy-workload
```

This document is design-only. It does not add Launcher code, install Helm charts, create manifests, or mutate either cluster.

## 2. Shared Runtime Contract

Both future modes target:

| Setting | Value |
| --- | --- |
| Cluster | `devdeploy-mgmt` |
| Context | `kind-devdeploy-mgmt` |
| Namespace | `argocd` |
| Helm release | `argocd` |
| Helm chart | `argo/argo-cd` |
| Ingress host | Hostless |
| Ingress path | `/argocd` |
| UI URL | `http://localhost:8080/argocd` |

Shared rules:

- Default Launcher behavior remains read-only preflight.
- Bootstrap runs only when `-BootstrapManagementArgoCD` is explicitly passed.
- Verification runs only when `-VerifyManagementArgoCD` is explicitly passed.
- Both modes write sanitized status to `platform_bootstrap.components.argocd`.
- Neither mode registers or mutates `devdeploy-workload`.
- Neither mode creates Applications or deploys user workloads.
- Failed bootstrap does not trigger automatic uninstall or destructive cleanup.

## 3. Bootstrap Mode: `-BootstrapManagementArgoCD`

Future invocation:

```powershell
.\scripts\launcher\devdeploy-launcher.ps1 -BootstrapManagementArgoCD
```

### 3.1 Preconditions

The Launcher should verify, in order:

1. Helm CLI is available.
2. kubectl CLI is available.
3. kind reports cluster `devdeploy-mgmt` exists.
4. kubectl context `kind-devdeploy-mgmt` is usable.
5. The management Kubernetes API is reachable.
6. At least one management node is Ready.
7. Management ingress-nginx is installed and has an Available controller.

Any required failure must stop bootstrap before namespace or Helm release mutation. Missing optional tooling must not be silently ignored when that tooling is required by the selected mode.

### 3.2 Namespace and Repository Preparation

After preconditions pass, the explicit bootstrap mode may:

- Create or verify namespace `argocd` in `devdeploy-mgmt`.
- Add or update the official Helm repository:

  ```text
  repository name: argo
  repository URL:  https://argoproj.github.io/argo-helm
  chart:           argo/argo-cd
  ```

- Update Helm repository metadata before installation.

Namespace creation should use an idempotent mechanism such as Helm `--create-namespace` or a narrowly scoped namespace ensure helper. The implementation must not create unrelated namespaces or resources.

### 3.3 Helm Installation

The implementation should use an exact chart version selected during Phase 2F.3 after chart schema, Kubernetes compatibility, and security validation.

Conceptual command:

```text
helm upgrade --install argocd argo/argo-cd \
  --kube-context kind-devdeploy-mgmt \
  --namespace argocd \
  --create-namespace \
  --version <pinned-version> \
  --values <validated-values>
```

The Launcher must:

- Pin the chart version explicitly.
- Use explicit context, namespace, and release arguments.
- Wait for Helm reconciliation with a bounded timeout.
- Record only sanitized chart and release metadata.
- Avoid logging complete rendered values when they may contain sensitive data.
- Leave failed resources available for diagnosis rather than uninstalling automatically.

Only the Argo CD release in `devdeploy-mgmt/argocd` is in scope.

### 3.4 Readiness Verification

After Helm succeeds, the Launcher should verify the resources installed by the pinned chart rather than assuming fixed topology.

Expected V1 components include:

- Deployment `argocd-server`.
- Deployment `argocd-repo-server`.
- Deployment `argocd-applicationset-controller`, when enabled by the pinned chart values.
- Redis Deployment or StatefulSet, according to the pinned chart topology.
- StatefulSet `argocd-application-controller`.

Implementation should inspect the pinned chart output and values to confirm exact workload names and kinds. Optional components must be represented honestly; an intentionally disabled component must not be reported as missing.

Required checks should include:

- Desired workloads exist.
- Deployments have the expected Available replicas.
- StatefulSets have the expected Ready replicas.
- Required Pods are Running and Ready.
- Service `argocd-server` exists.
- No component remains in a failed rollout state.

### 3.5 Ingress and Reachability

The bootstrap mode should configure hostless path-based ingress:

```text
host:             empty
ingressClassName: nginx
path:             /argocd
pathType:         Prefix
TLS:              disabled for V1
URL:              http://localhost:8080/argocd
```

The DevDeploy hostless routes remain unchanged:

```text
http://localhost:8080/         -> DevDeploy frontend
http://localhost:8080/api      -> DevDeploy backend
http://localhost:8080/argocd   -> Argo CD
```

Argo CD server-side TLS and path behavior must match ingress configuration. The pinned chart values must enable HTTP/insecure mode and configure `server.basehref` plus `server.rootpath` as `/argocd`, ensuring login redirects and static assets retain the prefix.

After rollout, the Launcher should verify:

- Ingress exists in namespace `argocd`.
- The rule is hostless.
- Ingress class is `nginx`.
- Path is exactly `/argocd` with `Prefix` matching.
- TLS is absent for V1.
- Backend Service is `argocd-server` on the expected port.
- `http://localhost:8080/argocd` returns the Argo CD UI or an expected Argo CD redirect.
- A safe, unauthenticated API/version endpoint is checked only if the pinned Argo CD version exposes one reliably.

Normal access must not depend on port-forwarding. Port-forward remains a troubleshooting tool only.

### 3.6 Initial Admin Credential Availability

The Launcher should verify that the initial admin credential Secret expected by the pinned chart exists, normally `argocd-initial-admin-secret`, and that the expected password key is present.

Verification must report only booleans such as:

```text
admin_secret_present: true
```

It must not read a raw password into status, print Secret data, decode base64 values for logging, or persist credential material locally.

## 4. Verify Mode: `-VerifyManagementArgoCD`

Future invocation:

```powershell
.\scripts\launcher\devdeploy-launcher.ps1 -VerifyManagementArgoCD
```

This mode is strictly read-only.

### 4.1 Allowed Operations

- `kind get clusters`.
- kubectl context, node, namespace, workload, Pod, Service, Ingress, and Secret metadata reads.
- `helm list` or `helm status` when Helm is available and release verification requires it.
- HTTP GET requests to the hostless `/argocd` Argo CD URL.
- Sanitized Launcher status and log writes under `.devdeploy/local`.

The mode must not invoke any helper that performs Helm install/upgrade, namespace creation, kubectl apply/patch/delete, rollout restart, Secret mutation, image build/load, or cluster creation.

### 4.2 Verification Sequence

1. Verify kubectl CLI exists.
2. Verify Helm CLI exists if Helm release metadata is required.
3. Verify `devdeploy-mgmt`, context `kind-devdeploy-mgmt`, API reachability, and a Ready node.
4. Verify namespace `argocd` exists.
5. Verify Helm release `argocd` exists and reports deployed.
6. Verify expected Argo CD workloads and required Pods are Ready.
7. Verify Service `argocd-server` exists and exposes the expected port.
8. Verify the Ingress is hostless, uses class `nginx`, and routes `/argocd` with `Prefix` matching.
9. Verify `http://localhost:8080/argocd` returns an expected Argo CD page or redirect.
10. Verify initial admin credential Secret and expected key metadata exist without reading the value.
11. Write sanitized `platform_bootstrap.components.argocd` status.

Required resource failures should produce `status: error`. Host route failures may produce `warning` when all in-cluster resources are Ready, allowing the user to distinguish a routing problem from an Argo CD runtime failure.

## 5. Helm Values Strategy

V1 values must express these decisions:

| Value intent | Decision |
| --- | --- |
| Namespace | `argocd` |
| Release | `argocd` |
| Host | Hostless |
| Path | `/argocd` |
| Ingress | Enabled |
| Ingress class | `nginx` |
| TLS | Disabled |
| Server transport | HTTP/insecure mode |
| Server base href | `/argocd` |
| Server root path | `/argocd` |
| HA | Disabled |

Exact value keys are deliberately not fixed in this design document. They must be verified against the pinned chart version during Phase 2F.3 because chart schemas can change.

Values may be passed as explicit Helm arguments or written to a deterministic local file such as:

```text
.devdeploy/local/argocd/values.yaml
```

If a generated local values file is used:

- It remains ignored by Git under `.devdeploy/`.
- It contains no admin password, repository credential, workload token, kubeconfig, or other secret.
- It is deterministic for the selected chart version and V1 settings.
- Launcher logs report only the local path and non-sensitive selected settings.

## 6. Launcher Status Contract

Both modes should write:

```text
platform_bootstrap.components.argocd
```

Proposed shape:

```json
{
  "installed": false,
  "ready": false,
  "namespace": "argocd",
  "release": "argocd",
  "chart": "argo/argo-cd",
  "chart_version": "<pinned-version>",
  "server_deployment": "argocd-server",
  "repo_server_deployment": "argocd-repo-server",
  "application_controller_statefulset": "argocd-application-controller",
  "ingress_enabled": true,
  "ingress_host": "",
  "ingress_path": "/argocd",
  "ui_access": "http://localhost:8080/argocd",
  "admin_secret_present": false,
  "mode": "not_checked",
  "status": "not_started",
  "message": "Argo CD bootstrap has not been requested.",
  "checked_at": "<ISO-8601 timestamp>"
}
```

Recommended `mode` values:

- `not_checked`
- `bootstrap`
- `verify`

Recommended `status` values:

- `not_started`
- `ready`
- `warning`
- `error`
- `unknown`

Status and checks may include component readiness counts and non-sensitive resource names. They must not contain Secret values, admin passwords, bearer tokens, kubeconfigs, certificates, private keys, Helm credentials, or raw command output that may include credentials.

After successful Argo CD bootstrap, top-level `platform_bootstrap.status` remains `partial`. Workload cluster registration, GitOps repository access, and the root workload Application are not complete yet.

## 7. Admin Credential Handling

- Bootstrap and verification may report only whether the initial admin Secret and expected key exist.
- The Launcher must not print the password by default.
- The Launcher must not persist the password or base64 Secret value in logs, status, generated values, or repository files.
- Initial password rotation and account hardening are outside the first bootstrap implementation.
- Any future password retrieval helper must be explicit, separately designed, and avoid persistence.
- Frontend and backend APIs must not proxy the initial password to the browser.

## 8. Safety Boundaries

### Bootstrap mode

`-BootstrapManagementArgoCD` may:

- Create or verify namespace `argocd` in `devdeploy-mgmt`.
- Add or update the official Argo Helm repository.
- Run Helm install/upgrade only for release `argocd` in `devdeploy-mgmt/argocd`.
- Read management cluster state and verify host ingress access.

It must not:

- Mutate `devdeploy-workload`.
- Register any external cluster.
- Create Argo CD Applications or deploy user workloads.
- Redeploy DevDeploy backend or frontend.
- Run database migrations, resets, drops, or deletes.
- Create GitHub repositories or modify GitHub workflows.
- Run `kubectl delete` or perform automatic uninstall.
- Print admin credentials or Secret values.

### Verify mode

`-VerifyManagementArgoCD` is read-only. It must not call bootstrap helpers or perform any Kubernetes, Helm, Docker, Git, database, or Secret mutation.

GitHub Actions remain cluster-credential-free and must not deploy directly to Kubernetes. Argo CD remains the only normal user-workload applier.

## 9. Failure Handling

The Launcher should convert failures into sanitized checks and actionable status rather than unhandled exceptions.

| Failure | Expected behavior |
| --- | --- |
| Helm missing | Stop bootstrap before namespace/release mutation; report required tool failure. |
| kubectl missing | Stop before cluster checks; report required tool failure. |
| `devdeploy-mgmt` missing | Do not create it implicitly; direct the user to the management cluster mode. |
| Context/API unavailable | Do not run Helm; report management cluster degraded or unreachable. |
| No Ready node | Do not run Helm; report blocking readiness failure. |
| ingress-nginx not Ready | Do not install Argo CD ingress; direct the user to management ingress recovery. |
| Helm repository unavailable | Stop with sanitized network/repository error; do not uninstall or retry indefinitely. |
| Helm release fails | Preserve resources for diagnosis; record `error`; perform no automatic cleanup. |
| Core workload not Ready | Report the specific non-ready component and bounded rollout timeout. |
| Ingress host unreachable | Report `warning` if in-cluster resources are Ready; otherwise report `error`. |
| Initial admin Secret missing | Report credential availability failure without attempting to synthesize or print a password. |

Rerunning bootstrap should be idempotent through `helm upgrade --install`. Rerunning verification should never modify state.

## 10. Future Validation Plan

Phase 2F.3 and 2F.4 should validate:

```powershell
.\scripts\launcher\devdeploy-launcher.ps1 -BootstrapManagementArgoCD
.\scripts\launcher\devdeploy-launcher.ps1 -VerifyManagementArgoCD
```

Read-only inspection:

```powershell
kubectl --context kind-devdeploy-mgmt -n argocd get pods,svc,ingress
helm --kube-context kind-devdeploy-mgmt -n argocd list
Invoke-WebRequest http://localhost:8080/argocd -UseBasicParsing
```

Status inspection:

```powershell
(Get-Content .devdeploy\local\status\launcher-status.json | ConvertFrom-Json).platform_bootstrap.components.argocd | ConvertTo-Json -Depth 10
```

Validation must confirm:

- Bootstrap changes only release `argocd` in `devdeploy-mgmt/argocd`.
- Verification performs no mutation.
- Required Argo CD resources are Ready.
- Host-specific ingress works without routine port-forwarding.
- Admin credential availability is reported without exposing its value.
- `platform_bootstrap.status` remains `partial`.
- No `devdeploy-workload`, user workload, backend, frontend, database, GitHub, or workflow mutation occurs.

## 11. Relationship to Next Phases

- Phase 2F.3 implements `-BootstrapManagementArgoCD`.
- Phase 2F.4 implements `-VerifyManagementArgoCD`.
- A later phase implements `-RegisterWorkloadClusterWithArgoCD`.
- A later phase implements `-VerifyArgoCDWorkloadCluster`.
- GitOps root Application creation follows successful workload registration.
- GitOps repository creation, GitHub integration, and CI automation remain future, separately reviewed work.
