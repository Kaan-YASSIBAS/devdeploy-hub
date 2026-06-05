# DevDeploy Bootstrapper / Launcher Design

## 1. Overview

This document defines the DevDeploy Bootstrapper / Launcher design for the local-first multi-cluster architecture.

The higher-level architecture is defined in:

```text
docs/architecture/multi-cluster-redesign.md
```

The Launcher is the host-side component that prepares the local environment. It runs on the user's machine and is allowed to inspect host tools, choose ports, create local kind clusters, and bootstrap platform components.

The in-cluster DevDeploy backend must not assume direct access to the user's host Docker daemon, kind binary, kubectl binary, kubeconfigs, ports, or filesystem state. Host checks and host cluster creation belong to the Launcher.

Normal user workload deployment remains GitOps-only:

```text
UI -> Backend -> GitHub/GitOps Repository -> Argo CD -> Workload Kubernetes Cluster
```

The Launcher may bootstrap platform infrastructure, but it must not bypass GitOps for normal user workloads.

## 2. Design Goals

- Provide a practical host-side entry point for starting DevDeploy Hub locally.
- Create or verify the management cluster `devdeploy-mgmt`.
- Install or verify DevDeploy platform components in `devdeploy-mgmt`.
- Support Setup Wizard-driven creation or verification of the workload cluster `devdeploy-workload`.
- Keep user workloads isolated from platform components.
- Keep normal app deployment GitOps-only.
- Make local ports predictable and conflict-aware.
- Provide clear progress, logs, and recovery guidance.
- Keep V1 simple enough to implement as a PowerShell script or small CLI-style launcher on Windows.
- Leave room for a future graphical DevDeploy Hub Launcher.

## 3. Non-Goals

V1 should not implement:

- Cloud provider cluster creation.
- Existing-cluster onboarding.
- Production-grade secret management.
- Team or multi-tenant RBAC.
- Graphical launcher UI.
- Automatic GitHub repository creation.
- Direct backend deployment of user workloads.
- GitHub Actions deployment to Kubernetes.
- Full rollback UI.
- Production TLS automation.

## 4. Launcher Runtime Context

The Launcher runs on the user's host machine.

For the initial serious version, the expected host is Windows with Docker Desktop and PowerShell.

The Launcher may run host commands such as:

- `docker`
- `kind`
- `kubectl`
- `git`
- `helm`

The Launcher should run these commands directly from the host runtime, not from inside the DevDeploy backend pod.

The Launcher should treat the host as the source of truth for:

- installed CLI tools
- Docker daemon availability
- local port availability
- local kubeconfig access
- kind cluster existence
- generated kind config files
- local setup logs

## 5. Responsibility Boundaries

### Launcher

The Launcher is responsible for host-side setup and platform bootstrap:

- Check host prerequisites.
- Detect busy ports.
- Generate kind configs.
- Create or verify `devdeploy-mgmt`.
- Create or verify `devdeploy-workload`.
- Install or verify platform bootstrap dependencies.
- Configure Argo CD to reach the workload cluster.
- Start or expose DevDeploy Hub through localhost.
- Produce setup progress and logs.
- Provide recovery guidance for partial setup.

The Launcher must not deploy normal user workloads directly.

### Backend

The backend is responsible for platform API behavior:

- Authentication.
- Setup status APIs.
- Setup orchestration APIs.
- Service catalog APIs.
- GitOps deployment request APIs.
- Observability APIs.
- Settings APIs.

The backend may coordinate setup through an explicit Launcher contract. It must not pretend it can inspect host tools or host filesystem state when running inside Kubernetes.

The backend must not directly `kubectl apply` or `kubectl delete` normal user workload resources.

### Setup Wizard

The Setup Wizard is the user-facing setup flow.

It should:

- Call backend setup/status APIs.
- Show clear setup stage progress.
- Show Launcher runtime messages.
- Explain when host-side actions require the Launcher.
- Surface actionable failures.
- Avoid implying that an in-cluster backend can verify host tools.

The Setup Wizard should not directly run host commands from the browser.

### Argo CD

Argo CD runs in `devdeploy-mgmt`.

It is responsible for applying normal user workload desired state to `devdeploy-workload`.

Argo CD should initially use a simple parent Application, such as:

```text
devdeploy-workloads
```

Future versions may evolve to App of Apps with one Argo CD Application per user app.

### GitHub Actions

GitHub Actions is responsible for:

- generating manifests
- validating manifests
- updating the GitOps repository according to repository policy

MVP/local flows may use direct commits. Stricter flows may use pull requests, checks, and review.

GitHub Actions must not deploy directly to Kubernetes.

## 6. Host Preflight Responsibilities

The Launcher should perform host preflight checks before creating or modifying local clusters.

Required checks:

- Docker CLI exists.
- Docker daemon is reachable.
- kind CLI exists.
- kubectl CLI exists.
- Git CLI exists.
- Helm CLI exists if Helm is used for platform bootstrap.
- Required ports are available.
- The user has permission to create kind clusters.
- Kubeconfig is readable and writable where needed.

Informational checks:

- Current Kubernetes context.
- Existing kind clusters.
- Docker Desktop resource availability.
- Available disk space.
- Existing DevDeploy setup files.

Preflight output should be structured and UI-friendly:

```text
id
label
status: ok | warning | failed
message
details
```

## 7. Port Discovery and Reservation Strategy

The Launcher should check required ports before cluster creation.

Recommended defaults:

```text
devdeploy-mgmt API server:       58080
devdeploy-mgmt HTTP ingress:     8080
devdeploy-mgmt HTTPS ingress:    8443

devdeploy-workload API server:   58081
devdeploy-workload HTTP ingress: 8081
devdeploy-workload HTTPS ingress:8444
```

If a port is busy, the Launcher should:

- fail before cluster creation
- identify the busy port
- explain which component needs it
- suggest an alternate port
- allow the user to rerun with custom ports

The Launcher should not silently choose random ports for important user-facing endpoints. Stable localhost URLs are part of the product experience.

Future versions may support automatic port suggestions, but the selected ports should still be shown to the user before creation.

## 8. Kind Config Generation Strategy

The Launcher should generate kind configs for both clusters.

Management cluster example:

```yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: devdeploy-mgmt
networking:
  apiServerAddress: "127.0.0.1"
  apiServerPort: 58080
nodes:
  - role: control-plane
    extraPortMappings:
      - containerPort: 80
        hostPort: 8080
        listenAddress: "127.0.0.1"
        protocol: TCP
      - containerPort: 443
        hostPort: 8443
        listenAddress: "127.0.0.1"
        protocol: TCP
```

Workload cluster example:

```yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: devdeploy-workload
networking:
  apiServerAddress: "127.0.0.1"
  apiServerPort: 58081
nodes:
  - role: control-plane
    extraPortMappings:
      - containerPort: 80
        hostPort: 8081
        listenAddress: "127.0.0.1"
        protocol: TCP
      - containerPort: 443
        hostPort: 8444
        listenAddress: "127.0.0.1"
        protocol: TCP
```

Generated configs should be written to a predictable local setup directory, for example:

```text
.devdeploy/local/kind/devdeploy-mgmt.yaml
.devdeploy/local/kind/devdeploy-workload.yaml
```

The generated config should be previewable before cluster creation.

## 9. Management Cluster Bootstrap Flow

Management bootstrap target:

```text
devdeploy-mgmt
```

Recommended flow:

1. Run host preflight checks.
2. Check whether `devdeploy-mgmt` already exists.
3. If it exists, verify it instead of recreating it.
4. If it does not exist, generate and apply kind config.
5. Verify kubeconfig context.
6. Install or verify ingress-nginx.
7. Install or verify Argo CD.
8. Deploy or verify DevDeploy frontend, backend, PostgreSQL, and platform components.
9. Verify DevDeploy Hub is reachable through localhost.
10. Record setup status.

The Launcher should be idempotent where possible. Re-running it should verify the current state and continue from the first incomplete stage.

## 10. Workload Cluster Creation Flow

Workload bootstrap target:

```text
devdeploy-workload
```

Recommended flow:

1. Verify management cluster is healthy.
2. Run workload cluster port checks.
3. Check whether `devdeploy-workload` already exists.
4. If it exists, verify it instead of recreating it.
5. If it does not exist, generate and apply kind config.
6. Install or verify workload ingress-nginx.
7. Create or verify workload namespaces.
8. Verify localhost app routing.
9. Record setup status.

Normal user applications should not be deployed by this flow. Demo deployment should still use the GitOps path.

## 11. Argo CD Workload Cluster Registration Flow

Argo CD runs in:

```text
devdeploy-mgmt
```

Workload target cluster:

```text
devdeploy-workload
```

Registration flow:

1. Verify Argo CD is running in `devdeploy-mgmt`.
2. Verify `devdeploy-workload` kubeconfig access from the host.
3. Create or update the Argo CD cluster Secret for `devdeploy-workload`.
4. Verify Argo CD can reach the workload cluster.
5. Create or verify parent Application `devdeploy-workloads`.
6. Confirm the parent Application tracks the GitOps workload path.
7. Confirm sync targets `devdeploy-workload`, not `devdeploy-mgmt`.

The initial model can use one parent Application. Future versions may generate per-app Argo CD Applications.

## 12. Launcher and Backend Communication Model

V1 should use a simple explicit contract.

Possible models:

### Script-first model

The user runs a PowerShell Launcher script. The script:

- performs host preflight
- creates/verifies clusters
- starts or verifies DevDeploy Hub
- prints the DevDeploy Hub URL

The Setup Wizard reads backend setup status, but host actions are mostly driven by the script.

This is the simplest V1 path.

### Local API model

The Launcher runs a local helper process exposing a localhost API. The backend or Setup Wizard can call that API for setup operations.

This gives a smoother UI but requires more security review.

### Recommended V1

Start with the script-first model.

Design the script output and status files so a later local API or graphical launcher can reuse the same concepts.

## 13. Setup Wizard Integration

The Setup Wizard should display setup state from backend APIs.

It should show:

- current runtime mode
- whether host checks are available
- management cluster status
- workload cluster status
- Argo CD registration status
- GitOps repository status
- demo deployment status

If the backend is running inside Kubernetes, the Wizard should clearly explain:

- host tools cannot be verified from the backend pod
- local setup actions require the Launcher
- preflight results from the in-cluster backend are runtime-limited

The Wizard should not directly execute host commands from the browser.

## 14. Status, Logs, and Progress Reporting

The Launcher should produce structured progress.

Recommended stage states:

```text
not_started
running
completed
warning
failed
skipped
```

Recommended fields:

```text
stage_id
label
status
message
started_at
completed_at
log_path
details
```

The Launcher should write logs to a local setup directory, for example:

```text
.devdeploy/local/logs/
```

Logs should not include secret values.

The backend and Wizard should display summarized status, not raw noisy command output.

## 15. Failure Recovery and Idempotency

The Launcher should be safe to rerun.

Idempotency rules:

- If `devdeploy-mgmt` exists, verify it instead of recreating blindly.
- If `devdeploy-workload` exists, verify it instead of recreating blindly.
- If ingress is installed, verify it instead of reinstalling blindly.
- If Argo CD is installed, verify it instead of reinstalling blindly.
- If the parent Application exists, verify source and destination before updating.

Failure handling:

- If ports are busy, stop before creating clusters.
- If cluster creation fails, keep logs and generated config.
- If platform install fails, retry from the failed stage.
- If partial setup exists, report what was found.
- Do not delete clusters automatically.
- Provide explicit cleanup instructions or a separate future cleanup command.

Destructive cleanup must require explicit user intent.

## 16. Security Boundaries

The Launcher has host-level setup power and must be treated carefully.

Security requirements:

- Do not print secrets.
- Do not write GitHub tokens to Git.
- Do not store sensitive tokens in browser localStorage.
- Do not log kubeconfig contents.
- Do not run arbitrary user-provided shell commands.
- Validate generated paths.
- Keep setup files under a known local directory.
- Avoid destructive cleanup by default.
- Require explicit confirmation for destructive actions.

Deployment boundary:

- Bootstrap operations may initialize platform infrastructure.
- Normal app deployment remains GitOps-only.
- The Launcher must not directly deploy normal user workloads.
- The backend must not directly deploy normal user workloads.
- GitHub Actions must not directly deploy normal user workloads.
- Argo CD is the Kubernetes applier for normal user workloads.

## 17. V1 Implementation Recommendation

Recommended first implementation:

- Windows PowerShell Launcher script.
- Deterministic kind config generation.
- Host preflight checks.
- Management cluster create/verify.
- Workload cluster create/verify.
- Argo CD workload cluster registration.
- Parent Application `devdeploy-workloads`.
- Local setup logs.
- Clear recovery messages.

Do not start with a graphical launcher.

Do not start with existing-cluster onboarding.

Do not start with cloud provider support.

Keep the first implementation boring, explicit, and easy to inspect.

## 18. Future Launcher Evolution

Future versions may evolve into:

- a small cross-platform CLI
- a signed desktop launcher
- a graphical setup experience
- a local privileged helper with a narrow API
- automated updates
- richer diagnostics
- safe cleanup/reset workflows
- existing-cluster onboarding

Future improvements should preserve the same core boundary:

```text
Launcher bootstraps the platform.
GitOps deploys user workloads.
Argo CD applies user workloads to Kubernetes.
```

