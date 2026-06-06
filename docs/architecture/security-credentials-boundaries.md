# Security Boundaries and Credentials Model

## 1. Overview

This document defines the security boundaries, credential ownership, token handling, kubeconfig handling, browser storage rules, logging safety, and permission model for the DevDeploy Hub local-first multi-cluster architecture.

The higher-level architecture is defined in:

- [Multi-Cluster Redesign](./multi-cluster-redesign.md)
- [Bootstrapper / Launcher Design](./bootstrapper-launcher-design.md)
- [Setup Wizard Multi-Cluster Lifecycle Design](./setup-wizard-multi-cluster-lifecycle.md)
- [GitOps Repository Layout and Argo CD Application Model](./gitops-repository-argocd-model.md)
- [Localhost Networking and Port Strategy](./localhost-networking-port-strategy.md)
- [Workload Observability and Status Model](./workload-observability-status-model.md)

In the target architecture:

- DevDeploy platform components run in the management cluster: `devdeploy-mgmt`.
- User applications run only in the workload cluster: `devdeploy-workload`.
- Argo CD runs in `devdeploy-mgmt` and deploys user workloads to `devdeploy-workload`.
- The Launcher runs on the user's host machine and may perform platform bootstrap operations.
- The Setup Wizard is the user-facing setup orchestrator and must not run host commands from the browser.
- The backend runs in `devdeploy-mgmt` and must not assume host Docker, kind, kubectl, kubeconfig, port, or filesystem access.

Normal workload deployment remains GitOps-only:

```text
UI -> Backend -> GitHub/GitOps Repository -> Argo CD -> Workload Kubernetes Cluster
```

## 2. Design Goals

- Keep credentials owned by the narrowest component that needs them.
- Prevent secrets from entering browser localStorage, frontend bundles, Git history, logs, and API responses.
- Keep backend workload permissions read-only for observability.
- Keep Argo CD as the Kubernetes applier for normal user workloads.
- Keep GitHub Actions limited to manifest generation, validation, and GitOps repository updates.
- Make setup status useful without exposing sensitive values.
- Keep V1 local-only and bound to loopback by default.
- Preserve a clear path for future stronger secret storage and multi-user permission models.

## 3. Non-Goals

- This document does not implement runtime code.
- This document does not change backend, frontend, Kubernetes manifests, or GitHub Actions workflows.
- This document does not define cloud provider IAM.
- This document does not add multi-tenant or team RBAC.
- This document does not grant backend write permissions for normal workload lifecycle.
- This document does not allow GitHub Actions to deploy directly to clusters.
- This document does not define a production-grade secret manager integration for V1.

## 4. Trust Boundaries

DevDeploy Hub should treat these as separate trust boundaries:

- Browser UI.
- Backend API.
- PostgreSQL database.
- Launcher running on the host.
- Management cluster.
- Workload cluster.
- Argo CD.
- GitHub/GitOps repository.
- GitHub Actions.
- Local filesystem.
- Kubernetes Secrets.

Each boundary should exchange only the data it needs.

Important rules:

- Browser UI is not a safe place for infrastructure credentials.
- Backend API responses must not include raw secrets.
- GitHub repository content must not include tokens, kubeconfigs, passwords, or cluster credentials.
- GitHub Actions must not receive Kubernetes credentials for normal deployment.
- Argo CD may hold workload cluster credentials because it is the applier.
- Launcher may access host credentials during bootstrap, but it must not print or persist them unsafely.

## 5. Credential Inventory

Expected credential classes:

- User login credentials.
- JWT signing secret.
- DevDeploy API tokens.
- PostgreSQL credentials.
- GitHub workflow/repository token.
- GitHub Actions token.
- Argo CD admin or automation credentials.
- Workload cluster kubeconfig or service account token.
- Management cluster kubeconfig or service account token.
- Observability access credentials, if introduced later.
- TLS private keys, if HTTPS is introduced later.

Ownership guidance:

| Credential | Preferred Owner |
| --- | --- |
| User password hash | PostgreSQL |
| JWT signing secret | Kubernetes Secret in `devdeploy-mgmt` |
| DevDeploy API token hash | PostgreSQL |
| PostgreSQL password | Kubernetes Secret in `devdeploy-mgmt` |
| GitHub workflow token | Protected server-side secret |
| GitHub Actions token | GitHub Actions runtime |
| Workload cluster credentials | Argo CD Secret in `devdeploy-mgmt` |
| Host kubeconfig | Launcher/host OS only |
| Setup progress | Browser localStorage, non-sensitive only |

## 6. Browser Storage Rules

Browser localStorage may store only non-sensitive UI state.

Allowed examples:

- Onboarding progress.
- Current setup step.
- Setup completion flag.
- Selected language.
- Selected theme.
- Non-sensitive setup display preferences.

Browser localStorage must not store:

- GitHub tokens.
- Kubeconfigs.
- Argo CD tokens.
- Cluster credentials.
- Database passwords.
- API secrets.
- Raw setup logs containing sensitive output.
- Kubernetes Secret values.
- JWT signing secrets.

Setup reset in the UI must reset local onboarding state only. It must not delete credentials, clusters, GitOps repository contents, Argo CD configuration, deployed workloads, or API tokens unless a separate explicit destructive action exists.

## 7. Backend Secret Handling

The backend may use protected server-side secrets for integration operations.

Backend rules:

- Do not return raw secret values in API responses.
- Do not log raw secret values.
- Do not include secrets in exception messages.
- Do not expose GitHub tokens to the frontend.
- Do not expose kubeconfigs or cluster tokens to the frontend.
- Store only hashes for DevDeploy API tokens.
- Show newly created DevDeploy API tokens only once.
- Prefer revocation over hard deletion when auditability matters.

If future versions require storing integration secrets in the database, they should use encryption or a dedicated secret manager. V1 may rely on Kubernetes Secrets for platform integration secrets.

## 8. Launcher Credential Handling

The Launcher runs on the user's host machine and may perform platform bootstrap operations.

The Launcher may access:

- Host Docker context.
- kind configuration.
- kubectl context.
- host kubeconfigs.
- local setup files.
- Git configuration.
- Helm repositories and charts, if required for bootstrap.

Launcher rules:

- Do not print kubeconfig contents.
- Do not print tokens.
- Do not print passwords.
- Write logs under a known local setup directory.
- Sanitize logs before surfacing them in the UI.
- Require explicit user intent for destructive actions.
- Verify existing clusters before recreating anything.
- Do not directly deploy normal user workloads.

Bootstrap operations are allowed for platform initialization. Normal app deployment remains GitOps-only.

## 9. GitHub Token and Repository Access Model

GitHub tokens should be stored server-side as protected secrets when needed.

GitHub token rules:

- Do not commit tokens to Git.
- Do not place tokens in frontend bundles.
- Do not store tokens in browser localStorage.
- Do not return tokens in API responses.
- Do not print tokens in logs.
- Use the minimum repository permissions needed.

GitHub Actions should receive only the permissions needed for:

- Manifest generation.
- Manifest validation.
- GitOps repository updates according to repository policy.

GitHub Actions must not receive Kubernetes cluster credentials for normal deployment. It must not deploy directly to Kubernetes.

Repository update policies may differ:

- MVP/local flows may use direct commits.
- Stricter flows may use pull requests and branch protection.

The security boundary remains the same: GitHub Actions updates Git, and Argo CD applies Git state to Kubernetes.

## 10. Kubeconfig Handling

Kubeconfigs are sensitive credentials.

Rules:

- Kubeconfigs must not be committed to Git.
- Kubeconfigs must not be stored in browser localStorage.
- Kubeconfigs must not be returned by backend APIs.
- Kubeconfig contents must not be printed in logs.
- Host kubeconfigs should remain on the host and be protected by local OS permissions.
- Workload cluster credentials required by Argo CD should be stored as Kubernetes Secrets in `devdeploy-mgmt`.

The in-cluster backend should use in-cluster service account credentials for management cluster reads where appropriate. It should use explicitly configured read-only credentials for workload observability if needed.

## 11. Argo CD Workload Cluster Credential Model

Argo CD is responsible for applying normal user workloads to `devdeploy-workload`.

Argo CD may hold workload cluster credentials as Kubernetes Secrets in `devdeploy-mgmt`.

Credential rules:

- Workload cluster credentials must not be committed to Git.
- Workload cluster credentials should be scoped to required workload namespaces where possible.
- Argo CD should have the permissions required to sync generated workload resources.
- Argo CD should not receive unnecessary cluster-admin permissions when narrower permissions are practical.
- Argo CD credential rotation should be possible without changing generated workload manifests.

The backend may read Argo CD Application status, but it should not need access to raw Argo CD cluster credentials.

## 12. Kubernetes RBAC Model

Kubernetes permissions should follow least privilege.

Backend workload observability permissions should be read-only:

- `get`
- `list`
- `watch`

Backend should not have normal workload lifecycle write permissions:

- `create`
- `update`
- `patch`
- `delete`

This includes avoiding backend permissions for direct scaling, restarting, patching, applying, or deleting user workloads as part of the normal product flow.

Argo CD permissions should be scoped to applying generated workload resources in `devdeploy-workload`.

Launcher permissions are host-side bootstrap permissions and should be treated separately from backend runtime RBAC.

## 13. Observability Permission Model

The backend may read observability data if credentials are scoped appropriately.

Allowed read surfaces:

- Kubernetes Deployments.
- Pods.
- Services.
- Ingress resources.
- Events, if useful and safe.
- Argo CD Application status.
- Logs through configured log aggregation or read-only Kubernetes log APIs.
- Metrics through configured metrics APIs.

Observability rules:

- Do not mutate workload resources during status collection.
- Do not expose secrets from pod environment, mounted secrets, or Kubernetes Secret objects.
- Apply limits to log and metrics queries.
- Sanitize errors before returning them to the UI.
- Keep management logs separate from workload app logs.

## 14. Setup Wizard Security Rules

The Setup Wizard is a user-facing orchestrator, not a host command executor.

Rules:

- Do not run host commands from the browser.
- Do not store secrets in localStorage.
- Do not display raw secret values.
- Show whether a secret or integration is configured without displaying the value.
- Show Launcher status and runtime limitations clearly.
- If host actions are required, rely on an explicit Launcher contract.
- Setup reset clears local onboarding state only.

The Wizard may show:

- "GitHub token configured" without showing the token.
- "Workload cluster registered" without showing kubeconfig.
- "Launcher waiting" without printing raw setup logs.

## 15. Logging and Status Redaction

Logs and status messages must be sanitized.

Never log or return:

- GitHub tokens.
- Kubeconfig contents.
- Kubernetes service account tokens.
- Database passwords.
- JWT signing secrets.
- API tokens.
- TLS private keys.
- Raw Kubernetes Secret values.

Status messages should prefer:

- Safe identifiers.
- Resource names.
- Namespace names.
- Status codes.
- Sanitized error categories.
- Short actionable guidance.

If command output may contain secrets, the Launcher should redact before writing logs or sending status to the backend.

## 16. GitOps Repository Security Rules

The GitOps repository is the desired-state source for generated workload manifests.

It must not contain:

- GitHub tokens.
- Kubeconfigs.
- Cluster credentials.
- Database passwords.
- JWT signing secrets.
- Raw API tokens.
- Local machine paths containing sensitive values.
- Generated Secret manifests with real secret values.

Generated manifests should avoid secret material. If a workload needs secrets in the future, the design should use a reviewed secret integration such as external secret management or local-only sealed/encrypted secrets.

Secret-like values should be detected or rejected where practical during manifest generation and validation.

## 17. Local-Only Security Posture for V1

V1 is local-first and local-only by default.

Recommended posture:

- Bind local platform endpoints to `127.0.0.1`.
- Use HTTP by default for local-only V1.
- Reserve HTTPS ports for future TLS support.
- Do not expose the platform on all network interfaces by default.
- Do not assume multi-user remote access.
- Keep secret storage simple but explicit.
- Use Kubernetes Secrets for platform runtime secrets.
- Use browser localStorage only for non-sensitive onboarding state.

If future versions support non-loopback binding, cloud clusters, existing cluster onboarding, multi-user RBAC, or remote access, this security model must be revisited.

## 18. Failure and Recovery Security Cases

Common security-sensitive failure cases:

- GitHub token missing.
- GitHub token invalid or insufficiently scoped.
- Workload cluster credential registration fails.
- Kubeconfig is unavailable or unreadable.
- Launcher setup logs contain sensitive command output.
- Argo CD credentials are stale.
- GitOps repository validation detects secret-like values.
- Setup reset is confused with destructive cleanup.

Recommended behavior:

- Report missing or invalid secrets without printing values.
- Provide recovery steps that do not require pasting secrets into the browser.
- Fail closed when credential scope is unclear.
- Require explicit confirmation for destructive Launcher actions.
- Keep setup reset non-destructive.
- Keep normal workload cleanup GitOps-based.

## 19. V1 Implementation Recommendation

V1 should implement a conservative model:

1. Store browser setup progress only as non-sensitive local state.
2. Keep GitHub workflow token as a server-side protected secret.
3. Keep workload cluster credentials in Argo CD Kubernetes Secrets in `devdeploy-mgmt`.
4. Keep backend workload access read-only.
5. Keep generated manifests secret-free.
6. Keep Launcher logs sanitized.
7. Bind local access to `127.0.0.1`.
8. Keep backend direct workload mutation out of scope.
9. Keep GitHub Actions cluster credentials out of scope.
10. Keep Argo CD as the applier for normal workloads.

This provides a safe local-first baseline without overbuilding a production secret-management system too early.

## 20. Future Enhancements

Future enhancements may include:

- Dedicated local secret store integration.
- Encrypted integration secrets in the database.
- External Secrets Operator for workload secrets.
- Sealed Secrets or SOPS for GitOps-compatible encrypted secrets.
- Stronger Launcher/backend authentication.
- Credential rotation UI.
- Argo CD project-level and namespace-level scoping improvements.
- Per-app GitOps permissions.
- Multi-user RBAC.
- Remote access hardening.
- HTTPS with local trusted certificates.
- Audit log for credential-related actions.
- Secret scanning for generated manifests and repository updates.

Any future enhancement must preserve the core boundary: normal workloads are declared in Git, applied by Argo CD, and observed by read-only status paths.
