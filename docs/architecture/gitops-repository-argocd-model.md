# GitOps Repository Layout and Argo CD Application Model

## 1. Overview

This document defines the GitOps repository layout and Argo CD Application model for the DevDeploy Hub local-first multi-cluster architecture.

The higher-level architecture is defined in:

- [Multi-Cluster Redesign](./multi-cluster-redesign.md)
- [Bootstrapper / Launcher Design](./bootstrapper-launcher-design.md)
- [Setup Wizard Multi-Cluster Lifecycle Design](./setup-wizard-multi-cluster-lifecycle.md)

In the target architecture, DevDeploy platform components run in the management cluster named `devdeploy-mgmt`. User applications run only in the workload cluster named `devdeploy-workload`. Argo CD runs in `devdeploy-mgmt` and deploys user workloads to `devdeploy-workload`.

Normal workload deployment remains GitOps-only:

```text
UI -> Backend -> GitHub/GitOps Repository -> Argo CD -> Workload Kubernetes Cluster
```

The backend must not directly apply or delete normal user workloads in Kubernetes. GitHub Actions must not deploy directly to clusters. GitHub Actions is responsible for manifest generation, validation, and GitOps repository updates according to repository policy.

## 2. Design Goals

- Keep the first implementation simple and understandable.
- Preserve the existing generated workload path where possible.
- Make the workload GitOps area deterministic and easy to validate.
- Ensure generated user workloads deploy to `devdeploy-workload`, not `devdeploy-mgmt`.
- Keep Argo CD as the only Kubernetes applier for normal user workloads.
- Support both local MVP repository updates and stricter pull-request based policies.
- Keep the layout compatible with a future App of Apps model.
- Avoid moving or renaming existing generated workload paths during the design phase.

## 3. Non-Goals

- This document does not implement runtime code.
- This document does not move existing files.
- This document does not rename existing generated workload paths.
- This document does not require full App of Apps in the first implementation.
- This document does not add direct Kubernetes deployment behavior to the backend.
- This document does not allow GitHub Actions to run `kubectl apply`, `kubectl delete`, or equivalent cluster deployment commands for user workloads.
- This document does not define cloud provider cluster deployment.

## 4. Current Generated Workload Layout

The current generated workload path is:

```text
infra/kubernetes/generated/workloads/
```

Generated user app folders live under:

```text
infra/kubernetes/generated/workloads/apps/<app-name>/
```

Each generated app folder should consistently contain:

```text
deployment.yaml
service.yaml
kustomization.yaml
```

If ingress or external exposure is enabled, the folder may also contain:

```text
ingress.yaml
```

The parent generated workloads kustomization lives at:

```text
infra/kubernetes/generated/workloads/kustomization.yaml
```

It should list shared generated workload resources such as `namespace.yaml` and generated app folders.

## 5. Target Multi-Cluster GitOps Layout

V1 should keep the generated workload layout stable:

```text
infra/
  kubernetes/
    generated/
      workloads/
        namespace.yaml
        kustomization.yaml
        apps/
          <app-name>/
            deployment.yaml
            service.yaml
            ingress.yaml
            kustomization.yaml
```

The key multi-cluster rule is not the path itself, but the Argo CD destination:

- DevDeploy platform resources run in `devdeploy-mgmt`.
- Generated user workloads deploy to `devdeploy-workload`.

The parent generated workload kustomization should remain a workload-only surface. It must not include DevDeploy platform resources such as backend, frontend, PostgreSQL, Argo CD, monitoring, or logging components.

## 6. Initial Argo CD Application Model

V1 should use a simple parent Argo CD Application named:

```text
devdeploy-workloads
```

This Application should track:

```text
infra/kubernetes/generated/workloads
```

Its destination should be the workload cluster:

```text
devdeploy-workload
```

It must not deploy generated user workloads into `devdeploy-mgmt`.

The initial model keeps operational complexity low:

- One parent Application manages generated workloads.
- GitHub Actions updates generated manifests in Git.
- Argo CD syncs and prunes the generated workload tree.
- The backend and UI observe status through Argo CD, Kubernetes read-only APIs, and existing observability APIs.

## 7. Future App of Apps Compatible Model

The layout should remain compatible with a future App of Apps model.

In that future model, DevDeploy may create one Argo CD Application per user app. Application manifests may live under:

```text
infra/argocd/applications/workloads/apps/<app-name>-application.yaml
```

A parent Application may track:

```text
infra/argocd/applications/workloads
```

Per-app Argo CD Applications would allow cleaner:

- Per-app health.
- Per-app sync status.
- Per-app rollback.
- Per-app lifecycle history.
- Per-app pruning and deletion behavior.

The first implementation should not require this. The generated workload folder structure should be strict enough that each app folder can later become the source path for a dedicated Argo CD Application.

## 8. Workload Manifest Generation Rules

Generated app names must be Kubernetes-safe DNS labels.

Generated app folders must be placed under:

```text
infra/kubernetes/generated/workloads/apps/<app-name>/
```

Each generated app folder must include:

- `deployment.yaml`
- `service.yaml`
- `kustomization.yaml`

`ingress.yaml` should be generated only when ingress or exposure is explicitly enabled.

Generated workload manifests should include consistent labels:

- `app.kubernetes.io/name`
- `app.kubernetes.io/managed-by: devdeploy-hub`
- `devdeploy.io/application`

Generated workloads should use secure defaults:

- Non-root execution.
- Dropped Linux capabilities.
- `allowPrivilegeEscalation: false`.
- Resource requests and limits.
- `seccompProfile: RuntimeDefault`.
- ClusterIP Service by default.

The generator must not create manifests that reference platform secrets unless explicitly designed and reviewed.

## 9. Parent Kustomization Rules

The parent generated workload kustomization should live at:

```text
infra/kubernetes/generated/workloads/kustomization.yaml
```

It should list:

```yaml
resources:
  - namespace.yaml
  - apps/<app-name>
```

Rules:

- Include `namespace.yaml` deterministically.
- Include generated app folders deterministically.
- Sort app folders consistently to reduce Git diff noise.
- Do not list missing folders.
- Do not include platform resources.
- Do not include dev or release overlay resources directly.
- Keep generated app folders self-contained.

Each app folder kustomization should list only files that exist in that folder:

```yaml
resources:
  - deployment.yaml
  - service.yaml
```

If ingress is enabled:

```yaml
resources:
  - deployment.yaml
  - service.yaml
  - ingress.yaml
```

## 10. Argo CD Destination Rules

The `devdeploy-workloads` Application must deploy to `devdeploy-workload`.

Destination rules:

- User workload destination cluster: `devdeploy-workload`.
- User workload namespace: default generated workload namespace, such as `devdeploy-workloads`.
- Management cluster: `devdeploy-mgmt`.
- Platform components stay in `devdeploy-mgmt`.

The Argo CD Application must not use the management cluster as the destination for generated user workloads.

The source path for V1 should be:

```text
infra/kubernetes/generated/workloads
```

The destination should be configured through the Argo CD cluster registration created during setup.

## 11. Repository Update Policy

GitHub Actions may update the GitOps repository according to repository policy.

For MVP/local flows:

- GitHub Actions may commit generated manifest changes directly.
- Direct commits should still run validation before updating Git.

For stricter flows:

- GitHub Actions may open pull requests.
- Branch protection, CI checks, and review policies may gate merges.

In all modes:

- GitHub Actions must not deploy directly to Kubernetes.
- GitHub Actions must not run `kubectl apply` or `kubectl delete` for normal user workloads.
- GitHub Actions should generate, validate, and update Git only.
- Argo CD remains responsible for applying Git state to the workload cluster.

## 12. Delete Flow

Deletion should be GitOps-based.

The expected delete flow is:

```text
UI -> Backend -> GitHub Actions -> GitOps Repository -> Argo CD prune -> devdeploy-workload
```

Deletion steps:

1. User requests deletion in the UI.
2. Backend validates the request and dispatches the GitOps delete workflow or records manual instructions.
3. GitHub Actions removes:
   - `infra/kubernetes/generated/workloads/apps/<app-name>/`
4. GitHub Actions updates:
   - `infra/kubernetes/generated/workloads/kustomization.yaml`
5. GitHub Actions validates the rendered workload tree.
6. GitHub Actions updates Git according to repository policy.
7. Argo CD syncs and prunes the removed resources from `devdeploy-workload`.

The backend must not directly delete normal user workload resources from Kubernetes.

## 13. Demo App Flow

The demo app must use the same path as normal app deployment.

The expected demo flow is:

```text
Setup Wizard -> Backend -> GitHub Actions -> GitOps Repository -> Argo CD -> devdeploy-workload
```

The demo app should not be a special direct-deploy path.

The demo app should:

- Generate a normal app folder under `infra/kubernetes/generated/workloads/apps/<demo-app-name>/`.
- Update the parent generated workload kustomization.
- Be validated by the same manifest validation checks.
- Be synced by Argo CD to `devdeploy-workload`.
- Be deletable through the same GitOps delete flow.

## 14. Validation Rules

Generated workload changes should be validated before repository update.

Recommended validation:

- App name is Kubernetes-safe.
- Namespace is Kubernetes-safe.
- Image repository is from an allowed registry.
- Image tag is explicit and not `latest`.
- Container port is valid.
- Replica count is within allowed bounds.
- Generated app folder contains required files.
- App folder kustomization lists only existing files.
- Parent kustomization lists only existing resources.
- `kubectl kustomize infra/kubernetes/generated/workloads` succeeds.
- Release or workload overlay render succeeds if used.
- Static security checks pass for generated manifests.

Validation must not require deploying to a live cluster from GitHub Actions.

## 15. Security Boundaries

Security boundaries:

- Backend does not directly apply or delete normal user workloads.
- GitHub Actions does not deploy directly to clusters.
- Argo CD is the only applier for normal user workload resources.
- Generated workloads deploy to `devdeploy-workload`, not `devdeploy-mgmt`.
- Platform resources remain separate from generated user workloads.
- GitHub tokens and cluster credentials must not be committed to Git.
- Generated manifests must not contain raw secrets.
- Delete operations must modify Git state, not directly mutate Kubernetes state.
- Repository update policy should be explicit and auditable.

Emergency local developer actions may exist outside the product flow, but they must not become the normal deployment architecture.

## 16. V1 Implementation Recommendation

V1 should keep the model simple:

1. Keep generated user workloads under:

   ```text
   infra/kubernetes/generated/workloads/apps/<app-name>/
   ```

2. Keep one parent generated workloads kustomization:

   ```text
   infra/kubernetes/generated/workloads/kustomization.yaml
   ```

3. Use one parent Argo CD Application:

   ```text
   devdeploy-workloads
   ```

4. Configure `devdeploy-workloads` to deploy to:

   ```text
   devdeploy-workload
   ```

5. Let GitHub Actions generate, validate, and update Git according to repository policy.

6. Let Argo CD sync and prune workload resources.

7. Keep future App of Apps migration in mind, but do not require it for the first serious version.

This balances clarity, safety, and implementation speed.

## 17. Future Migration Path

The future App of Apps migration can happen incrementally.

Possible migration steps:

1. Keep existing generated app folders as workload sources.
2. Add per-app Argo CD Application manifests under:

   ```text
   infra/argocd/applications/workloads/apps/<app-name>-application.yaml
   ```

3. Add a parent Argo CD Application that tracks:

   ```text
   infra/argocd/applications/workloads
   ```

4. Move per-app lifecycle status from the single parent Application to individual app Applications.
5. Update backend and UI status mapping to prefer per-app Argo CD Application health when available.
6. Keep generated workload manifests in the same app folders unless a later repository layout migration is justified.

The migration should preserve the same security boundary: Git changes define desired state, and Argo CD applies that state to `devdeploy-workload`.
