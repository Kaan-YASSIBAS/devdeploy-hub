# Setup Wizard Multi-Cluster Lifecycle Design

## 1. Overview

This document defines how the DevDeploy Hub Setup Wizard should evolve for the local-first multi-cluster architecture.

The higher-level architecture is defined in:

- [Multi-Cluster Redesign](./multi-cluster-redesign.md)
- [Bootstrapper / Launcher Design](./bootstrapper-launcher-design.md)

In the target architecture, the user starts DevDeploy Hub through a host-side Bootstrapper / Launcher. The Launcher creates or verifies a management kind cluster named `devdeploy-mgmt`. DevDeploy frontend, backend, PostgreSQL, Argo CD, and platform components run inside that management cluster.

The Setup Wizard then guides the user through preparing a separate workload cluster named `devdeploy-workload`. User applications run only in the workload cluster. Argo CD runs in `devdeploy-mgmt` and deploys to `devdeploy-workload`.

Normal workload deployment remains GitOps-only:

```text
UI -> Backend -> GitHub/GitOps Repository -> Argo CD -> Workload Kubernetes Cluster
```

The Setup Wizard is the user-facing setup orchestrator. It should show status, progress, actions, and recovery guidance, but it must not run host commands directly from the browser.

## 2. Design Goals

- Give users a clear guided path from first launch to a usable local GitOps environment.
- Keep host-side operations behind an explicit Bootstrapper / Launcher contract.
- Keep the in-cluster backend honest about runtime limits. It must not pretend it can inspect host Docker, kind, kubectl, kubeconfig, port, or filesystem state.
- Make management cluster and workload cluster status visually distinct.
- Preserve the GitOps deployment boundary for normal user workloads.
- Keep the first implementation simple enough to support a script or CLI-style Launcher before a graphical launcher exists.
- Support clear recovery when setup is partial, blocked, or failed.
- Avoid storing sensitive values in browser state.

## 3. Non-Goals

- The Wizard does not run `docker`, `kind`, `kubectl`, `helm`, or `git` commands directly from the browser.
- The Wizard does not deploy normal user workloads directly to Kubernetes.
- The backend does not directly `kubectl apply` or `kubectl delete` normal user workloads.
- GitHub Actions does not deploy directly to clusters.
- The first implementation does not require a graphical launcher.
- Existing cluster support is postponed for the first serious version.
- Cloud provider cluster creation, team RBAC, multi-tenancy, rollback automation, and GitHub repository provisioning are not part of the first implementation.

## 4. Wizard Role in the Multi-Cluster Architecture

The Wizard is a guided UI for setup state and setup decisions. It coordinates the user's setup experience by reading backend setup/status APIs and presenting Launcher-provided results.

The Wizard may:

- Display runtime mode and Launcher availability.
- Show host preflight results collected by the Launcher.
- Show management cluster status.
- Guide GitOps repository configuration.
- Trigger approved setup API actions when supported.
- Show workload cluster creation progress.
- Show Argo CD workload registration status.
- Start a demo app deployment through the normal GitOps path.
- Mark setup as completed only after required conditions are satisfied or explicitly skipped with warnings.

The Wizard must not:

- Execute host commands from the browser.
- Assume the backend can inspect host state when running inside Kubernetes.
- Suggest that backend or GitHub Actions deploy normal workloads directly to Kubernetes.
- Hide setup failures behind fake successful states.

## 5. Setup Lifecycle Overview

The target lifecycle is:

1. User starts DevDeploy Hub through the host-side Launcher.
2. Launcher verifies host prerequisites.
3. Launcher creates or verifies `devdeploy-mgmt`.
4. Launcher installs or verifies platform components in `devdeploy-mgmt`.
5. User opens DevDeploy Hub UI.
6. Setup Wizard detects runtime and Launcher status through backend setup/status APIs.
7. Wizard guides GitOps repository configuration.
8. Launcher creates or verifies `devdeploy-workload`.
9. Argo CD in `devdeploy-mgmt` is registered to deploy into `devdeploy-workload`.
10. Parent workload Application is created or verified.
11. Optional demo app deployment is requested through the normal GitOps flow.
12. Wizard marks setup complete when required health and configuration checks pass.

## 6. Step-by-Step Wizard Flow

### Welcome

Purpose:

- Explain that DevDeploy Hub is preparing a local-first GitOps environment.
- Set expectations that there are separate management and workload clusters.
- Clarify that normal app deployments will go through GitOps and Argo CD.

Primary UI state:

- `not_started` until the user begins setup.

### Runtime / Launcher Detection

Purpose:

- Detect whether the backend is running in host/local mode, Kubernetes mode, or an unknown mode.
- Detect whether the Launcher is available and has reported setup status.

Expected behavior:

- If Launcher status is available, show the Launcher as the source of host-side setup truth.
- If the backend is running inside Kubernetes and no Launcher status exists, show `waiting_for_launcher`.
- If runtime mode is unknown, show an explanation and avoid false host-tool failures.

The UI should explain:

- Host checks require the Launcher.
- In-cluster backend cannot verify host Docker, kind, kubectl, git, helm, ports, kubeconfigs, or filesystem state.

### Host Preflight

Purpose:

- Show host readiness for local environment setup.

Checks should come from the Launcher or explicit setup status written by the Launcher. In host/local mode, supported checks may include:

- Docker CLI available.
- Docker daemon reachable.
- kind CLI available.
- kubectl CLI available.
- git CLI available.
- helm CLI available, if required by the bootstrap path.
- Required ports available.
- Current Kubernetes context detected.
- Existing `devdeploy-mgmt` or `devdeploy-workload` clusters detected.

In Kubernetes runtime mode, host checks should be marked as runtime-limited instead of failed.

### Management Cluster Status

Purpose:

- Show whether `devdeploy-mgmt` exists and is healthy.
- Show whether platform components are healthy.

Expected checks:

- `devdeploy-mgmt` cluster exists.
- Kubernetes API is reachable.
- DevDeploy frontend is reachable.
- DevDeploy backend is reachable.
- PostgreSQL is running.
- Argo CD is running.
- Required namespaces and platform Applications exist.

This status must be visually separate from workload cluster status.

### GitHub / GitOps Repository Setup

Purpose:

- Confirm the GitOps repository configuration used for workload manifests.
- Confirm whether automatic workflow dispatch is configured.
- Explain whether repository updates use direct commits or pull requests according to repository policy.

Expected behavior:

- Missing GitHub token or repository configuration should not crash the platform.
- If automatic dispatch is unavailable, show manual fallback instructions.
- Do not expose tokens.
- Do not store GitHub tokens in browser localStorage.

### Workload Cluster Creation

Purpose:

- Guide creation or verification of `devdeploy-workload`.

Expected behavior:

- Creation is performed by the Launcher, not by browser code.
- The Wizard shows progress and final status from backend setup/status APIs.
- If the workload cluster already exists, setup verifies it instead of recreating it blindly.
- If ports or names conflict, show actionable messages.

### Argo CD Workload Registration

Purpose:

- Confirm that Argo CD in `devdeploy-mgmt` can deploy to `devdeploy-workload`.

Expected checks:

- Workload cluster credentials are registered with Argo CD.
- Argo CD can reach the workload cluster API.
- Destination namespace for generated workloads is available or can be managed by GitOps.
- Parent workload Application exists.

The first implementation may use a single parent Application named `devdeploy-workloads` tracking `infra/kubernetes/generated/workloads`. The design should remain compatible with future App of Apps behavior where each user app receives its own Argo CD Application.

### Demo App Deployment

Purpose:

- Validate the normal deployment path with a small demo workload.

Required boundary:

```text
Wizard -> Backend -> GitHub/GitOps Repository -> Argo CD -> devdeploy-workload
```

The demo app step must not:

- Ask the backend to apply Kubernetes manifests directly.
- Ask GitHub Actions to deploy directly to Kubernetes.
- Bypass Argo CD.

If the demo app is skipped, setup may complete with a warning when all other required platform checks are healthy.

### Setup Completion

Setup completion means:

- `devdeploy-mgmt` is healthy.
- DevDeploy UI, backend, and PostgreSQL are healthy.
- Argo CD is healthy.
- `devdeploy-workload` is reachable.
- Argo CD is registered to `devdeploy-workload`.
- Parent workload Application exists.
- GitOps repository is configured.
- Demo app deployment has passed or has been explicitly skipped with a warning.

Setup completion should not mean that every future user workload will always deploy successfully. It means the platform has enough verified infrastructure to accept normal GitOps deployment requests.

## 7. Wizard State Model

The Wizard should use explicit step and overall statuses.

Recommended status values:

- `not_started`: The step has not started.
- `waiting_for_launcher`: The step requires host-side Launcher status or action.
- `running`: The step is actively checking or waiting for a setup operation.
- `completed`: The step completed successfully.
- `warning`: The step is usable but has a limitation or skipped optional requirement.
- `failed`: The step has a blocking problem.
- `skipped`: The user intentionally skipped an optional step.

Recommended persisted state:

- Setup version.
- Current step.
- Step statuses.
- Selected setup path.
- Runtime mode observed by backend.
- Launcher availability summary.
- Management cluster status summary.
- Workload cluster status summary.
- GitOps repository status summary.
- Demo app status.
- Last updated timestamp.

The browser may store non-sensitive wizard progress locally, scoped per user. Sensitive values, tokens, kubeconfigs, cluster credentials, and repository credentials must not be stored in browser localStorage.

## 8. Backend Setup Status API Expectations

The backend should expose setup/status APIs that describe platform state without pretending to have host access when running inside Kubernetes.

Expected API responsibilities:

- Report runtime mode: `host`, `kubernetes`, or `unknown`.
- Report runtime limitations.
- Return Launcher-provided status if available.
- Return management cluster/platform health from in-cluster checks.
- Return workload cluster registration status if available from Argo CD or stored setup state.
- Return GitOps repository configuration status without exposing secrets.
- Return safe progress and error messages.

The backend may accept setup actions only when they map to an explicit Launcher contract or safe platform configuration operation. It must not directly apply or delete normal user workload resources.

## 9. Launcher Status Integration

Launcher integration should be explicit and auditable.

The Launcher may provide status through one of these V1-friendly patterns:

- A local status file mounted or copied into a known platform setup location.
- A backend setup/status API call authenticated with a short-lived local setup credential.
- A CLI command that starts the platform and streams setup status to the user while the backend later reads summarized state.

The chosen contract should include:

- Launcher version.
- Runtime host OS.
- Preflight check results.
- Management cluster status.
- Workload cluster status.
- Port assignments.
- Last action.
- Current operation status.
- Sanitized logs or log references.
- Last updated timestamp.

The contract must not include raw tokens, kubeconfigs, passwords, or secret values.

## 10. Runtime-Aware Preflight Behavior

Runtime-aware preflight should remain visible because it prevents misleading setup output.

Host/local mode can verify:

- Docker CLI and daemon.
- kind.
- kubectl.
- git.
- helm, if required.
- Port availability.
- Current Kubernetes context.
- Existing kind clusters.

Kubernetes mode cannot verify the user's host tools. In that mode, the Wizard should show warnings such as:

- Host checks are running from the backend pod.
- Docker, kind, kubectl, git, helm, and host ports cannot be verified from this runtime.
- Local environment setup requires the Launcher.

Kubernetes mode should not show missing host tools as if the user's machine is misconfigured.

## 11. Progress and Error States

Setup progress should be explicit and non-ambiguous.

Recommended behavior:

- Use static icons for completed, warning, failed, skipped, and waiting states.
- Use active progress indicators only for `running` operations.
- Show clear labels such as "Waiting for Launcher", "Running", "Completed", or "Failed".
- Keep management and workload cluster progress in separate sections.
- Show a compact summary plus expandable details for command-level or check-level output.

Error messages should be:

- Safe.
- Actionable.
- Specific enough to help recovery.
- Free of secret values.
- Honest about whether the issue is host-side, backend-side, GitOps-side, Argo CD-side, or workload-cluster-side.

## 12. Recovery and Retry Behavior

Setup should be idempotent where possible.

Recommended recovery behavior:

- If `devdeploy-mgmt` exists, verify it instead of recreating it blindly.
- If `devdeploy-workload` exists, verify it instead of recreating it blindly.
- If a setup operation fails halfway, show what completed and what remains.
- Retry should re-run verification before creating or changing anything.
- Port conflicts should fail with actionable instructions.
- Missing Launcher status should move steps to `waiting_for_launcher`.
- Demo app failure should not hide successful platform setup.

The Wizard should support:

- Retry current step.
- Re-run preflight.
- Continue after warning where safe.
- Skip optional demo app with warning.
- Reset local wizard state without deleting clusters, GitOps repositories, Kubernetes resources, Argo CD configuration, deployments, or API tokens.

## 13. UX Copy Guidelines

Copy should be direct and implementation-accurate.

Use wording that clarifies:

- The Wizard guides setup.
- The Launcher performs host-side actions.
- Argo CD applies Kubernetes manifests.
- GitHub Actions updates and validates GitOps repository content.
- The backend does not directly deploy normal user workloads.

Avoid wording that implies:

- The browser can run host commands.
- The in-cluster backend can inspect the host machine.
- GitHub Actions deploys directly to Kubernetes.
- Setup success means all future deployments are guaranteed to succeed.

Turkish copy should stay natural and product-oriented. Technical terms like GitOps, backend, GitHub, Kubernetes, Argo CD, workflow, deployment, dashboard, and Launcher can remain as-is when clearer.

## 14. Security Boundaries

Security boundaries:

- Browser state may store non-sensitive onboarding progress only.
- Browser state must not store GitHub tokens, kubeconfigs, passwords, or cluster credentials.
- Backend responses must not expose secret values.
- Launcher logs and status must be sanitized before surfacing in the UI.
- Backend must not directly apply or delete normal user workloads.
- GitHub Actions must not deploy directly to clusters.
- Argo CD remains the applier for normal workload resources.
- Workload cluster credentials should be handled as platform secrets, not UI-local state.
- Setup reset in the UI must reset local onboarding state only.

Bootstrap operations are allowed for platform initialization through the Launcher. Normal app deployment remains GitOps-only.

## 15. V1 Implementation Recommendation

V1 should remain simple and explicit:

1. Keep the existing frontend Setup Wizard route.
2. Extend the Wizard to show runtime mode and Launcher availability.
3. Keep current runtime-aware preflight visible.
4. Add backend setup/status APIs that can return Launcher-provided setup summaries.
5. Implement the Launcher first as a PowerShell or CLI-style host process for Windows.
6. Use the Launcher to create or verify `devdeploy-mgmt`.
7. Use the Wizard to guide `devdeploy-workload` creation and registration, but execute host-side steps through the Launcher contract.
8. Use a single parent Argo CD Application named `devdeploy-workloads` for generated workloads.
9. Keep demo app deployment on the normal GitOps path.
10. Store only non-sensitive wizard progress in browser localStorage.

This keeps the product direction clear without requiring a graphical Launcher or broad automation surface in the first implementation.

## 16. Future Enhancements

Future work may include:

- Graphical DevDeploy Hub Launcher.
- Stronger Launcher/backend authentication contract.
- Per-step log streaming.
- More detailed setup event history.
- Existing cluster setup path.
- App of Apps model with one Argo CD Application per user app.
- Automated GitHub repository creation when explicitly configured.
- Rollback and recovery workflows.
- Workload cluster replacement flow.
- Platform backup and restore workflow.
- Policy checks for generated workloads.
- Better localhost routing previews for generated app URLs.

These should be added without changing the core deployment boundary: normal workloads flow through GitOps and are applied by Argo CD.
