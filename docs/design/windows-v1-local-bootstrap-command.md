# Windows V1 Local Bootstrap Command

Date: 2026-08-28

This document refines the Windows v1 user-facing bootstrap command for DevDeploy Hub. It builds on the cross-platform launcher architecture and keeps the current backend, frontend, Kubernetes, GitOps, and Argo CD model unchanged.

## Goal

A normal Windows user should start DevDeploy with one command. The launcher should orchestrate local platform bootstrap when prerequisites are available, then hand off to the in-app Setup Wizard for product configuration.

The user should not manually run internal steps such as backend image build, image load, backend bootstrap, frontend image build, frontend image load, frontend bootstrap, Argo CD installation, or workload cluster registration.

## Recommended Entrypoint

Windows v1 should expose both names, with one canonical flow behind them:

- `Start-DevDeploy.ps1`: friendly user-facing script entrypoint for early Windows distribution.
- `devdeploy-launcher.ps1 -SetupLocalPlatform`: explicit internal/developer command that implements the same orchestration path.

`Start-DevDeploy.ps1` should be a thin wrapper. The long-term `DevDeployLauncher.exe` should wrap the same bootstrap flow rather than replacing the product architecture.

## Windows V1 User Flow

1. User downloads or checks out DevDeploy Hub.
2. User runs `Start-DevDeploy.ps1` from the repository or packaged distribution.
3. Launcher checks prerequisites and reports actionable guidance for missing items.
4. Launcher verifies or prepares pinned local tools under `.devdeploy/local/tools`.
5. Launcher creates or verifies the management and workload kind clusters.
6. Launcher installs or verifies platform components.
7. Launcher builds, loads, and deploys backend and frontend images.
8. Launcher waits for backend readiness, frontend readiness, and platform readiness.
9. Launcher opens the browser to DevDeploy Hub when reachable.
10. Setup Wizard continues in the app for GitHub, GitOps, Root Application, and product setup.

## Orchestrated Internal Steps

`-SetupLocalPlatform` should orchestrate these existing internal actions in order, with idempotent checks before each mutating step:

1. Validate host prerequisites.
2. Prepare pinned tools when safe.
3. Plan safe host ports.
4. Ensure management kind cluster.
5. Ensure workload kind cluster.
6. Ensure management ingress and PostgreSQL.
7. Install or verify Argo CD in the management cluster.
8. Register workload cluster with Argo CD.
9. Reconcile namespace-scoped workload permissions.
10. Reconcile preview and observability service-account credentials.
11. Build management backend image.
12. Load management backend image into kind.
13. Bootstrap or reconcile management backend.
14. Build management frontend image.
15. Load management frontend image into kind.
16. Bootstrap or reconcile management frontend.
17. Verify backend, frontend, PostgreSQL, Argo CD, workload cluster, and Root Application readiness where configured.
18. Write launcher status and logs.
19. Open the browser when the platform is reachable.

These remain internal stages. They should be available for developer troubleshooting, but the normal user path should be the single setup command.

## Prerequisite Checks

The command should check:

- Windows and PowerShell version.
- Docker Desktop installed.
- Docker engine reachable and using Linux containers.
- Docker build and image inspect support.
- `kubectl` available or preparable as a pinned local tool.
- `kind` available or preparable as a pinned local tool.
- Git available.
- Argo CD CLI available only if a stage needs it; Kubernetes API based operations are preferred when safe.
- Helm available or preparable as a pinned local tool for observability/platform charts.
- Required host ports are available or safe dynamic fallbacks can be selected.

Docker Desktop must not be silently installed. If Docker is missing, the launcher should stop before cluster creation and show an official install link plus required configuration guidance.

If Docker is installed but stopped, the launcher may attempt safe startup only when the OS and Docker installation support it. Otherwise it should explain how to start Docker Desktop and ask the user to rerun the command.

## Existing Cluster Behavior

If clusters already exist and are healthy, the command should preserve them.

For each DevDeploy kind cluster, the launcher should verify:

- Expected control-plane container exists.
- Kubernetes API is reachable from the host or from the correct execution environment.
- Required host port publications are present.
- Existing immutable host bindings are usable.
- Docker restart policy is healthy or reported for explicit repair.
- Cluster identity matches the expected DevDeploy cluster.

A different HTTPS host port from the old default is not a reason to recreate a healthy cluster. Selected ports should be persisted in the launcher status/runtime configuration.

## Missing Cluster Behavior

If a required cluster is missing, `-SetupLocalPlatform` may create it using the current safe port plan.

Creation should:

- Use deterministic, non-overlapping host port selection.
- Avoid Windows excluded TCP ranges.
- Reject ports owned by unrelated containers or the other DevDeploy cluster.
- Generate kind config under `.devdeploy/local/kind`.
- Reconcile the expected control-plane container restart policy to `unless-stopped` only after successful creation.
- Write status without logging credentials.

## Management Cluster Bootstrap

The management cluster hosts the DevDeploy platform: PostgreSQL, backend, frontend, ingress, Argo CD, and platform-owned Secrets and ConfigMaps.

The command should:

- Create or verify the management cluster.
- Install or verify ingress.
- Install or verify PostgreSQL without rotating existing credentials unnecessarily.
- Build, load, and deploy backend and frontend images.
- Update deterministic image identity annotations when same-tag images are rebuilt and loaded.
- Wait for new rollouts, not merely old ready pods.
- Keep management-cluster recreation explicit and destructive-recovery gated.

Management recreation must not be automatic in Windows v1. A plan-only recovery command may report that recreation is required and remind the user to verify an external PostgreSQL backup first.

## Workload Cluster Bootstrap

The workload cluster hosts user workloads in the managed namespace, currently `devdeploy-apps`.

The command should:

- Create or verify the workload cluster.
- Create or verify the managed namespace.
- Register the workload cluster with Argo CD.
- Create narrow workload permissions for GitOps sync, runtime status, observability, and preview.
- Generate separate kubeconfig representations for host-local and in-cluster execution where needed.
- Preserve GitOps as the source of workload desired state.

The launcher must not apply user workload manifests directly as the normal product path.

## Argo CD Installation And Root Application

The command may install or verify Argo CD as a platform component. Product-level GitOps settings remain Setup Wizard responsibility.

When Root Application configuration is already known and trusted, bootstrap should:

- Reconcile only the configured DevDeploy Root Application.
- Use the configured namespace and application name.
- Support initial empty repositories.
- Support recovery from an existing populated DevDeploy-managed GitOps repository.
- Keep automated self-heal and safe prune behavior for managed workload cleanup.
- Allow empty desired state.
- Avoid changing existing workload manifests.

The command must not require a legacy release Application when the configured Root Application is the product source of reconciliation truth.

## Backend And Frontend Bootstrap

The one-command flow should hide these internal stages from the normal user:

- `BuildManagementBackendImage`
- `LoadManagementBackendImage`
- `BootstrapManagementBackend`
- `BuildManagementFrontendImage`
- `LoadManagementFrontendImage`
- `BootstrapManagementFrontend`

Each stage should remain independently callable for developers, but `-SetupLocalPlatform` owns the normal orchestration.

Same-tag local image rebuilds must update a deterministic pod-template image identity annotation during mutating bootstrap. Verify/read-only modes must not mutate annotations.

## Port, Access, And Browser Behavior

The launcher should select and persist safe host ports for management and workload cluster HTTPS access. Post-validation commands and status output must use selected values, not fixed `8443` or `8444` assumptions.

Browser opening should happen only after:

- frontend is reachable,
- backend readiness is healthy,
- platform readiness is available enough for the app to route correctly.

Failure to open a browser should be reported as a non-fatal convenience failure when the URL itself is reachable.

## Status And Logs

The command should write:

```text
.devdeploy/local/logs/devdeploy-launcher.log
.devdeploy/local/status/launcher-status.json
.devdeploy/local/kind/*.yaml
.devdeploy/local/kubeconfig/*.yaml
.devdeploy/local/tools/*
```

Status should distinguish:

- `ready`
- `degraded`
- `absent`
- `not_checked`
- `unknown`
- `recreation_required`

A narrow internal stage must not mark unrelated installed components as `not_started` or `absent` solely because it did not check them. The setup command should merge current live discovery with prior verified state, and current live failure should override stale success.

Logs and status files must not include tokens, passwords, kubeconfig contents, certificates, private keys, Authorization headers, or cookies.

## Retry And Recovery

The setup command should be safe to rerun. Reruns should continue, verify, or repair idempotent stages instead of duplicating resources.

Safe automatic retries include:

- prerequisite recheck,
- image rebuild/load,
- backend/frontend reconcile,
- Argo CD verification,
- workload cluster registration verification,
- Root Application bootstrap when configured,
- observability verification.

Explicit recovery gates are required for:

- management cluster recreation,
- workload cluster recreation,
- destructive cleanup of broken kind clusters,
- Docker restart-policy repair outside a creation/bootstrap flow.

Plan modes must remain read-only.

## Security And Credentials

Security rules for Windows v1:

- Do not broaden RBAC as part of the bootstrap command.
- Use separate credentials for management, workload, observability, and preview access.
- Use narrow service-account permissions for workload read, service proxy, and pod port-forward.
- Mount Kubernetes Secrets read-only in cluster workloads.
- Store host-local generated kubeconfigs under DevDeploy-managed `.devdeploy/local` paths.
- Use host-reachable endpoints for local kubeconfigs and cluster-internal endpoints for in-cluster Secrets.
- Do not log token, certificate, private key, kubeconfig, cookie, or Authorization material.
- Do not expose the main user JWT to workload preview apps.
- Do not forward DevDeploy `Authorization`, `Cookie`, or `X-DevDeploy-*` headers upstream in preview.

## Internal And Developer-Only Commands

These should remain available for troubleshooting but not required in the normal user journey:

- individual build/load/bootstrap image commands,
- plan-only recovery commands,
- targeted observability bootstrap and verification,
- targeted Root Application bootstrap,
- status and integrity inspection commands,
- developer validation helpers.

The public documentation should point most users to `Start-DevDeploy.ps1` first.

## Setup Wizard Handoff

The launcher should stop at platform readiness. The in-app Setup Wizard should own:

- GitHub authentication and repository configuration,
- GitOps repository selection,
- Root Application product intent confirmation,
- first-run product setup,
- user-facing verification of GitOps and Argo CD state.

Host-level bootstrap belongs to the launcher. Product-level configuration belongs to the app.

## Future DevDeployLauncher.exe

The Windows `.exe` should eventually become the polished distribution wrapper. It should:

- call the same bootstrap orchestration flow,
- present clearer prerequisite and progress UI,
- write the same logs and status files,
- preserve script compatibility for developers,
- avoid embedding backend/frontend product logic.

The executable is packaging and orchestration, not a backend/frontend rewrite.

## Phased Implementation Plan

### Phase 1: Command Contract And Tests

- Add `-SetupLocalPlatform` as the one-command orchestration contract.
- Add `Start-DevDeploy.ps1` as a thin wrapper.
- Add dry-run and status tests for command sequencing.
- Preserve existing internal command behavior.

### Phase 2: Prerequisite And Tool Preparation

- Centralize Docker, PowerShell, Git, kind, kubectl, Argo CD CLI, and Helm checks.
- Prepare pinned local tools with checksum verification.
- Avoid global PATH changes and administrator requirements.

### Phase 3: Cluster Verification And Creation

- Reuse safe port planning for management and workload clusters.
- Preserve healthy existing clusters.
- Gate destructive recovery explicitly.
- Reconcile restart policy only during approved creation/bootstrap or explicit repair.

### Phase 4: Platform Bootstrap Orchestration

- Install or verify management platform components.
- Build, load, and reconcile backend/frontend images.
- Verify rollout image identity and readiness.
- Merge status without regressing unrelated components.

### Phase 5: Workload Platform Integration

- Register workload cluster with Argo CD.
- Reconcile workload namespace and least-privilege permissions.
- Generate host-local and in-cluster kubeconfig representations.
- Verify Root Application when configuration is present.

### Phase 6: Browser Launch And Wizard Handoff

- Wait for backend/frontend/platform readiness.
- Open the browser to DevDeploy Hub.
- Let Setup Wizard complete GitHub/GitOps/product configuration.

### Phase 7: Native Windows Packaging

- Wrap the same command flow in `DevDeployLauncher.exe`.
- Add user-friendly progress UI and logs access.
- Keep script entrypoints for developers and CI validation.

## Non-Goals

- Implementing `Start-DevDeploy.ps1` in this phase.
- Implementing `-SetupLocalPlatform` in this phase.
- Implementing `DevDeployLauncher.exe` in this phase.
- Implementing Setup Wizard behavior.
- Changing backend or frontend product behavior.
- Changing GitOps workload manifests.
- Adding cloud provider support.
- Adding env vars, secrets/configmaps, volumes, ingress/custom domains, rollback, or multi-container deployment features.