# Phase 2 Implementation Roadmap

## 1. Overview

This document defines the practical implementation roadmap for moving DevDeploy Hub from the current single-cluster/local setup toward the local-first multi-cluster architecture.

The Phase 2 architecture baseline is defined in:

- [Multi-Cluster Redesign](./multi-cluster-redesign.md)
- [Bootstrapper / Launcher Design](./bootstrapper-launcher-design.md)
- [Setup Wizard Multi-Cluster Lifecycle Design](./setup-wizard-multi-cluster-lifecycle.md)
- [GitOps Repository Layout and Argo CD Application Model](./gitops-repository-argocd-model.md)
- [Localhost Networking and Port Strategy](./localhost-networking-port-strategy.md)
- [Workload Observability and Status Model](./workload-observability-status-model.md)
- [Security Boundaries and Credentials Model](./security-credentials-boundaries.md)

The target architecture uses:

- `devdeploy-mgmt` for DevDeploy platform components.
- `devdeploy-workload` for user applications.
- Argo CD in `devdeploy-mgmt` deploying user workloads to `devdeploy-workload`.

Normal workload deployment remains GitOps-only:

```text
UI -> Backend -> GitHub/GitOps Repository -> Argo CD -> Workload Kubernetes Cluster
```

The backend must not directly apply, delete, patch, scale, or restart normal user workloads. GitHub Actions must not deploy directly to clusters. GitHub Actions updates the GitOps repository according to repository policy.

## 2. Roadmap Goals

- Convert the architecture design into small, reviewable runtime milestones.
- Avoid a big-bang rewrite.
- Keep the existing DevDeploy Hub codebase and evolve it incrementally.
- Preserve the current GitOps deployment flow while redirecting the target architecture toward `devdeploy-workload`.
- Introduce a script-first Bootstrapper / Launcher before any graphical launcher.
- Use deterministic kind configs and predictable localhost ports.
- Keep the first Argo CD model simple with one parent Application named `devdeploy-workloads`.
- Preserve compatibility with a future App of Apps model.
- Keep security boundaries explicit through the implementation.

## 3. Non-Goals

- Do not implement full App of Apps immediately.
- Do not implement a graphical Launcher immediately.
- Do not implement existing-cluster onboarding yet.
- Do not introduce cloud provider support yet.
- Do not move every manifest immediately.
- Do not replace the existing backend/frontend architecture.
- Do not make GitHub Actions deploy directly to Kubernetes.
- Do not give the backend normal workload write permissions.
- Do not store secrets in frontend localStorage or Git.

## 4. Current Baseline

The current baseline already includes:

- Working full-stack DevDeploy Hub.
- Docker Compose support.
- Kubernetes manifests.
- Argo CD GitOps setup.
- GitOps deployment request flow.
- GitHub Actions manifest generation and GitOps repository updates.
- Generated workload structure under `infra/kubernetes/generated/workloads`.
- Live dashboard, deployments, logs, monitoring, and settings integrations.
- Setup Wizard foundation.
- Setup preflight endpoint.
- Runtime-aware preflight behavior.
- Security scanning and dependency hardening.
- Green CI baseline.

Phase 2A is the documentation/design baseline. Runtime implementation should begin only after the Phase 2A roadmap and design documents are committed.

## 5. Phase 2 Implementation Principles

- Prefer small, testable changes.
- Keep documentation commits separate from runtime commits.
- Keep frontend, backend, and infrastructure changes separate unless a milestone requires a coordinated change.
- Keep the normal workload path GitOps-only.
- Keep Launcher-owned host checks separate from in-cluster backend checks.
- Keep runtime behavior honest about whether it is running on the host or inside Kubernetes.
- Make partial setup states explicit and recoverable.
- Validate generated files before using them.
- Do not silently choose random user-facing ports.
- Do not hide warnings behind successful states.

## 6. Recommended Implementation Sequence

Recommended sequence:

0. Complete Phase 2A documentation baseline.
1. Add Bootstrapper / Launcher command contract document or script skeleton.
2. Add deterministic kind config generation preview for `devdeploy-mgmt` and `devdeploy-workload`.
3. Add or adjust host preflight to match the Launcher responsibility model.
4. Implement management cluster creation and verification in the Launcher.
5. Deploy or verify DevDeploy platform components in `devdeploy-mgmt`.
6. Implement workload cluster creation and verification in the Launcher.
7. Register `devdeploy-workload` in Argo CD running in `devdeploy-mgmt`.
8. Create or verify parent Argo CD Application `devdeploy-workloads` targeting `devdeploy-workload`.
9. Update Setup Wizard to show runtime, Launcher, management cluster, workload cluster, GitOps, Argo CD, and demo statuses.
10. Run demo app deployment through the normal GitOps path.
11. Add read-only workload observability and status mapping.
12. Perform security, credential, and logging hardening pass.

## 7. Phase 2B - Bootstrapper Contract and Host Preflight

Goal:

- Define and implement the first explicit host-side Launcher contract.

Recommended tasks:

- Add a script-first Launcher entry point, likely PowerShell for Windows V1.
- Define the Launcher status output shape.
- Define where sanitized setup status is written.
- Define how the backend reads or receives Launcher status.
- Update preflight to distinguish Launcher-provided host checks from in-cluster runtime checks.
- Keep checks read-only in this phase.

Expected output:

- Launcher can report Docker, kind, kubectl, git, helm, and port check status.
- Backend and Setup Wizard can distinguish `host`, `kubernetes`, and `unknown` runtime modes.
- Missing host tools are not falsely reported when checks run inside the backend pod.

## 8. Phase 2C - Kind Config Generation and Port Strategy

Goal:

- Generate deterministic kind config previews for both clusters.

Recommended tasks:

- Add kind config generation for `devdeploy-mgmt`.
- Add kind config generation for `devdeploy-workload`.
- Use stable ports from the localhost networking strategy.
- Validate that generated configs are deterministic.
- Add a preview mode before create mode.
- Surface selected ports in setup status.

Expected defaults:

- Management API: `127.0.0.1:58080`
- Management HTTP: `127.0.0.1:8080`
- Management HTTPS: `127.0.0.1:8443`
- Workload API: `127.0.0.1:58081`
- Workload HTTP: `127.0.0.1:8081`
- Workload HTTPS: `127.0.0.1:8444`

## 9. Phase 2D - Management Cluster Bootstrap

Goal:

- Create or verify `devdeploy-mgmt` through the Launcher.

Recommended tasks:

- Check whether `devdeploy-mgmt` already exists.
- Verify API server reachability.
- Verify expected port mappings.
- Create the cluster only when explicitly requested.
- Install or verify required platform bootstrap components.
- Deploy or verify DevDeploy platform resources.
- Keep bootstrap operations idempotent where possible.

Expected output:

- DevDeploy Hub runs inside `devdeploy-mgmt`.
- DevDeploy UI is reachable through `http://devdeploy.localhost:8080`.
- Backend, frontend, PostgreSQL, and Argo CD are healthy.

## 10. Phase 2E - Workload Cluster Creation

Goal:

- Create or verify `devdeploy-workload` through the Launcher.

Recommended tasks:

- Check whether `devdeploy-workload` already exists.
- Verify API server reachability.
- Verify expected port mappings.
- Install or verify workload ingress.
- Create or verify generated workload namespace.
- Keep workload bootstrap separate from management bootstrap.

Expected output:

- `devdeploy-workload` is reachable.
- Workload ingress is ready.
- User app URLs can use `http://<app-name>.localhost:8081`.

## 11. Phase 2F - Argo CD Workload Registration

Goal:

- Register `devdeploy-workload` with Argo CD running in `devdeploy-mgmt`.

Recommended tasks:

- Register workload cluster credentials with Argo CD.
- Scope credentials to workload namespaces where practical.
- Verify Argo CD can reach `devdeploy-workload`.
- Create or verify parent Application `devdeploy-workloads`.
- Ensure `devdeploy-workloads` targets `devdeploy-workload`.
- Ensure Git source path is `infra/kubernetes/generated/workloads`.

Expected output:

- Argo CD in `devdeploy-mgmt` can sync generated workloads to `devdeploy-workload`.
- The parent Application exists and has the correct destination.

## 12. Phase 2G - Setup Wizard Multi-Cluster UI Integration

Goal:

- Make the Setup Wizard accurately represent multi-cluster setup progress.

Recommended tasks:

- Show runtime mode.
- Show Launcher availability.
- Show host preflight status.
- Show management cluster status.
- Show workload cluster status.
- Show GitOps repository status.
- Show Argo CD registration status.
- Show demo app deployment status.
- Keep simulated steps clearly labeled until backed by real status.

Expected output:

- Setup Wizard guides users through the multi-cluster lifecycle without pretending to run host commands from the browser.
- Setup completion reflects actual platform readiness.

## 13. Phase 2H - GitOps Smoke Demo App

Goal:

- Validate the normal GitOps workload path using a small demo app.

Recommended tasks:

- Add or reuse a known safe demo image.
- Generate the demo app under `infra/kubernetes/generated/workloads/apps/<demo-app>`.
- Update the parent generated workload kustomization.
- Validate rendered manifests.
- Update Git according to repository policy.
- Let Argo CD sync to `devdeploy-workload`.
- Verify app URL reachability through workload ingress.

Expected output:

- Demo app deploys through:

  ```text
  Setup Wizard -> Backend -> GitHub/GitOps Repository -> Argo CD -> devdeploy-workload
  ```

- The demo app is observable with the same status model as normal apps.

## 14. Phase 2I - Observability and Status Integration

Goal:

- Distinguish management and workload status in the UI and backend.

Recommended tasks:

- Add workload cluster read-only status collection.
- Map GitOps requests to workload Kubernetes resources by labels.
- Show parent Argo CD Application status.
- Show workload Deployment, Pod, Service, and Ingress status.
- Keep management cluster health separate.
- Add URL reachability status where safe.
- Keep logs and metrics optional when unavailable.

Expected output:

- Dashboard and Deployments views can show whether a user app is pending, syncing, healthy, degraded, unavailable, unknown, or deleting.
- Management health and workload health are not mixed.

## 15. Phase 2J - Security Hardening Pass

Goal:

- Verify that the runtime implementation follows the security boundary documents.

Recommended checks:

- No secrets in Git.
- No secrets in browser localStorage.
- No raw tokens in logs.
- No kubeconfigs in API responses.
- Backend workload permissions are read-only.
- GitHub Actions do not receive cluster credentials.
- GitHub Actions do not run cluster deploy commands.
- Argo CD remains the applier for normal workloads.
- Launcher destructive operations require explicit user intent.
- Setup reset remains non-destructive.

Expected output:

- Phase 2 runtime behavior matches the security and credential model.

## 16. Commit and PR Strategy

Recommended commit strategy:

- One small commit per design or runtime milestone.
- Documentation commits separate from runtime commits.
- Avoid mixing frontend, backend, and infrastructure changes unless required by the milestone.
- Keep generated demo artifacts separate from platform changes where practical.
- Use clear commit messages that name the phase and milestone.
- Tag after a stable Phase 2 runtime milestone, not after every small documentation change.

Recommended PR strategy:

- Keep Phase 2A as a documentation baseline PR or commit series.
- Keep Launcher skeleton separate from management cluster creation.
- Keep management cluster bootstrap separate from workload cluster creation.
- Keep Argo CD registration separate from Setup Wizard UI integration.
- Keep security hardening as its own reviewable pass.

## 17. Validation Checklist

Baseline validation:

- Backend tests or compile checks pass.
- Frontend lint passes.
- Frontend build passes.
- Kubernetes manifests render.
- GitHub Actions syntax validates.
- Generated scripts compile.
- Dependency audits pass or documented exceptions are understood.

Phase 2-specific validation:

- Generated kind configs are deterministic.
- Local port conflict checks work.
- Required ports are shown in setup status.
- `devdeploy-mgmt` can be created or verified.
- DevDeploy platform runs in `devdeploy-mgmt`.
- `devdeploy-workload` can be created or verified.
- Argo CD can reach `devdeploy-workload`.
- Parent Application `devdeploy-workloads` targets `devdeploy-workload`.
- Generated workload manifests render.
- Demo app deploys through the GitOps path.
- Demo app URL works at `http://<app-name>.localhost:8081`.
- Delete flow removes Git state and lets Argo CD prune.
- No normal workload deployment occurs directly from backend.
- No normal workload deployment occurs directly from GitHub Actions.
- No secrets appear in Git, logs, API responses, or browser localStorage.

## 18. Rollback and Recovery Strategy

Phase 2 should support safe recovery from partial setup.

Recommended behavior:

- Verify existing clusters before creating anything.
- Detect incompatible cluster port mappings.
- Fail before cluster creation when required ports are busy.
- Keep setup status explicit when an operation fails.
- Allow retry after a failed step.
- Avoid deleting clusters automatically.
- Require explicit user intent for destructive Launcher actions.
- Keep GitOps delete separate from cluster deletion.
- Keep local setup reset separate from credential or resource deletion.

If a runtime milestone fails:

- Preserve logs with secret redaction.
- Record last successful step.
- Show actionable next steps.
- Avoid leaving the UI in a fake completed state.

## 19. Definition of Done for Phase 2

Phase 2 is complete when:

- `devdeploy-mgmt` can be created locally.
- DevDeploy Hub runs in `devdeploy-mgmt`.
- `devdeploy-workload` can be created locally.
- Argo CD in `devdeploy-mgmt` can deploy to `devdeploy-workload`.
- Parent Application `devdeploy-workloads` exists.
- Parent Application `devdeploy-workloads` targets `devdeploy-workload`.
- Demo app deploys through:

  ```text
  UI -> Backend -> GitHub/GitOps Repository -> Argo CD -> devdeploy-workload
  ```

- User app URL works at:

  ```text
  http://<app-name>.localhost:8081
  ```

- Backend does not directly apply, delete, patch, scale, or restart normal user workloads.
- GitHub Actions does not deploy directly to Kubernetes.
- Setup Wizard accurately shows multi-cluster setup state.
- Observability distinguishes management and workload health.
- Credentials and secrets follow the security boundaries.
- Validation checklist passes.

## 20. Future Phase Handoff

After Phase 2, future phases may add:

- Graphical DevDeploy Hub Launcher.
- Existing-cluster onboarding.
- App of Apps model with one Argo CD Application per user app.
- GitHub repository automation.
- Argo CD bootstrap automation refinements.
- Rollback workflows.
- More complete backup and restore workflows.
- Cloud provider cluster support.
- Multi-user RBAC and teams.
- Stronger secret manager integration.
- HTTPS automation and custom local domains.

These should be implemented only after the Phase 2 local-first multi-cluster baseline is stable.
