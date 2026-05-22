# DevDeploy Hub GitOps Deployment Engine

## Purpose

The GitOps Deployment Request Engine turns a user deployment request into a reviewed Git manifest change.

The backend never deploys directly to Kubernetes. It stores the request and, when configured, triggers a GitHub Actions workflow. The workflow generates workload manifests and opens a pull request. After the PR is merged, Argo CD syncs the release overlay into the cluster.

## Concepts

A Service is the platform catalog record owned by a developer or team. The backend still uses application model/API names internally, but the product UI presents these records as the Services catalog.

A Deployment Request is an intent to run a container image as a Kubernetes workload. It includes the app name, image repository, image tag, namespace, port, replica count, and optional ingress host.

Generated workload manifests live under:

```text
infra/kubernetes/generated/workloads/apps/<app-name>
```

Generated workloads use the separate namespace:

```text
devdeploy-workloads
```

DevDeploy Hub platform resources remain in:

```text
devdeploy
```

## Flow

1. A user creates a GitOps deployment request from the frontend.
2. The backend validates and stores the request.
3. If GitHub dispatch is configured, the backend calls `workflow_dispatch` for `gitops-workload-request.yml`.
4. GitHub Actions runs `scripts/create-gitops-workload.py`.
5. The workflow renders `infra/kubernetes/overlays/release` and opens a PR.
6. Branch protection and CI validate the PR.
7. After merge, Argo CD syncs the release overlay.

## GitOps Deletion Flow

Deployments are deleted through Git, not through direct Kubernetes API writes.

1. A user requests deletion from the Deployments page.
2. The backend validates the workload name/namespace and stores the request state.
3. If GitHub dispatch is configured, the backend calls `workflow_dispatch` for `gitops-workload-delete.yml`.
4. GitHub Actions runs `scripts/delete-gitops-workload.py`.
5. The workflow removes `infra/kubernetes/generated/workloads/apps/<app-name>` and removes the app entry from `infra/kubernetes/generated/workloads/kustomization.yaml`.
6. The workflow renders `infra/kubernetes/overlays/release`, opens a pull request, and can attempt non-admin auto-merge.
7. After merge, Argo CD syncs the release overlay and removes the Kubernetes Deployment, Service, and optional Ingress.

Service catalog deletion is intentionally conservative. If a service has legacy deployment records, GitOps requests, or a matching live generated workload, the backend returns `409 Conflict` and asks the user to delete related deployments through GitOps first.

## Backend Configuration

Local development can keep GitOps dispatch disabled:

```text
GITOPS_ENABLED=false
```

Automatic workflow dispatch requires:

```text
GITOPS_ENABLED=true
GITOPS_AUTO_MERGE=true
GITHUB_OWNER=Kaan-YASSIBAS
GITHUB_REPO=devdeploy-hub
GITOPS_WORKFLOW_FILE=gitops-workload-request.yml
GITOPS_TARGET_REF=main
```

In Kubernetes, these non-secret values come from `devdeploy-config`.

The GitHub workflow token must not be stored in Git. `devdeploy-secret` is managed by Argo CD and contains normal app, database, and JWT secrets only. If a real token is added there manually, Argo CD will remove it during reconciliation.

Automatic dispatch reads `GITHUB_WORKFLOW_TOKEN` from a separate cluster-local secret:

```text
devdeploy-gitops-secret
```

Create it manually, or later through an external secret manager:

```powershell
$githubToken = "PASTE_TOKEN_HERE"

kubectl create secret generic devdeploy-gitops-secret `
  -n devdeploy `
  --from-literal=GITHUB_WORKFLOW_TOKEN="$githubToken" `
  --dry-run=client -o yaml | kubectl apply -f -

Remove-Variable githubToken
```

Bash:

```bash
kubectl create secret generic devdeploy-gitops-secret \
  -n devdeploy \
  --from-literal=GITHUB_WORKFLOW_TOKEN="<token>" \
  --dry-run=client -o yaml | kubectl apply -f -
```

The backend Deployment references this secret with `optional: true`, so the platform still starts if the token is missing. In that case, GitOps deployment creation fails gracefully with a configuration error and asks the user to contact the platform administrator.

The token is never returned by the API, should not be logged, and should not be printed while checking the cluster.

## Manual Fallback

If `GITOPS_ENABLED=false` or `GITHUB_WORKFLOW_TOKEN` is missing, the backend stores the request as `pending_manual_trigger`. The frontend presents this as deployment automation being unavailable for normal users.

Run manually:

```text
Actions -> GitOps Workload Request -> Run workflow
```

Then enter:

```text
app_name
image
tag
namespace
container_port
replicas
ingress_host
```

To delete a generated workload manually:

```text
Actions -> GitOps Workload Delete -> Run workflow
```

Then enter:

```text
app_name
namespace
auto_merge
```

## Generator

Local example:

```powershell
python scripts/create-gitops-workload.py `
  --app-name demo-api `
  --image ghcr.io/kaan-yassibas/demo-api `
  --tag v1.0.0 `
  --namespace devdeploy-workloads `
  --container-port 8000 `
  --replicas 1
```

Validate:

```powershell
kubectl kustomize infra/kubernetes/overlays/release
```

Remove the generated demo workload after local testing unless it is intentionally part of the release.

## Security Constraints

- The backend does not run `kubectl apply`.
- The backend does not delete Kubernetes resources directly.
- The backend does not need Kubernetes write RBAC.
- Generated workloads are reviewed through pull requests.
- Branch protection checks run before merge.
- `latest` image tags are rejected.
- Replica count is limited to `1-5`.
- Container ports must be `1024-65535` for non-root compatibility.
- Generated workload containers drop Linux capabilities and disallow privilege escalation.

Observability RBAC remains read-only and separate from deployment request handling.

## Automatic Release Promotion

Release image promotion is also GitOps-based. CI never applies manifests directly to the cluster.

1. Create and push a semantic version tag:

```powershell
git tag v1.3.0
git push origin v1.3.0
```

2. `container-publish.yml` builds and pushes:

```text
ghcr.io/kaan-yassibas/devdeploy-backend:v1.3.0
ghcr.io/kaan-yassibas/devdeploy-frontend:v1.3.0
```

3. After both image builds succeed, `container-publish.yml` calls `gitops-promotion.yml` with the same tag.
4. `gitops-promotion.yml` runs `scripts/promote-release-images.py`, updates `infra/kubernetes/overlays/release/kustomization.yaml`, and opens a pull request.
5. If `auto_merge=true`, the workflow tries `gh pr merge --auto --squash`. If auto-merge cannot be enabled and the PR is immediately mergeable, it tries a direct squash merge without `--admin`.
6. After merge, Argo CD syncs the release overlay and deploys the new image tags.

Manual fallback remains available:

```text
Actions -> GitOps Promotion -> Run workflow -> image_tag = v1.3.0
```

This preserves the GitOps contract: CI writes Git and opens or merges a reviewed PR; Argo CD is the only component that applies the merged desired state to Kubernetes.
