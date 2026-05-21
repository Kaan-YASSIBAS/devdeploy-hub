# DevDeploy Hub GitOps Deployment Engine

## Purpose

The GitOps Deployment Request Engine turns a user deployment request into a reviewed Git manifest change.

The backend never deploys directly to Kubernetes. It stores the request and, when configured, triggers a GitHub Actions workflow. The workflow generates workload manifests and opens a pull request. After the PR is merged, Argo CD syncs the release overlay into the cluster.

## Concepts

An Application is the platform catalog record owned by a developer or team.

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

## Backend Configuration

Local development can keep GitOps dispatch disabled:

```text
GITOPS_ENABLED=false
```

Automatic workflow dispatch requires:

```text
GITOPS_ENABLED=true
GITHUB_OWNER=Kaan-YASSIBAS
GITHUB_REPO=devdeploy-hub
GITOPS_WORKFLOW_FILE=gitops-workload-request.yml
GITHUB_WORKFLOW_TOKEN=<token with workflow dispatch access>
GITOPS_TARGET_REF=main
```

The token is never returned by the API and should not be logged.

## Manual Fallback

If `GITOPS_ENABLED=false` or `GITHUB_WORKFLOW_TOKEN` is missing, the backend stores the request as `pending_manual_trigger` and returns the exact workflow inputs.

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
- The backend does not need Kubernetes write RBAC.
- Generated workloads are reviewed through pull requests.
- Branch protection checks run before merge.
- `latest` image tags are rejected.
- Replica count is limited to `1-5`.
- Container ports must be `1024-65535` for non-root compatibility.
- Generated workload containers drop Linux capabilities and disallow privilege escalation.

Observability RBAC remains read-only and separate from deployment request handling.
