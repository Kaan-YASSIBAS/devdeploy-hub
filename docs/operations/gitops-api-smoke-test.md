# GitOps Deploy API Smoke Test

## Purpose

This procedure verifies the API-level GitOps deployment path end to end:

```text
POST /api/v1/gitops/apps
  -> generate workload manifests
  -> create a local Git commit
  -> push the commit to origin/main
  -> Argo CD reconciles the Root Application
  -> devdeploy-workload/devdeploy-apps receives the workload
```

The API reports repository publication as `pushed_waiting_for_argocd`. It does not claim that the workload is deployed or healthy. Argo CD remains the workload deployment actor.

This test creates the known sample workload `api-smoke-nginx`. Run it only in a disposable or explicitly approved local environment.

## Preconditions

Before starting, verify:

- `devdeploy-mgmt` is running.
- `devdeploy-workload` is running.
- The backend API is reachable.
- A DevDeploy Hub user can authenticate and obtain a bearer token.
- `argocd/devdeploy-workloads-root` is `Synced` and `Healthy`.
- The Git working tree is clean.
- The configured `origin/main` is reachable and the backend Git identity can push to it.
- `gitops/workloads/devdeploy-apps/apps/api-smoke-nginx` does not exist locally or on `origin/main`.
- No Deployment, Service, or Pod named `api-smoke-nginx` already exists in `devdeploy-apps`.

Use read-only checks before the API request:

```powershell
git status

kubectl --context kind-devdeploy-mgmt `
  -n argocd `
  get application devdeploy-workloads-root

kubectl --context kind-devdeploy-workload `
  -n devdeploy-apps `
  get deployment,service,pod `
  -l app.kubernetes.io/name=api-smoke-nginx
```

Do not use `kubectl apply` or force an Argo CD sync during this procedure.

## Backend Configuration

The API uses server-controlled Git settings:

| Environment variable | Smoke-test value |
| --- | --- |
| `DEVDEPLOY_GITOPS_REPO_ROOT` | Absolute path to the local Git worktree |
| `DEVDEPLOY_GITOPS_SOURCE_ROOT` | `gitops/workloads/devdeploy-apps` |
| `DEVDEPLOY_GITOPS_BRANCH` | `main` |
| `DEVDEPLOY_GITOPS_REMOTE` | `origin` |
| `DEVDEPLOY_GITOPS_REMOTE_BRANCH` | `main` |
| `DEVDEPLOY_STATUS_READER_MODE` | `kubernetes` |
| `DEVDEPLOY_MGMT_KUBECONFIG` | Absolute path to the server-side kubeconfig |
| `DEVDEPLOY_MGMT_KUBECONFIG_CONTEXT` | `kind-devdeploy-mgmt` |
| `DEVDEPLOY_WORKLOAD_KUBECONFIG` | Absolute path to the server-side kubeconfig |
| `DEVDEPLOY_WORKLOAD_KUBECONFIG_CONTEXT` | `kind-devdeploy-workload` |

Example for a backend started from PowerShell:

```powershell
$env:DEVDEPLOY_GITOPS_REPO_ROOT = "<REPOSITORY_ROOT>"
$env:DEVDEPLOY_GITOPS_SOURCE_ROOT = "gitops/workloads/devdeploy-apps"
$env:DEVDEPLOY_GITOPS_BRANCH = "main"
$env:DEVDEPLOY_GITOPS_REMOTE = "origin"
$env:DEVDEPLOY_GITOPS_REMOTE_BRANCH = "main"
$env:DEVDEPLOY_STATUS_READER_MODE = "kubernetes"
$env:DEVDEPLOY_MGMT_KUBECONFIG = "<KUBECONFIG_PATH>"
$env:DEVDEPLOY_MGMT_KUBECONFIG_CONTEXT = "kind-devdeploy-mgmt"
$env:DEVDEPLOY_WORKLOAD_KUBECONFIG = "<KUBECONFIG_PATH>"
$env:DEVDEPLOY_WORKLOAD_KUBECONFIG_CONTEXT = "kind-devdeploy-workload"
```

`DEVDEPLOY_GITOPS_REPO_ROOT` must be accessible from the backend process. A Windows path such as `C:\Users\...` is not automatically available to a backend container running in Kubernetes.

When one kubeconfig contains both kind clusters, keep the explicit context values above even if the current host context appears correct. Context selection is server-controlled and is not accepted from API requests.

For this smoke test, prefer running the backend in local development mode from the selected worktree. An in-cluster backend is suitable only when that worktree is explicitly mounted into the container and the container has the required Git identity. Do not place a Git token in the API request or generated manifests.

The management ingress normally exposes the backend at `http://localhost:8080/api`. A host-side development backend normally listens at `http://localhost:8000`; use the URL of the process that has access to `DEVDEPLOY_GITOPS_REPO_ROOT`.

## Authentication

If a test user is needed, register through the existing JSON endpoint. Replace every placeholder before running the command:

```powershell
$RegisterBody = @{
  email = "<EMAIL>"
  username = "<USERNAME>"
  password = "<PASSWORD>"
} | ConvertTo-Json

Invoke-RestMethod `
  -Method Post `
  -Uri "http://localhost:8080/api/v1/auth/register" `
  -ContentType "application/json" `
  -Body $RegisterBody
```

Login with the JSON endpoint:

```powershell
$LoginBody = @{
  email = "<EMAIL>"
  password = "<PASSWORD>"
} | ConvertTo-Json

$LoginResponse = Invoke-RestMethod `
  -Method Post `
  -Uri "http://localhost:8080/api/v1/auth/login" `
  -ContentType "application/json" `
  -Body $LoginBody

$AccessToken = $LoginResponse.access_token
```

Alternatively, `/api/v1/auth/token` accepts OAuth form data. The `username` value is the user's email:

```powershell
$TokenResponse = Invoke-RestMethod `
  -Method Post `
  -Uri "http://localhost:8080/api/v1/auth/token" `
  -ContentType "application/x-www-form-urlencoded" `
  -Body @{ username = "<USERNAME>"; password = "<PASSWORD>" }

$AccessToken = $TokenResponse.access_token
```

Do not print, log, or commit `$AccessToken`. Use `<ACCESS_TOKEN>` in shared examples and clear the local variable after the test.

## Submit The Workload

The required request is:

```powershell
$Body = @{
  app_name = "api-smoke-nginx"
  image = "nginx:latest"
  replicas = 1
  container_port = 80
  service_port = 80
  service_type = "ClusterIP"
} | ConvertTo-Json

$Response = Invoke-RestMethod `
  -Method Post `
  -Uri "http://localhost:8080/api/v1/gitops/apps" `
  -Headers @{ Authorization = "Bearer <ACCESS_TOKEN>" } `
  -ContentType "application/json" `
  -Body $Body

$Response | Format-List
```

When using the token variable from the authentication step, replace the header with:

```powershell
-Headers @{ Authorization = "Bearer $AccessToken" }
```

For a host-side backend on its default development port, change the URI to `http://localhost:8000/api/v1/gitops/apps`.

Expected response:

- HTTP `202 Accepted`.
- `status` is `pushed_waiting_for_argocd`.
- `commit_sha` contains the pushed Git revision.
- `namespace` is `devdeploy-apps`.
- The response does not claim the workload is deployed or healthy.

Retain the response SHA for read-only verification:

```powershell
$ExpectedCommit = $Response.commit_sha
```

## Verify Git

From `DEVDEPLOY_GITOPS_REPO_ROOT`, run:

```powershell
git status
git log -1 --oneline
git show --name-only --stat HEAD
```

The latest commit message should be:

```text
deploy: add api-smoke-nginx workload
```

The commit should contain only:

```text
gitops/workloads/devdeploy-apps/kustomization.yaml
gitops/workloads/devdeploy-apps/apps/api-smoke-nginx/kustomization.yaml
gitops/workloads/devdeploy-apps/apps/api-smoke-nginx/deployment.yaml
gitops/workloads/devdeploy-apps/apps/api-smoke-nginx/service.yaml
```

Confirm the local revision matches the API response:

```powershell
$LocalCommit = git rev-parse HEAD
$LocalCommit -eq $ExpectedCommit
```

The working tree should be clean after the successful commit and push.

## Verify Argo CD

Read the Root Application without forcing a sync:

```powershell
$Application = kubectl --context kind-devdeploy-mgmt `
  -n argocd `
  get application devdeploy-workloads-root `
  -o json | ConvertFrom-Json

$Application.status.sync.status
$Application.status.health.status
$Application.status.sync.revision
```

Expected after automatic reconciliation:

- `status.sync.status` is `Synced`.
- `status.health.status` is `Healthy`.
- `status.sync.revision` equals `$ExpectedCommit` or advances to a later revision that contains that commit.

If the revision has not advanced yet, wait for the normal Argo CD refresh and rerun the read-only command. Do not force a sync in this phase.

## Verify The Workload

After Argo CD reports the expected revision, run:

```powershell
kubectl --context kind-devdeploy-workload `
  -n devdeploy-apps `
  get deployment,service,pod `
  -l app.kubernetes.io/name=api-smoke-nginx `
  -o wide
```

Expected:

- Deployment `api-smoke-nginx` is `READY 1/1`.
- Service `api-smoke-nginx` is `ClusterIP` on port `80`.
- The selected Pod is `Running` and `READY 1/1`.

No Ingress is expected in this phase.

## Troubleshooting

### HTTP 401 Unauthorized

The bearer token is missing, expired, or invalid. Login again and retry with the new token. Do not print the token while diagnosing the request.

### HTTP 400 Or 409

The workload input may be invalid, the app folder may already exist, the branch may be wrong, or the worktree may contain unrelated changes. Inspect the safe `status`, `message`, and `error_code` fields. Preserve unrelated local changes; do not stage or discard them to make the smoke test pass.

### `push_failed`

The remote may have rejected the update, authentication may be unavailable, or `origin/main` may have advanced. The backend never force-pushes or automatically rebases arbitrary edits. Resolve the repository state deliberately before retrying.

### Root Application Has Not Updated

Wait for the normal Argo CD refresh interval and rerun the read-only Application query. Do not force sync.

### Backend Cannot Access The Repository

An in-cluster backend cannot directly use an unmounted Windows host path. Run the backend locally for this smoke test or defer execution until an explicit repository-mount design exists.

### Nginx Pod Is Not Ready

Use read-only diagnostics:

```powershell
kubectl --context kind-devdeploy-workload `
  -n devdeploy-apps `
  describe deployment api-smoke-nginx

kubectl --context kind-devdeploy-workload `
  -n devdeploy-apps `
  get events --sort-by=.metadata.creationTimestamp

kubectl --context kind-devdeploy-workload `
  -n devdeploy-apps `
  logs deployment/api-smoke-nginx
```

Do not patch or apply workload resources manually. Correct workload definitions through the GitOps flow.

## Cleanup And Current Limitation

The Root Application currently uses `prune=false`. Removing the app folder from Git does not safely establish that live resources were deleted, so this procedure does not include a cleanup command.

Leave `api-smoke-nginx` as a known local test workload, or handle it only after the separate delete/prune design is implemented. Do not manually delete the workload as part of this phase.

After the test, clear local token variables:

```powershell
Remove-Variable AccessToken -ErrorAction SilentlyContinue
Remove-Variable LoginResponse -ErrorAction SilentlyContinue
Remove-Variable TokenResponse -ErrorAction SilentlyContinue
```

For the endpoint and repository safety model, see [Backend GitOps Commit Flow Design](../architecture/backend-gitops-commit-flow-design.md). For launcher and Root Application operations, see [DevDeploy Launcher Preflight](./devdeploy-launcher.md).
