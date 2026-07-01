# Argo CD Bootstrap Preparation

## 1. Purpose

This document defines the preparation decisions for installing Argo CD in the DevDeploy Hub management cluster and later registering the workload cluster.

It builds on:

- [Multi-Cluster Redesign](./multi-cluster-redesign.md)
- [Bootstrapper / Launcher Design](./bootstrapper-launcher-design.md)
- [GitOps Repository Layout and Argo CD Application Model](./gitops-repository-argocd-model.md)
- [Localhost Networking and Port Strategy](./localhost-networking-port-strategy.md)
- [Security Boundaries and Credentials Model](./security-credentials-boundaries.md)

The DevDeploy frontend, backend, PostgreSQL, and management ingress are running in `devdeploy-mgmt`. Argo CD is the next platform component because it will reconcile Git state into the workload cluster.

The normal workload path remains:

```text
UI -> Backend -> GitHub/GitOps Repository -> Argo CD -> devdeploy-workload
```

Argo CD is the only normal Kubernetes applier for user workloads. The backend must not directly apply or delete normal user workloads, and GitHub Actions must not deploy directly to either cluster.

This phase is preparation only. It does not install Argo CD or mutate cluster state.

## 2. Placement and Installation Method

V1 targets:

| Setting | Value |
| --- | --- |
| Cluster | `devdeploy-mgmt` |
| Context | `kind-devdeploy-mgmt` |
| Namespace | `argocd` |
| Release | `argocd` |
| Component | Argo CD |
| Installation owner | DevDeploy Launcher |

The recommended V1 installation method is Helm, consistent with management ingress-nginx and PostgreSQL bootstrap.

Future implementation should:

- Add explicit Launcher mode `-BootstrapManagementArgoCD`.
- Use the official Argo Helm chart repository `https://argoproj.github.io/argo-helm`, commonly added as repository name `argo` with chart `argo/argo-cd`.
- Pin an exact chart version during implementation after compatibility and security validation.
- Create or verify namespace `argocd` only in the explicit bootstrap mode.
- Use idempotent `helm upgrade --install` behavior with explicit context and namespace.
- Wait for required Argo CD components to become Ready.
- Avoid automatic uninstall or destructive cleanup when bootstrap fails.

No chart version is selected in this preparation phase. The implementation must not use an unpinned floating chart version.

## 3. Argo CD Access Model

V1 uses a host-specific management ingress:

```text
http://argocd.localhost:8080/
```

Existing management routes remain unchanged:

```text
http://localhost:8080/      -> DevDeploy frontend
http://localhost:8080/api   -> DevDeploy backend
```

Argo CD must not use a hostless `/` ingress because the DevDeploy frontend already owns that route. V1 also avoids `/argocd` path-based routing because Argo CD path prefix, base href, redirects, and callback configuration add unnecessary local setup complexity.

Implementation requirements:

- Use ingress-nginx in `devdeploy-mgmt`.
- Set ingress host to `argocd.localhost`.
- Use HTTP only for V1.
- Do not require routine port-forwarding for normal UI access.
- Configure the Argo CD server for an HTTP ingress backend, including insecure server mode when required by the selected chart values.
- Verify both the Argo CD server Service and host-specific ingress route.

Port-forwarding may remain a troubleshooting tool, but it is not the normal access model.

## 4. Admin Credential Handling

The initial Argo CD administrator credential is sensitive.

Rules:

- Do not commit the password or its Secret data to Git.
- Do not write the password to Launcher logs or `launcher-status.json`.
- Do not expose it through frontend state, browser storage, or backend API responses.
- Verification may report only whether the initial admin credential Secret and expected key are present.
- A future explicit credential-display workflow requires separate design, deliberate user intent, console-safety rules, and no persistence.
- Until such a workflow exists, documentation may provide a manual retrieval command that the user runs knowingly.

The Launcher should not automatically rotate or delete the initial password during initial bootstrap. Production-grade SSO, account policy, and external secret management are outside V1.

## 5. Workload Cluster Registration Model

Argo CD in `devdeploy-mgmt` must later register `devdeploy-workload` as a deployment target.

Registration is separate from Argo CD installation and must use explicit, idempotent Launcher modes:

```text
-RegisterWorkloadClusterWithArgoCD
-VerifyArgoCDWorkloadCluster
```

Possible approaches include:

1. **Host `argocd` CLI registration**
   - Familiar and supported by Argo CD.
   - Requires CLI installation, login state, and reliable API access.
   - Often creates broad credentials unless additional controls are applied.

2. **Launcher-managed Argo CD cluster Secret**
   - Deterministic and suitable for structured status.
   - Requires careful credential generation, Secret handling, idempotency, and redaction.
   - Keeps registration independent of interactive CLI login state.

3. **Raw workload kubeconfig reuse**
   - Simple for local development.
   - Risks storing excessive client credentials and cluster-admin-style access.
   - Must not be copied into logs, status files, Git, or browser-visible state.

The preferred V1 direction is a deterministic Launcher-managed Argo CD cluster Secret in namespace `argocd`, backed by credentials created specifically for `devdeploy-workload`.

The registration endpoint requires deliberate handling. The host kubeconfig endpoint `https://127.0.0.1:58081` is not valid from inside an Argo CD Pod because Pod loopback refers to that Pod, not the Windows host. Future implementation must:

- Discover or construct an API endpoint reachable from `devdeploy-mgmt` Pods.
- Preserve CA verification and the expected Kubernetes API server name.
- Verify connectivity from the Argo CD runtime context before storing registration state.
- Avoid using `insecureSkipVerify` as the default workaround.
- Fail with actionable diagnostics if Docker Desktop or kind networking does not provide a stable reachable endpoint.

The credential should be narrowly scoped where practical:

- Create a dedicated ServiceAccount in `devdeploy-workload` during an explicit registration step.
- Grant only the permissions required for Argo CD to manage the selected workload namespaces and resource kinds.
- Avoid cluster-admin when namespace-scoped operation satisfies the V1 workload model.
- Store the resulting connection configuration only as a Kubernetes Secret in `devdeploy-mgmt/argocd`.
- Never write raw tokens, CA data, or kubeconfig content to Launcher status or logs.

Registration grants Argo CD visibility and controlled apply access to `devdeploy-workload`. It must not create Applications or deploy user workloads by itself.

## 6. GitOps Repository and Application Model

After bootstrap and workload registration, Argo CD will watch a GitOps repository or repository path containing generated workload manifests.

The initial model remains deliberately simple:

- One parent Argo CD Application named `devdeploy-workloads`.
- Source path `infra/kubernetes/generated/workloads`.
- Destination cluster `devdeploy-workload`.
- Generated apps remain under `infra/kubernetes/generated/workloads/apps/<app-name>/`.

The repository update policy may use direct commits for local MVP flows or pull requests for stricter flows. In both cases:

- GitHub Actions may generate, validate, and update Git state.
- GitHub Actions must not run `kubectl apply` or deploy directly to clusters.
- The backend may request GitOps changes but must not directly mutate normal user workloads.
- The GitHub token remains backend-side and must never enter the frontend.
- Argo CD reconciles accepted Git state into `devdeploy-workload`.

The layout remains compatible with future per-app Argo CD Applications for independent health, sync, rollback, and lifecycle history.

GitHub repository creation, repository credential setup, and CI automation remain future phases after Argo CD bootstrap and workload registration are verified.

## 7. Future Launcher Modes

The detailed bootstrap and read-only verification contracts are defined in [Argo CD Bootstrap Launcher Design](./argocd-bootstrap-launcher-design.md).

Required future explicit modes:

- `-BootstrapManagementArgoCD`
  - Install or verify the pinned Argo CD Helm release in `devdeploy-mgmt/argocd`.
- `-VerifyManagementArgoCD`
  - Perform read-only component, ingress, and credential-availability checks.
- `-RegisterWorkloadClusterWithArgoCD`
  - Create or reconcile scoped workload access and the Argo CD cluster Secret.
- `-VerifyArgoCDWorkloadCluster`
  - Verify the cluster Secret and Argo CD connection status without exposing credentials.

Possible later modes:

- `-BootstrapGitOpsRootApplication`
- `-VerifyGitOpsRootApplication`

Each mutating mode must be explicit. Verification modes must remain read-only. Default Launcher behavior must remain read-only preflight.

## 8. Future Status Contracts

### `platform_bootstrap.components.argocd`

Proposed shape:

```json
{
  "installed": false,
  "ready": false,
  "namespace": "argocd",
  "release": "argocd",
  "server_deployment": "argocd-server",
  "repo_server_deployment": "argocd-repo-server",
  "application_controller_statefulset": "argocd-application-controller",
  "ingress_enabled": true,
  "ui_access": "http://argocd.localhost:8080/",
  "status": "not_started",
  "message": "Argo CD bootstrap has not been requested.",
  "checked_at": "<ISO-8601 timestamp>"
}
```

Allowed status values should follow existing Launcher conventions such as `not_started`, `ready`, `warning`, `degraded`, `error`, and `unknown` where applicable.

### `platform_bootstrap.components.argocd_workload_cluster`

Proposed shape:

```json
{
  "registered": false,
  "ready": false,
  "target_cluster": "devdeploy-workload",
  "target_context": "kind-devdeploy-workload",
  "argocd_namespace": "argocd",
  "cluster_secret_present": false,
  "argocd_connection_status": "unknown",
  "status": "not_started",
  "message": "Workload cluster registration has not been requested.",
  "checked_at": "<ISO-8601 timestamp>"
}
```

Status must contain only sanitized metadata and booleans. It must not contain admin passwords, bearer tokens, CA bundles, kubeconfigs, client certificates, private keys, or Secret data.

## 9. Safety Boundaries

- Argo CD bootstrap targets only `devdeploy-mgmt` and namespace `argocd`.
- Workload registration may create narrowly scoped registration resources in `devdeploy-workload`, but only through an explicit future mode.
- Registration must not deploy user workloads or create the root workload Application.
- Backend normal workload permissions remain read-only.
- GitHub Actions receive no cluster credentials and perform no cluster deployment.
- Argo CD remains the only normal workload applier.
- Frontend receives no GitHub, Argo CD admin, Kubernetes, or database credentials.
- Launcher logs and status never contain raw admin passwords, cluster tokens, kubeconfigs, certificates, or Secret values.
- Bootstrap and registration must be idempotent and must not perform automatic destructive cleanup.
- No `kubectl delete`, database reset, or platform redeployment belongs to this preparation phase.

## 10. V1 Limitations

- Local HTTP only; TLS hardening is postponed.
- No production SSO or identity-provider integration.
- No external DNS or custom domains.
- No high-availability Argo CD topology.
- No production secret manager integration.
- Local kind management and workload clusters only.
- No automated application deployment until repository credentials and the root Application model are implemented.
- No automated GitHub repository creation or CI provisioning.
- No full App of Apps or per-app Application model yet.

## 11. Definition of Done for Future Implementation

### Argo CD bootstrap

- Namespace `argocd` exists in `devdeploy-mgmt`.
- A pinned Argo CD Helm release named `argocd` exists.
- Required Argo CD server, repository server, and application controller workloads are Ready.
- Argo CD UI is reachable at `http://argocd.localhost:8080/`.
- Initial admin credential availability is verifiable without exposing its value.
- `platform_bootstrap.components.argocd` is sanitized and reports `ready`.
- Overall platform status remains `partial` until workload registration and the GitOps Application model are ready.

### Workload cluster registration

- `devdeploy-workload` is registered in Argo CD.
- Argo CD reports the workload cluster reachable.
- Registration credentials are scoped and stored only in protected Kubernetes Secrets.
- `platform_bootstrap.components.argocd_workload_cluster` reports `ready` without credential material.
- No root Application or user workload is deployed as a side effect of registration.
- No workload cluster credentials appear in Git, logs, status files, API responses, or browser storage.

## 12. Phase Handoff

Phase 2F.1 establishes the preparation decisions in this document. Phase 2F.2 defines the Launcher contracts for management Argo CD bootstrap and verification. Runtime installation remains future work in Phase 2F.3 and Phase 2F.4.
