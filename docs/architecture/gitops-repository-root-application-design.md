# GitOps Repository and Root Application Design

## 1. Overview

This document defines the V1 GitOps repository setup and first Argo CD Root Application model for the DevDeploy Hub local-first multi-cluster architecture.

It builds on:

- [Multi-Cluster Redesign](./multi-cluster-redesign.md)
- [Setup Wizard Multi-Cluster Lifecycle](./setup-wizard-multi-cluster-lifecycle.md)
- [GitOps Repository Layout and Argo CD Application Model](./gitops-repository-argocd-model.md)
- [Workload Cluster Registration Design](./workload-cluster-registration-design.md)
- [GitOps Workload Permission Design](./gitops-workload-permission-design.md)
- [Security and Credentials Boundaries](./security-credentials-boundaries.md)

The primary V1 product flow is:

```text
Setup Wizard -> GitHub GitOps repository -> Argo CD -> devdeploy-workload/devdeploy-apps
```

The backend may create or update Git state through an explicit GitHub integration. It must not directly apply, patch, or delete normal user workloads in Kubernetes. GitHub Actions may generate and validate manifests and update the GitOps repository according to repository policy, but must not deploy directly to a cluster. Argo CD remains the only normal workload applier.

This phase is documentation only. It does not create a repository, Argo CD resource, manifest tree, or workload.

## 2. Current State

The current runtime baseline is:

- Argo CD is installed in `devdeploy-mgmt` in namespace `argocd`.
- The Argo CD UI is available at `http://localhost:8080/argocd`.
- `devdeploy-workload` is registered through `argocd/argocd-cluster-devdeploy-workload`.
- The registered destination endpoint is `https://devdeploy-workload-control-plane:6443`.
- The registration identity is `kube-system/devdeploy-argocd-manager`.
- Argo CD has reviewed, namespace-scoped workload permissions only in `devdeploy-apps`.
- The namespaced Role and RoleBinding are named `devdeploy-argocd-deployer`.
- Writes outside `devdeploy-apps`, RBAC management, CRD management, namespace management, and cluster-admin access are denied.
- The Argo CD Application count is `0`.
- No GitOps Root Application exists yet.
- `platform_bootstrap.status` remains `partial`.

Repository configuration and Root Application creation are the next boundaries. They must not weaken the workload authorization model already verified in Phase 2H.

## 3. Product-Level Repository Model

The primary V1 product model uses a GitHub repository selected or created through the Setup Wizard. The user should not need to manually create repository directories, configure Argo CD repository access, author an Argo CD Application, or run `kubectl` or Helm commands.

The Setup Wizard offers two repository modes:

1. Create a new GitOps repository.
2. Use an existing GitOps repository.

In either mode, DevDeploy Hub:

1. Verifies the authorized GitHub identity and repository access.
2. Resolves the repository owner, name, default branch, and managed source path.
3. Initializes or validates the deterministic GitOps directory structure.
4. Stores sanitized repository metadata and a credential reference.
5. Configures Argo CD repository access without exposing credentials.
6. Creates or verifies the Root Application after all prerequisites are ready.

A path in the DevDeploy product repository may remain available for development or demonstrations. It is not the primary end-user model and must not make product setup depend on a source checkout on the user's host.

## 4. CD and CI Boundary

V1 focuses on continuous delivery:

```text
UI -> Backend -> GitHub GitOps repository -> Argo CD -> devdeploy-workload/devdeploy-apps
```

The user initially supplies an already available image reference, for example:

```text
nginx:1.27
ghcr.io/example/payment-api:v1.0.0
registry.example.com/team/app:2026.07.02
```

The backend validates the deployment request, generates Kubernetes manifests, and updates the configured GitOps repository. Argo CD observes the Git change and reconciles the declared resources into `devdeploy-apps`.

Full continuous integration is a later phase. It may add:

- Source repository connections.
- GitHub Actions workflow generation.
- Container image builds.
- Registry pushes and image tag promotion.
- Build logs and status.
- Registry credential management.

CI additions must preserve the same boundary: GitHub Actions can update Git state but cannot receive cluster credentials or deploy directly to Kubernetes.

## 5. Repository Setup Modes

### 5.1 Create a new repository

Example repository names include:

```text
devdeploy-gitops
devdeploy-workloads
<user-selected-name>
```

Flow:

1. The user authorizes GitHub through the Setup Wizard.
2. The user selects an account or allowed organization and chooses a repository name and visibility.
3. The backend creates the repository through the GitHub API using the minimum required permission scope.
4. The backend initializes the default branch and V1 GitOps directory structure.
5. The backend records sanitized repository metadata in workspace settings.
6. The Root Application uses the initialized repository, branch, and source path.

Repository creation must be idempotent. If a repository with the requested name already exists, setup must stop with a clear choice to select it as an existing repository or choose a different name. It must not overwrite repository contents.

### 5.2 Use an existing repository

Flow:

1. The user selects an accessible repository or supplies its owner and name.
2. The backend verifies read and write access without logging credentials.
3. The backend verifies the selected branch and managed path.
4. If the managed path is absent, the backend proposes initialization.
5. If the path exists, the backend validates its structure before adopting it.
6. The Root Application uses the verified repository, branch, and source path.

DevDeploy Hub must fail closed when existing files conflict with the expected managed layout. It must not silently replace unrelated content.

### 5.3 Repository metadata and credentials

Sanitized workspace metadata may include:

- Provider.
- Repository mode.
- Owner and repository name.
- Sanitized repository URL.
- Default branch.
- Managed source path.
- Repository and path readiness.
- A credential reference or configured boolean.

It must not include a GitHub token, token fragment, credential-bearing URL, or raw authentication header. Credential material belongs in the backend's approved Secret or encrypted credential storage model, never in Launcher status, frontend localStorage, Git, or logs.

### 5.4 Repository update policy

Repository updates follow the policy selected for the GitOps repository:

- A local MVP repository may allow validated direct commits to its default branch.
- A stricter repository may require a branch, pull request, checks, and review before merge.
- The selected policy should be recorded as workspace metadata and applied consistently to create, update, and delete requests.
- Every update must validate the generated kustomization before Git state is changed.

GitHub Actions may assist with manifest generation, validation, and repository updates. It must not receive cluster credentials or run `kubectl apply`, `kubectl delete`, Helm deployment commands, or equivalent direct cluster mutations. Argo CD remains the only normal workload applier in both repository modes.

## 6. V1 GitOps Directory Layout

The selected GitOps repository uses this V1 layout:

```text
gitops/
  workloads/
    devdeploy-apps/
      kustomization.yaml
      apps/
        .gitkeep
        <app-name>/
          kustomization.yaml
          deployment.yaml
          service.yaml
          ingress.yaml
```

Rules:

- `gitops/` separates generated delivery state from platform source code.
- `workloads/devdeploy-apps` mirrors the Launcher-owned destination namespace.
- `apps/<app-name>` gives each UI-created application a deterministic ownership boundary.
- `deployment.yaml`, `service.yaml`, and `kustomization.yaml` are required for a normal exposed or internal application deployment.
- `ingress.yaml` exists only when ingress exposure is requested.
- The root `kustomization.yaml` aggregates app directories deterministically.
- `.gitkeep` may preserve an empty `apps` directory before the first deployment.
- Setup must not deploy a sample workload unless the user explicitly requests the demo step.

An initial empty root kustomization is valid:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources: []
```

When applications exist, `resources` contains sorted relative paths such as `apps/payment-api`. Missing directories and duplicate entries are invalid.

The repository does not include a Namespace manifest for `devdeploy-apps`. Namespace ownership remains with the Launcher, and the Root Application uses `CreateNamespace=false`.

## 7. Root Application Model

The preferred V1 Root Application is:

| Field | Value |
| --- | --- |
| Name | `devdeploy-workloads-root` |
| Namespace | `argocd` |
| Project | `default` initially |
| Repository | Setup Wizard-selected GitOps repository |
| Revision | `main` |
| Source path | `gitops/workloads/devdeploy-apps` |
| Destination server | `https://devdeploy-workload-control-plane:6443` |
| Destination namespace | `devdeploy-apps` |

Conceptual specification:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: devdeploy-workloads-root
  namespace: argocd
spec:
  project: default
  source:
    repoURL: <sanitized-gitops-repository-url>
    targetRevision: main
    path: gitops/workloads/devdeploy-apps
  destination:
    server: https://devdeploy-workload-control-plane:6443
    namespace: devdeploy-apps
  syncPolicy:
    automated:
      prune: false
      selfHeal: true
    syncOptions:
      - CreateNamespace=false
```

The exact `repoURL` is configured at setup time. Credentials must be supplied to Argo CD through an approved repository credential Secret and must not be embedded in the Application.

### 7.1 Sync policy decision

- Automated sync is enabled so Git state drives V1 continuous delivery.
- `selfHeal=true` restores declared workload resources when they drift.
- `prune=false` is the safer initial MVP choice and prevents automatic deletion solely because a resource disappears from Git.
- `CreateNamespace=false` preserves Launcher ownership of `devdeploy-apps`.

With pruning disabled, a future GitOps delete operation cannot be considered complete until an explicit, separately reviewed prune policy is introduced. The UI must not claim that deleting Git state has removed a workload while pruning is disabled. A later safe-delete phase should define whether pruning is enabled globally, enabled only for reviewed delete operations, or performed through an explicit Argo CD action that preserves the GitOps boundary.

An optional manual-sync safe mode may be added later. It is not required for the first automated CD path.

## 8. AppProject Decision

### Option A: `default` AppProject

Advantages:

- Smallest initial implementation.
- No additional Argo CD policy resource is required.
- Easier bootstrap and recovery while the repository flow is being proven.

Limitations:

- The Argo CD policy boundary is less explicit.
- Source repository and destination restrictions are not dedicated to DevDeploy workloads.

### Option B: dedicated `devdeploy-workloads` AppProject

Advantages:

- Restricts allowed source repositories.
- Restricts destination to `devdeploy-workload/devdeploy-apps`.
- Can restrict resource kinds consistently with the reviewed workload RBAC model.
- Provides a clearer production-oriented ownership boundary.

Costs:

- Adds another bootstrap resource and verification contract.
- Requires careful source and destination reconciliation during repository changes.

### Decision

Design toward a dedicated `devdeploy-workloads` AppProject. The earliest MVP may use `default` only when this limitation is visible in setup status and documentation. A dedicated AppProject should be introduced in a separate explicit phase with future modes such as:

- `-BootstrapGitOpsAppProject`
- `-VerifyGitOpsAppProject`

This documentation phase does not create an AppProject.

## 9. Future Setup Modes and APIs

### 9.1 `-ConfigureGitOpsRepository`

This future explicit setup operation is responsible for:

- Creating or selecting a GitHub repository.
- Verifying GitHub access.
- Validating the branch and managed source path.
- Initializing the directory structure when authorized.
- Persisting sanitized repository status and a credential reference.

It must not create an Argo CD Application or user workload.

Although shown as a Launcher-style mode for lifecycle consistency, host execution is not inherently required for GitHub API operations. The final contract may be implemented through authenticated backend setup APIs coordinated by the Setup Wizard. It must remain explicit, idempotent, and separate from normal deployment requests.

### 9.2 `-BootstrapGitOpsRootApplication`

This future explicit mutating setup operation must:

1. Verify management Argo CD is ready.
2. Verify `devdeploy-workload` registration is ready.
3. Verify workload deployment permissions are ready and bounded to `devdeploy-apps`.
4. Verify GitOps repository access and source path readiness.
5. Create or reconcile only `argocd/devdeploy-workloads-root`.
6. Verify its repository, revision, path, destination, and sync policy.
7. Confirm that bootstrap did not create a user workload.

It must fail closed on destination, namespace, repository, or credential mismatches.

### 9.3 `-VerifyGitOpsRootApplication`

This future strict read-only operation must:

- Verify the Application exists.
- Verify source repository, target revision, and source path.
- Verify destination server and namespace.
- Verify the reviewed sync policy.
- Report sync and health status.
- Report Application inventory without requiring the total count to remain zero.
- Avoid repository, Application, or cluster mutation.

### 9.4 Future backend and UI deployment flow

After setup is complete:

1. The user creates an application deployment in the UI.
2. The backend validates the image and workload settings.
3. The backend generates files under `gitops/workloads/devdeploy-apps/apps/<app-name>/`.
4. The backend updates the parent kustomization deterministically.
5. The backend updates Git directly or dispatches repository automation according to repository policy.
6. Argo CD observes the Git revision and syncs it to `devdeploy-workload/devdeploy-apps`.

No backend Kubernetes write operation is introduced by this flow.

## 10. Status Contracts

### 10.1 GitOps repository

Launcher or setup status adds:

```text
platform_bootstrap.components.gitops_repository
```

Suggested shape:

```json
{
  "configured": false,
  "ready": false,
  "provider": "github",
  "mode": "create_new",
  "owner": null,
  "repo": null,
  "default_branch": "main",
  "repo_url_sanitized": null,
  "source_path": "gitops/workloads/devdeploy-apps",
  "path_initialized": false,
  "credentials_configured": false,
  "status": "not_started",
  "message": "GitOps repository setup has not started.",
  "checked_at": null
}
```

Stable `mode` values are `create_new` and `existing_repo`. Stable status values should follow the existing setup contract, such as `not_started`, `ready`, `warning`, and `error`.

### 10.2 GitOps Root Application

Launcher or setup status adds:

```text
platform_bootstrap.components.gitops_root_application
```

Suggested shape:

```json
{
  "bootstrapped": false,
  "ready": false,
  "application_name": "devdeploy-workloads-root",
  "application_namespace": "argocd",
  "project": "default",
  "source_repo_url_sanitized": null,
  "source_target_revision": "main",
  "source_path": "gitops/workloads/devdeploy-apps",
  "destination_cluster": "devdeploy-workload",
  "destination_server": "https://devdeploy-workload-control-plane:6443",
  "destination_namespace": "devdeploy-apps",
  "sync_policy": "automated",
  "prune_enabled": false,
  "self_heal_enabled": true,
  "create_namespace": false,
  "application_present": false,
  "sync_status": null,
  "health_status": null,
  "application_count": 0,
  "status": "not_started",
  "message": "GitOps Root Application has not been bootstrapped.",
  "checked_at": null
}
```

Status and logs may contain owner, repository name, sanitized URL, branch, path, resource names, and readiness values. They must not contain GitHub tokens, authorization headers, kubeconfig, Argo CD admin credentials, workload bearer tokens, certificates, private keys, CA data, cluster Secret configuration, or raw repository credential Secret data.

## 11. Security Boundaries

- The Root Application targets only `devdeploy-workload/devdeploy-apps`.
- `CreateNamespace=false`; the Launcher remains namespace owner.
- No cluster-admin, cluster-wide workload write, RBAC management, CRD management, or namespace management is granted.
- GitHub tokens use the minimum scopes needed for the selected repository operation. Broad organization administration is avoided.
- GitHub tokens are never placed in manifests, status, logs, URLs, frontend localStorage, or Git.
- Repository URLs are sanitized before storage or display when credentials could be embedded.
- Argo CD repository credentials are stored through an approved Kubernetes Secret or credential-template model, not in the Application spec.
- Setup does not deploy a user workload unless the user explicitly requests the demo step.
- `prune=false` reduces initial destructive risk; delete semantics remain incomplete until a safe prune policy is explicitly implemented.
- Backend and GitHub Actions do not apply, delete, patch, scale, or restart normal user workloads directly.
- Argo CD remains the only normal Kubernetes applier.

## 12. Failure and Recovery Rules

- Repository creation failure leaves Root Application bootstrap blocked and retryable.
- Existing repository conflicts fail closed without overwriting files.
- A missing or invalid managed path prevents Root Application creation.
- A destination mismatch prevents Application reconciliation.
- An unavailable workload registration or failed permission boundary prevents Application creation.
- A repository credential failure reports sanitized status without echoing provider responses that may contain sensitive data.
- Partial repository initialization must be detectable and safe to retry.
- An existing Root Application with unexpected ownership or destination must not be silently replaced.
- Setup recovery must not delete repositories, clusters, namespaces, or workloads automatically.

## 13. Implementation Sequence

1. Implement authenticated GitHub connection and minimum-scope credential storage.
2. Implement create-new and existing-repository validation through explicit setup APIs.
3. Implement deterministic GitOps path initialization without deploying a workload.
4. Add `platform_bootstrap.components.gitops_repository` status.
5. Decide whether the earliest MVP uses `default` or a dedicated AppProject.
6. Implement guarded Root Application bootstrap after registration and permission verification are ready.
7. Implement strict read-only Root Application verification.
8. Add Setup Wizard progress and recovery states.
9. Validate an explicitly requested demo app through the same GitOps path.
10. Design safe prune/delete behavior before presenting GitOps deletion as complete.

## 14. Non-Goals

- No Launcher runtime changes.
- No Argo CD Application or AppProject creation.
- No GitHub repository creation.
- No repository credential creation.
- No GitOps manifest generation.
- No backend or frontend changes.
- No user workload or demo deployment.
- No Kubernetes resource mutation.
- No cluster mutation.
- No full CI/image-build automation.
