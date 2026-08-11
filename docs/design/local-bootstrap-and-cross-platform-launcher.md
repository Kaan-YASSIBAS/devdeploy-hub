# Local Bootstrap and Cross-Platform Launcher Architecture

Date: 2026-08-11

DevDeploy Hub needs a local-first bootstrap experience that hides the current collection of manual scripts behind one user-facing launcher. The launcher is a host-level orchestration layer. It does not replace the Python/FastAPI backend, the React/Vite frontend, Kubernetes, GitOps, or Argo CD.

## Goals

- A normal user starts DevDeploy with one launcher entry point.
- The launcher prepares the local platform when prerequisites are available.
- The in-app Setup Wizard completes product configuration after the platform is reachable.
- Windows is the first practical distribution target.
- macOS and Linux remain first-class future targets.
- GitOps remains the desired-state source.
- Database/domain records remain the product source of truth.
- Kubernetes and Argo CD remain runtime and reconciliation sources.

## User Installation And Start Flow

For Windows v1, the practical user flow is:

1. User downloads DevDeploy Hub.
2. User runs `Start-DevDeploy.ps1` or a packaged `DevDeployLauncher.exe`.
3. Launcher checks host prerequisites.
4. Launcher starts or validates Docker Desktop.
5. Launcher installs or prepares pinned local tools under DevDeploy-managed directories when safe.
6. Launcher creates or verifies the local management and workload clusters.
7. Launcher installs platform components.
8. Launcher builds, loads, and deploys the backend and frontend.
9. Launcher opens the browser to DevDeploy Hub.
10. Setup Wizard continues inside the app when platform readiness is available.

The user should not manually run internal actions such as `BuildManagementBackendImage`, `LoadManagementBackendImage`, `BootstrapManagementBackend`, `BootstrapManagementFrontend`, `BootstrapGitOpsRootApplication`, or observability bootstrap steps. Those remain internal launcher stages.

## Windows V1 Distribution Model

Windows v1 can begin as a signed PowerShell launcher plus a stable script entry point:

```text
Start-DevDeploy.ps1
```

The long-term Windows target is a native launcher or installer:

```text
DevDeployLauncher.exe
```

The executable is a platform package, not the core product architecture. Its job is to invoke the same launcher orchestration model and write the same status/log artifacts.

## Future macOS And Linux Distribution Model

Future platform packages should reuse the same launcher concepts:

- macOS: app bundle, signed binary, or shell entry point.
- Linux: shell entry point, package, AppImage, or distro-specific package.
- Shared behavior: prerequisite detection, tool preparation, cluster lifecycle, image build/load/deploy, status files, logs, browser launch.
- Platform-specific behavior: Docker Desktop vs Docker Engine, service startup guidance, shell conventions, executable packaging, OS-specific port checks.

The launcher should use a thin platform abstraction rather than embedding all behavior in a Windows-only script model.

## Launcher Responsibilities

The launcher owns host-level bootstrap and local platform orchestration:

- Detect host OS and architecture.
- Detect Docker availability and runtime state.
- Detect reserved/unavailable host ports.
- Prepare pinned local tools when safe.
- Create or verify kind management cluster.
- Create or verify kind workload cluster.
- Install or verify Argo CD.
- Register the workload cluster with Argo CD.
- Create or verify namespace-scoped workload permissions.
- Build backend and frontend images.
- Load images into the management cluster.
- Deploy or reconcile backend and frontend platform workloads.
- Bootstrap workload observability when requested by the local profile.
- Write safe logs and machine-readable status.
- Open the browser after the frontend is reachable.
- Retry safe, idempotent steps.
- Report explicit recovery plans for destructive cluster recreation.

The launcher must not become an application backend. It should call tools, apply platform manifests, and report status; the product API remains in FastAPI.

## Setup Wizard Responsibilities

The Setup Wizard owns in-app product configuration after the platform is reachable:

- Confirm platform readiness from backend APIs.
- Configure GitHub/GitOps connection details.
- Configure Root Application intent and verify readiness.
- Confirm Argo CD and GitOps source health.
- Guide user through first-run product setup.
- Store product settings through backend APIs.
- Present actionable user-facing errors.

The Setup Wizard should not create host clusters, install Docker, install kind, or build/load local images.

## Launcher And Wizard Boundary

Host-level bootstrap belongs to the launcher.

Product-level configuration belongs to the Setup Wizard.

Examples:

- Docker missing: launcher reports install guidance.
- Docker installed but stopped: launcher guides startup or attempts a safe start when appropriate.
- kind cluster missing: launcher creates it.
- backend unavailable: launcher deploys or repairs it.
- GitHub token missing: Setup Wizard asks for it.
- Root Application misconfigured: Setup Wizard guides configuration, while launcher may provide platform-level Argo CD installation.
- workload runtime resources: managed through GitOps and Argo CD, not manual runtime patching.

## Prerequisite Handling

Docker Desktop should not be silently installed by DevDeploy.

If Docker is missing:

- Launcher reports a clear prerequisite failure.
- Launcher shows an official install link.
- Launcher explains required settings such as Linux containers and Kubernetes/kind compatibility.
- Launcher exits safely without partial cluster creation.

If Docker is installed but not running:

- Launcher detects the state.
- Launcher may attempt safe startup when the OS and Docker installation support it.
- If startup cannot be verified, launcher provides clear guidance.

For command-line tools:

- Prefer DevDeploy-managed local tool directories.
- Pin versions for kind, kubectl, Argo CD CLI, Helm, and other tools.
- Verify checksums for downloaded tools.
- Avoid global PATH changes.
- Avoid administrator rights unless a future installer explicitly requests them.
- Reuse already installed compatible tools when safe.

## Docker Desktop Behavior

Docker is a hard prerequisite for the local kind-based platform.

The launcher should verify:

- Docker command availability.
- Docker daemon reachability.
- Linux container mode where applicable.
- Image build support.
- kind node container visibility.
- Published host ports.
- Restart policy for DevDeploy-owned kind control-plane containers.

Docker Desktop shutdown/restart behavior must be handled explicitly. DevDeploy-owned kind node containers should have a durable restart policy such as `unless-stopped` after successful creation, applied only to expected DevDeploy kind control-plane containers.

## kind, kubectl, Argo CD, And Helm Handling

The launcher should manage local tool availability:

- kind: create and inspect local clusters.
- kubectl: read platform state, apply platform manifests, verify rollouts.
- argocd: optional where Kubernetes API interactions are insufficient.
- Helm: install platform charts such as observability components.

Tool handling rules:

- Use pinned versions.
- Use official sources.
- Verify checksums.
- Store tools below `.devdeploy/local/tools` or equivalent.
- Do not require global PATH mutation.
- Do not log tokens, kubeconfigs, or certificates.

## Management Cluster Bootstrap

The management cluster hosts the DevDeploy platform:

- PostgreSQL
- backend
- frontend
- ingress
- Argo CD
- platform Secrets and ConfigMaps required for DevDeploy itself

The launcher should:

- Select safe host ports dynamically.
- Preserve healthy existing clusters.
- Detect immutable broken port bindings.
- Require explicit confirmation before destructive management-cluster recreation.
- Warn that PostgreSQL/platform data can be lost unless backed up.
- Restore or reconcile platform workloads through manifests.

Management cluster recreation must never be implicit.

## Workload Cluster Bootstrap

The workload cluster hosts user workloads in the managed namespace, currently `devdeploy-apps`.

The launcher should:

- Create or verify the workload cluster.
- Create the managed namespace.
- Register the workload cluster with Argo CD.
- Create narrow workload permissions.
- Generate separate kubeconfigs for normal workload access and observability/preview access.
- Preserve GitOps as the source of workload desired state.

The launcher must not manually apply user workload manifests as the normal product path.

## Argo CD Installation And Bootstrap

The launcher installs and verifies Argo CD in the management cluster.

The Setup Wizard verifies and configures product-level GitOps intent.

Root Application bootstrap should:

- Use configured namespace and Root Application name.
- Support initial empty repositories.
- Support recovery from an existing populated DevDeploy-managed GitOps repository.
- Keep `selfHeal` enabled.
- Use safe prune behavior for managed workload cleanup.
- Support empty desired state with `allowEmpty`.
- Avoid mutating existing user workload manifests.

## Backend And Frontend Build/Load/Deploy Strategy

Local development and packaged local installs can use the same conceptual stages:

1. Build backend image.
2. Load backend image into management kind cluster.
3. Reconcile backend Deployment.
4. Verify backend rollout and readiness.
5. Build frontend image.
6. Load frontend image into management kind cluster.
7. Reconcile frontend Deployment.
8. Verify frontend rollout and readiness.

Same-tag local image rebuilds must update a deterministic pod-template image identity annotation so Kubernetes creates a new ReplicaSet without manual rollout restart.

Read-only verify modes must not mutate Deployment annotations.

## Browser Opening Behavior

The launcher should open the browser only after:

- frontend Service or ingress is reachable,
- backend readiness is healthy,
- platform readiness endpoint reports enough state for the app to route correctly.

Browser launch should be best-effort. Failure to open a browser should not mark platform bootstrap failed if the URL is reachable and clearly reported.

## Logs And Status Files

The launcher should write safe local artifacts such as:

```text
.devdeploy/local/logs/devdeploy-launcher.log
.devdeploy/local/status/launcher-status.json
.devdeploy/local/kind/*.yaml
.devdeploy/local/kubeconfig/*.yaml
.devdeploy/local/tools/*
```

Status files should distinguish:

- ready
- degraded
- absent
- not_checked
- unknown
- recreation_required

A narrow launcher mode must not turn a previously verified unrelated component into `not_started` or `absent` merely because that component was not checked in the current mode.

Logs and status files must not contain:

- tokens
- passwords
- kubeconfig contents
- certificates or private keys
- Authorization headers
- cookies

## Error Recovery And Retry Behavior

Launcher stages should be idempotent where possible.

Safe retries:

- re-run preflight
- re-run image build/load
- re-run backend/frontend bootstrap
- re-run Root Application bootstrap
- re-run observability verification
- re-run workload observability bootstrap when manifests and secrets are valid

Explicit recovery required:

- management cluster recreation
- workload cluster recreation
- destructive cleanup of broken kind clusters

Recovery plans should be plan-first and read-only by default.

## Security And Credential Handling

Security rules:

- Do not broaden RBAC as part of launcher design.
- Use separate credentials for management, workload, observability, and preview access.
- Use narrow service-account permissions for workload read, service proxy, and pod port-forward.
- Store generated kubeconfigs under DevDeploy-managed local paths or Kubernetes Secrets as appropriate.
- Mount in-cluster Secrets read-only.
- Do not log or print secret values.
- Do not expose main user JWTs to workload apps.
- Do not forward DevDeploy `Authorization` or `Cookie` headers upstream in preview.

Credential representations may differ by execution environment:

- host-local kubeconfigs use host-reachable kind API endpoints,
- in-cluster kubeconfigs use cluster-internal endpoints.

The identity and RBAC should stay narrow in both representations.

## Platform Readiness Handoff

The launcher hands off to the Setup Wizard when:

- backend is reachable and ready,
- frontend is reachable,
- management cluster API is reachable,
- workload cluster API is reachable or its absence is reported clearly,
- platform readiness API can distinguish healthy, degraded, unavailable, and not configured states.

The app should not send users to Setup Wizard because of stale cached launcher status or optional diagnostics. The backend readiness endpoints remain authoritative for app routing.

## Cross-Platform Abstraction Strategy

The launcher should separate core orchestration from platform-specific mechanics.

Suggested conceptual modules:

- `PlatformDetector`
- `CommandRunner`
- `ToolManager`
- `DockerRuntime`
- `PortPlanner`
- `KindClusterManager`
- `KubernetesApplier`
- `ImageBuilder`
- `StatusStore`
- `BrowserOpener`

Each platform implementation can provide:

- command paths and shell invocation rules,
- Docker startup guidance,
- filesystem locations,
- port-exclusion detection,
- browser opening command,
- packaging-specific behavior.

The orchestration plan should remain shared.

## Phased Implementation Plan

### Phase 1: Design And Guardrails

- Document launcher architecture and boundaries.
- Preserve current stable GitOps lifecycle.
- Keep Setup Wizard out of scope.
- Add regression checks for existing lifecycle, preview, and status contracts.

### Phase 2: Windows Launcher Command Contract

- Define one user-facing Windows command.
- Map existing internal launcher actions into one orchestration flow.
- Preserve existing status file contract.
- Keep plan/verify modes read-only.

### Phase 3: Prerequisite And Tool Manager

- Detect Docker Desktop presence and daemon state.
- Prepare pinned kind/kubectl/argocd/Helm tools.
- Verify checksums.
- Store tools under DevDeploy-managed paths.

### Phase 4: Cluster Bootstrap Orchestration

- Bootstrap or verify management cluster.
- Bootstrap or verify workload cluster.
- Use dynamic safe port planning.
- Preserve explicit recovery gates for destructive operations.

### Phase 5: Platform Component Bootstrap

- Install or verify Argo CD.
- Reconcile backend and frontend.
- Verify platform readiness.
- Open the browser.

### Phase 6: Setup Wizard Handoff

- Ensure Setup Wizard consumes backend platform readiness.
- Configure GitHub/GitOps and Root Application through app workflows.
- Keep host-level bootstrap in the launcher.

### Phase 7: Packaging

- Package Windows launcher as an executable or installer.
- Preserve script-based development entry point.
- Add macOS/Linux launcher backends without changing backend/frontend architecture.

## Non-Goals

- Implementing launcher code in this document.
- Implementing Setup Wizard code.
- Rewriting backend or frontend.
- Replacing existing scripts immediately.
- Adding cloud provider support.
- Adding production multi-user hosting.
- Adding env vars, secrets/configmaps, volumes, ingress, rollback, or multi-container deployment features.
