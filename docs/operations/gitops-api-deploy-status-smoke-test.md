# GitOps API Deploy And Status Smoke Test

## Purpose

This procedure validates the full local API deploy and live status path:

```text
POST /api/v1/gitops/apps
  -> generate and push GitOps manifests
  -> Argo CD automatically reconciles devdeploy-workloads-root
  -> devdeploy-workload/devdeploy-apps receives the workload
  -> GET /api/v1/gitops/apps/{app_name}/status reports live readiness
```

The deploy response confirms Git publication only. The separate status endpoint uses the live read-only Kubernetes reader and should eventually report `deployed`. Argo CD remains the workload deployment actor.

This procedure creates the known smoke workload `api-status-smoke-nginx`. Run it only in an explicitly approved local environment.

API-generated Deployments now include default numeric non-root, RuntimeDefault seccomp, disabled privilege escalation, read-only root filesystem, and dropped-capability security contexts. Trivy KSV-0118 prompted the initial hardening, and KSV-0014 is addressed by `readOnlyRootFilesystem: true` plus writable `emptyDir` mounts for nginx cache, runtime, and temporary paths.

## Latest Verified Result

Phase 2J.5j completed successfully with the following observed result:

- App: `api-status-smoke-nginx`.
- Git commit: `33e7df4f2fcf6d71d00bc94e51daaee11083e8b6`.
- Commit message: `deploy: add api-status-smoke-nginx workload`.
- The deploy API returned HTTP `202 Accepted`, `status: pushed_waiting_for_argocd`, and the commit SHA.
- The status API returned HTTP `200 OK` and `status: deployed`.
- `devdeploy-workloads-root` was `Synced` and `Healthy`.
- `observed_revision` matched `commit_sha` and `root_application.observed_commit_match` was `true`.
- Workload status reported `deployment_ready`, `service_ready`, and `pods_ready` as `true`.
- Replica status reported `desired_replicas: 1`, `ready_replicas: 1`, and `available_replicas: 1`.
- Pod status reported `pod_count: 1` and `ready_pod_count: 1`; read-only verification observed zero restarts.
- The Git working tree was clean after the smoke deployment and before the hardening follow-up.
- Local HEAD and `origin/main` subsequently advanced through the smoke and security-hardening commits.

The smoke commit changed only:

```text
gitops/workloads/devdeploy-apps/apps/api-status-smoke-nginx/deployment.yaml
gitops/workloads/devdeploy-apps/apps/api-status-smoke-nginx/kustomization.yaml
gitops/workloads/devdeploy-apps/apps/api-status-smoke-nginx/service.yaml
gitops/workloads/devdeploy-apps/kustomization.yaml
```

Manual verification used read-only cluster queries only. It observed Deployment `api-status-smoke-nginx` ready at `1/1`, its ClusterIP Service on `80/TCP`, and one running Pod ready at `1/1` with zero restarts.

The initial generated Deployment was subsequently hardened after Trivy reported KSV-0118 and KSV-0014. API-generated workloads now use the security defaults described above, and CI is green after the hardening follow-up.

The smoke app remains in Git and in the workload cluster because the Root Application still uses `prune=false`. Verified deletion remains future work under the separate delete and prune design.

## Preconditions

Before starting, confirm:

- `devdeploy-mgmt` is running.
- `devdeploy-workload` is running.
- `argocd/devdeploy-workloads-root` exists.
- The Root Application is `Synced` and `Healthy`, or at minimum is not `Degraded`.
- The backend API is reachable.
- The backend has the server-controlled GitOps repository configuration listed below.
- `DEVDEPLOY_STATUS_READER_MODE` is `kubernetes`.
- The backend can access the configured management and workload kubeconfigs.
- The configured kubeconfig contexts select `kind-devdeploy-mgmt` and `kind-devdeploy-workload` explicitly.
- `gitops/workloads/devdeploy-apps/apps/api-status-smoke-nginx` does not exist locally or on `origin/main`.
- No workload named `api-status-smoke-nginx` exists in `devdeploy-apps`.
- The Git working tree is clean before submission.

Do not manually mutate Kubernetes resources or force Argo CD synchronization during this test. Reconciliation must happen through the normal GitOps path.

Optional read-only preflight checks:

```powershell
git status

kubectl --context kind-devdeploy-mgmt `
  -n argocd `
  get application devdeploy-workloads-root

kubectl --context kind-devdeploy-workload `
  -n devdeploy-apps `
  get deployment,service,pod `
  -l app.kubernetes.io/name=api-status-smoke-nginx
```

The workload query should return no matching resources before the smoke test.

## Backend Local Development Configuration

Use server-controlled environment variables. Do not send repository paths, kubeconfig paths, or context names in API requests.

```text
DEVDEPLOY_GITOPS_REPO_ROOT=<LOCAL_DEVDEPLOY_HUB_REPO_PATH>
DEVDEPLOY_GITOPS_SOURCE_ROOT=gitops/workloads/devdeploy-apps
DEVDEPLOY_GITOPS_BRANCH=main
DEVDEPLOY_GITOPS_REMOTE=origin
DEVDEPLOY_GITOPS_REMOTE_BRANCH=main
DEVDEPLOY_STATUS_READER_MODE=kubernetes
DEVDEPLOY_ARGOCD_ROOT_APPLICATION_NAME=devdeploy-workloads-root
DEVDEPLOY_ARGOCD_NAMESPACE=argocd
DEVDEPLOY_WORKLOAD_NAMESPACE=devdeploy-apps
DEVDEPLOY_MGMT_KUBECONFIG=<PATH_TO_MANAGEMENT_KUBECONFIG>
DEVDEPLOY_MGMT_KUBECONFIG_CONTEXT=kind-devdeploy-mgmt
DEVDEPLOY_WORKLOAD_KUBECONFIG=<PATH_TO_WORKLOAD_KUBECONFIG>
DEVDEPLOY_WORKLOAD_KUBECONFIG_CONTEXT=kind-devdeploy-workload
```

One kubeconfig may be used for both paths when it contains both kind contexts. Keep both context variables explicit so the current kubeconfig context cannot direct a reader to the wrong cluster.

Example for a backend started from PowerShell:

```powershell
$env:DEVDEPLOY_GITOPS_REPO_ROOT = "<LOCAL_DEVDEPLOY_HUB_REPO_PATH>"
$env:DEVDEPLOY_GITOPS_SOURCE_ROOT = "gitops/workloads/devdeploy-apps"
$env:DEVDEPLOY_GITOPS_BRANCH = "main"
$env:DEVDEPLOY_GITOPS_REMOTE = "origin"
$env:DEVDEPLOY_GITOPS_REMOTE_BRANCH = "main"
$env:DEVDEPLOY_STATUS_READER_MODE = "kubernetes"
$env:DEVDEPLOY_ARGOCD_ROOT_APPLICATION_NAME = "devdeploy-workloads-root"
$env:DEVDEPLOY_ARGOCD_NAMESPACE = "argocd"
$env:DEVDEPLOY_WORKLOAD_NAMESPACE = "devdeploy-apps"
$env:DEVDEPLOY_MGMT_KUBECONFIG = "<PATH_TO_MANAGEMENT_KUBECONFIG>"
$env:DEVDEPLOY_MGMT_KUBECONFIG_CONTEXT = "kind-devdeploy-mgmt"
$env:DEVDEPLOY_WORKLOAD_KUBECONFIG = "<PATH_TO_WORKLOAD_KUBECONFIG>"
$env:DEVDEPLOY_WORKLOAD_KUBECONFIG_CONTEXT = "kind-devdeploy-workload"
```

Windows host paths are not automatically available to a backend running inside Kubernetes. For this smoke test, prefer a local development backend unless the repository and kubeconfigs are explicitly mounted into the backend container with appropriate read permissions.

The examples below use the management ingress URL `http://localhost:8080/api`. A host-side development backend may instead use `http://localhost:8000`.

## Authentication

Use an existing test account or register with placeholders only:

```powershell
$RegisterBody = @{
  email = "<USERNAME>"
  username = "<USERNAME>"
  password = "<PASSWORD>"
} | ConvertTo-Json

Invoke-RestMethod `
  -Method Post `
  -Uri "http://localhost:8080/api/v1/auth/register" `
  -ContentType "application/json" `
  -Body $RegisterBody
```

Login without printing the returned credential:

```powershell
$LoginBody = @{
  email = "<USERNAME>"
  password = "<PASSWORD>"
} | ConvertTo-Json

$LoginResponse = Invoke-RestMethod `
  -Method Post `
  -Uri "http://localhost:8080/api/v1/auth/login" `
  -ContentType "application/json" `
  -Body $LoginBody

$AccessToken = $LoginResponse.access_token
```

Do not print, log, or commit `$AccessToken`. Shared command examples use `<ACCESS_TOKEN>` instead of a real value.

## Submit The Deploy Request

```powershell
$Body = @{
  app_name = "api-status-smoke-nginx"
  image = "nginx:latest"
  replicas = 1
  container_port = 80
  service_port = 80
  service_type = "ClusterIP"
} | ConvertTo-Json

$DeployResponse = Invoke-RestMethod `
  -Method Post `
  -Uri "http://localhost:8080/api/v1/gitops/apps" `
  -Headers @{ Authorization = "Bearer <ACCESS_TOKEN>" } `
  -ContentType "application/json" `
  -Body $Body

$DeployResponse

$CommitSha = $DeployResponse.commit_sha
```

When using the local variable from the login step, replace the authorization value with `Bearer $AccessToken`.

Expected result:

- HTTP `202 Accepted`.
- `status` is `pushed_waiting_for_argocd`.
- `commit_sha` is present.
- The deploy response does not claim that the workload is deployed or healthy.

## Poll The Read-Only Status Endpoint

Poll for at most 90 seconds:

```powershell
for ($i = 0; $i -lt 30; $i++) {
  $StatusResponse = Invoke-RestMethod `
    -Method Get `
    -Uri "http://localhost:8080/api/v1/gitops/apps/api-status-smoke-nginx/status?commit_sha=$CommitSha" `
    -Headers @{ Authorization = "Bearer <ACCESS_TOKEN>" }

  $StatusResponse
  if ($StatusResponse.status -eq "deployed") { break }
  Start-Sleep -Seconds 3
}
```

Early responses may report:

- `pushed_waiting_for_argocd`
- `argocd_observing`
- `argocd_synced`
- `workload_progressing`

The final expected response reports:

- `status: deployed`
- `root_application.observed_commit_match: true`
- `workload.deployment_ready: true`
- `workload.service_ready: true`
- `workload.pods_ready: true`

The status request cannot override kubeconfig paths, contexts, namespaces, or cluster credentials.

## Optional Read-Only Cluster Verification

Inspect the Root Application without forcing reconciliation:

```powershell
kubectl --context kind-devdeploy-mgmt `
  -n argocd `
  get application devdeploy-workloads-root `
  -o json
```

Inspect only the smoke workload in the workload cluster:

```powershell
kubectl --context kind-devdeploy-workload `
  -n devdeploy-apps `
  get deployment,service,pod `
  -l app.kubernetes.io/name=api-status-smoke-nginx `
  -o wide
```

Expected live resources:

- Deployment `api-status-smoke-nginx` is ready at `1/1`.
- Service `api-status-smoke-nginx` is a `ClusterIP` service on port `80`.
- One selected Pod is `Running` and ready at `1/1`.

No Ingress is expected.

## Verify The Git Change

From `DEVDEPLOY_GITOPS_REPO_ROOT`, run:

```powershell
git log -1 --oneline
git show --name-only --stat HEAD
```

The commit should contain only:

```text
gitops/workloads/devdeploy-apps/kustomization.yaml
gitops/workloads/devdeploy-apps/apps/api-status-smoke-nginx/kustomization.yaml
gitops/workloads/devdeploy-apps/apps/api-status-smoke-nginx/deployment.yaml
gitops/workloads/devdeploy-apps/apps/api-status-smoke-nginx/service.yaml
```

The current revision should match `$CommitSha` when no later commit has advanced the branch.

## Troubleshooting

### HTTP 401 Unauthorized

The bearer credential is missing, expired, or invalid. Login again and retry without printing the credential.

### HTTP 400 Bad Request

The app name or commit SHA is invalid. Use the exact app name and the full commit SHA returned by the deploy response.

### HTTP 409 Conflict

The app folder may already exist, the Git worktree may contain conflicting changes, or the expected branch state may not match. Preserve unrelated work and inspect the safe response fields.

### `push_failed`

The remote may be unreachable, authentication may be unavailable, or the branch may reject the update. The backend does not force-push. Resolve repository access deliberately before retrying.

### `status_reader_unavailable`

Confirm Kubernetes reader mode, both kubeconfig paths, and both explicit contexts are configured for the backend process. Also confirm the paths are visible from that process.

### `permission_denied`

The management or workload reader identity lacks a required read permission. Correct the dedicated least-privilege read configuration; do not grant workload write access or cluster-admin.

### `pushed_waiting_for_argocd` Persists

Argo CD has not yet observed the returned commit. Wait for normal reconciliation and use the optional read-only Root Application query. Do not force synchronization.

### `workload_progressing` Persists

The Deployment, Service, or Pods are not ready yet. Use label-scoped, read-only workload diagnostics and inspect readiness conditions.

### `degraded`

Argo CD or the workload reports a known failure. Use approved read-only events or logs for diagnosis where available. Fix the source manifests through GitOps; do not mutate the live workload directly.

## Cleanup Limitation

The Root Application currently uses `prune=false`. Removing the app folder from Git is therefore not a complete or verified deletion flow and is not documented as cleanup here.

The smoke workload may remain until the separate delete and prune design is implemented. Do not manually remove its live resources as part of this procedure.

After testing, clear local authentication variables:

```powershell
Remove-Variable AccessToken -ErrorAction SilentlyContinue
Remove-Variable LoginResponse -ErrorAction SilentlyContinue
```

See [Argo CD Status Read Model Design](../architecture/argocd-status-read-model-design.md) for the read-only status contract and [GitOps API Smoke Test](./gitops-api-smoke-test.md) for the earlier deploy-only procedure.
