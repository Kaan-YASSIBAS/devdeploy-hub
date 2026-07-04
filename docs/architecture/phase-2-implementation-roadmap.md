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
- [Management Platform Bootstrap Plan](./management-platform-bootstrap-plan.md)
- [Backend Bootstrap Preparation](./backend-bootstrap-preparation.md)
- [Backend Bootstrap Manifest Strategy](./backend-bootstrap-manifest-strategy.md)
- [Backend Image Build and Load Strategy](./backend-image-build-load-strategy.md)
- [Backend Runtime Secret Strategy](./backend-secret-runtime-strategy.md)
- [Backend Bootstrap Launcher Design](./backend-bootstrap-launcher-design.md)
- [Frontend Bootstrap Preparation](./frontend-bootstrap-preparation.md)
- [Frontend Bootstrap Manifest Strategy](./frontend-bootstrap-manifest-strategy.md)
- [Argo CD Bootstrap Preparation](./argocd-bootstrap-preparation.md)
- [Argo CD Bootstrap Launcher Design](./argocd-bootstrap-launcher-design.md)
- [Workload Cluster Registration Design](./workload-cluster-registration-design.md)
- [GitOps Repository and Root Application Design](./gitops-repository-root-application-design.md)

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
- Keep the first Argo CD model simple with one Root Application named `devdeploy-workloads-root`.
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
5. Deploy and verify ingress-nginx, PostgreSQL, and the backend in `devdeploy-mgmt`.
6. Prepare, deploy, and verify the frontend in `devdeploy-mgmt`.
7. Implement workload cluster creation and verification in the Launcher.
8. Register `devdeploy-workload` in Argo CD running in `devdeploy-mgmt`.
9. Configure a Setup Wizard-selected GitOps repository and create or verify Root Application `devdeploy-workloads-root` targeting `devdeploy-workload/devdeploy-apps`.
10. Update Setup Wizard to show runtime, Launcher, management cluster, workload cluster, GitOps, Argo CD, and demo statuses.
11. Run demo app deployment through the normal GitOps path.
12. Add read-only workload observability and status mapping.
13. Perform security, credential, and logging hardening pass.

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

- Bootstrap and verify the initial management ingress, PostgreSQL, and backend components in `devdeploy-mgmt`.

The Phase 2D backend baseline is complete. The Launcher can build and load `devdeploy-backend:local`, ensure and verify the runtime Secret, bootstrap and verify backend resources, and initialize the database schema through explicit modes.

Completed baseline:

- `devdeploy-mgmt` is Ready.
- Management ingress-nginx is installed and Ready.
- Namespace `devdeploy` and PostgreSQL are installed and Ready.
- Backend manifests live under `platform/management/backend`.
- Backend image build/load and runtime Secret modes are implemented.
- Backend Deployment, Service, and Ingress are deployed and verified.
- Backend health verification succeeds.
- Alembic migrations are initialized and the `users` table is present.
- Launcher status reports backend image, Secret, and runtime state without exposing credentials.

Expected output:

- Management ingress, PostgreSQL, and backend are healthy in `devdeploy-mgmt`.
- `platform_bootstrap.status` remains `partial` until Argo CD bootstrap is complete.
- `devdeploy-workload` remains isolated from management platform bootstrap.

## 10. Phase 2E - Management Frontend Bootstrap

Goal:

- Prepare, deploy, and verify the DevDeploy frontend in `devdeploy-mgmt`.

Completed baseline:

- Phase 2E.1 documents the frontend build, Nginx runtime, API routing, image, and security requirements.
- Phase 2E.2 defines the future manifest layout, hostless ingress model, Service port decision, status contract, and Launcher mode boundaries.
- Phase 2E.3 adds the frontend Deployment, Service, Ingress, and Kustomization under `platform/management/frontend`.
- Build `devdeploy-frontend:local` with `VITE_API_BASE_URL=/api/v1`.
- Load the local image only into `devdeploy-mgmt`.
- Explicit frontend build, load, bootstrap, and read-only verify Launcher modes are implemented.
- Route frontend `/` and backend `/api` through management ingress.
- Verify the UI page through `http://localhost:8080/`.

Expected output:

- DevDeploy frontend is Running and Ready in `devdeploy-mgmt`.
- Browser API calls use the same-origin `/api/v1` route.
- The UI is reachable without routine port-forwarding.
- Platform status remains `partial` until Argo CD is installed.

## 11. Phase 2F - Argo CD Bootstrap and Workload Cluster Integration

Goal:

- Install and verify Argo CD in `devdeploy-mgmt`, then register the existing `devdeploy-workload` cluster as a deployment target.

Completed baseline:

- `devdeploy-workload` exists and is Ready.
- Phase 2F.1 documents the Argo CD installation, access, credential, registration, status, and safety decisions.
- Phase 2F.2 defines the explicit management Argo CD bootstrap and read-only verification Launcher contracts.
- Phase 2F.3 implements explicit, pinned Argo CD Helm bootstrap in `devdeploy-mgmt/argocd` with hostless `/argocd` local ingress and sanitized Launcher status.
- Phase 2F.4 implements strict read-only management Argo CD verification, including release metadata, component readiness, ingress access, credential Secret presence, and Application inventory.

Completed runtime baseline:

- Explicit workload registration and strict read-only verification Launcher modes are implemented.
- `devdeploy-workload` is registered through a dedicated identity with scoped registration visibility.
- Registration remains separate from Root Application creation and workload deployment.

Expected output:

- Argo CD is Ready in `devdeploy-mgmt`.
- Argo CD UI is reachable without routine port-forwarding.
- `devdeploy-workload` is registered and reported reachable.
- No user workloads are deployed as a side effect of registration.

## 12. Phase 2G - Workload Registration and GitOps Root Application

Goal:

- Register `devdeploy-workload` with management Argo CD and establish the authorization prerequisites for a future GitOps Root Application.

Completed design baseline:

- Phase 2G.1 defines endpoint discovery, Pod-network validation, credential/RBAC boundaries, the Launcher-managed cluster Secret, and sanitized registration status.
- Phase 2G.2 implements explicit endpoint discovery, rejects host loopback, validates candidates from a temporary management-cluster Pod, verifies TLS with the workload CA, and performs targeted probe cleanup without registering the cluster.
- Phase 2G.3 implements explicit, idempotent workload registration with a launcher-managed Argo CD cluster Secret. The local MVP uses a dedicated ServiceAccount, a local-only durable token, and read-only registration RBAC while keeping the Application count unchanged.
- Phase 2G.4 implements strict read-only workload registration verification for the cluster Secret contract, endpoint, identity/RBAC metadata, denied workload writes, Argo CD visibility evidence, and Application inventory.

Recommended tasks:

- Keep repository setup and Root Application creation separate from registration and permission grants.
- Continue to verify Argo CD connection health without requiring a persisted API session.
- Carry the verified registration and authorization boundaries into Phase 2I repository and Root Application setup.

Expected output:

- `devdeploy-workload` is registered and reachable from Argo CD.
- Registration credentials and endpoint details are sanitized.
- Argo CD registration is ready for a future source and Application.
- Namespace-scoped deployment authorization can be introduced and verified independently.
- No Application or user workload is created as a side effect of registration.

## 13. Phase 2H - Workload Permissions and Setup Wizard Integration

Goal:

- Add a controlled namespace-scoped workload deployment boundary, then make the Setup Wizard accurately represent multi-cluster setup progress.

Completed design baseline:

- Phase 2H.1 defines Launcher-owned namespace `devdeploy-apps`, namespaced Argo CD workload RBAC, explicit grant/verify modes, sanitized permission status, and prohibited cluster-wide grants.
- Phase 2H.2 implements guarded permission grant mode for `devdeploy-apps`, the namespaced deploy Role/RoleBinding, cluster Secret namespace scope, and post-grant authorization boundary verification without creating an Application or workload.
- Phase 2H.3 implements strict read-only verification for namespace/RBAC metadata, RoleBinding ownership, allowed workload writes, denied dangerous/outside writes, cluster-admin absence, and Application inventory.

Recommended tasks:

- Align the Argo CD cluster Secret namespace scope and future GitOps source with `devdeploy-apps`.
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

- Argo CD can reconcile reviewed workload resource types only in `devdeploy-apps`.
- Representative writes outside `devdeploy-apps` remain denied.
- Setup Wizard guides users through the multi-cluster lifecycle without pretending to run host commands from the browser.
- Setup completion reflects actual platform readiness.

## 14. Phase 2I - GitOps Repository and Root Application

Goal:

- Configure the GitOps source, bootstrap the first Root Application, and verify the empty-root baseline without deploying a user workload.

Completed design baseline:

- Phase 2I.1 defines Setup Wizard-managed create-new and existing GitHub repository modes.
- Phase 2I.2 implements explicit local-path GitOps structure initialization and sanitized repository status as a validation step before GitHub API integration.
- Phase 2I.3 implements guarded `devdeploy-workloads-root` reconciliation, exact source/destination/sync-policy verification, and before/after workload inventory checks.
- Phase 2I.4 implements strict read-only `devdeploy-workloads-root` verification with JSON-based contract checks, Synced/Healthy requirements, and an empty `devdeploy-apps` workload inventory.
- The V1 managed source path is `gitops/workloads/devdeploy-apps`.
- The preferred Root Application is `argocd/devdeploy-workloads-root`.
- The Root Application targets `https://devdeploy-workload-control-plane:6443` and namespace `devdeploy-apps`.
- Initial automated sync uses `selfHeal=true`, `prune=false`, and `CreateNamespace=false`.
- V1 CD accepts an existing image reference; source builds, registry pushes, and image promotion remain a later CI phase.

Recommended tasks:

- Preserve local-path mode as a development/MVP validation option without treating it as configured GitHub integration.
- Add authenticated GitHub repository selection or creation through explicit Setup Wizard/backend setup APIs.
- Initialize or validate the deterministic GitOps path without deploying a sample workload.
- Configure sanitized Argo CD repository access.
- Preserve strict read-only Root Application verification as the required post-bootstrap health check.

Expected output:

- `argocd/devdeploy-workloads-root` is `Synced` and `Healthy`.
- Its source and destination match the Phase 2I contract.
- `devdeploy-apps` contains no Deployment, Service, or Ingress before Phase 2J workload manifests are introduced.

## 15. Phase 2J - GitOps Workload Manifests and Delivery

Goal:

- Define and validate the first user-workload manifest contract, then prepare the backend Git commit flow without bypassing Argo CD.

Completed baseline:

- **Phase 2J.1:** define the V1 Deployment, Service, optional Ingress, per-app Kustomization, and root Kustomization contracts in [GitOps Workload Manifest Design](./gitops-workload-manifest-design.md).
- **Phase 2J.2:** add the reviewed `nginx-demo` sample Deployment and ClusterIP Service under `gitops/workloads/devdeploy-apps/apps/nginx-demo`, with no Ingress until workload exposure is designed.
- **Phase 2J.3:** verify the Root Application is `Synced` and `Healthy` at revision `647e486b42fc03f9d125af7c404e2b5df6dc121d`, with the `nginx-demo` Deployment, Service, and Pod healthy in `devdeploy-workload/devdeploy-apps`.
- This confirms the GitOps chain: GitHub push -> Argo CD Root Application -> `devdeploy-workload/devdeploy-apps` -> `nginx-demo` Deployment and Service.
- **Phase 2J.4:** define the backend repository workspace, validation, manifest generation, deterministic Kustomization update, commit/push, conflict, sanitization, and status contracts in [Backend GitOps Commit Flow Design](./backend-gitops-commit-flow-design.md).
- **Phase 2J.5a:** implement the pure backend GitOps writer foundation: typed validation, safe path resolution, deterministic Deployment and Service generation, root Kustomization editing, structural render validation, atomic create-only file writing, and temporary-directory unit tests. This phase adds no API endpoint, Git commit, or push.
- **Phase 2J.5b:** implement the backend local Git commit adapter with repository, branch, operation-state, expected-path, staging, commit-message, and output-sanitization checks. The adapter stages only operation-owned paths and stops at a verified local commit; it does not push or call Kubernetes.
- **Phase 2J.5c:** implement the backend Git push adapter with safe remote and branch validation, optional expected-commit pinning, credential-safe diagnostics, and non-force rejection handling. This phase stops after publishing the local commit and does not read Argo CD status.
- **Phase 2J.5d:** compose request validation, the create-only writer, local commit adapter, and push adapter into an internal deploy operation service. The service returns safe operation metadata after a successful push and does not expose an API or read Argo CD status.
- **Phase 2J.5e:** expose the internal deploy operation through the authenticated `POST /api/v1/gitops/apps` endpoint with server-controlled repository configuration and strict request fields. A successful response is `pushed_waiting_for_argocd`; the endpoint does not claim deployment success or read Argo CD status.
- **Phase 2J.5f:** document the repeatable [API-level local GitOps deploy smoke test](../operations/gitops-api-smoke-test.md), covering authentication, API submission, Git verification, passive Argo CD reconciliation, and read-only workload checks. This manual procedure adds no frontend or Argo CD polling code.
- **Phase 2J.5g:** define the read-only [Argo CD Status Read Model](./argocd-status-read-model-design.md), including commit-to-revision correlation, Root Application signals, label-scoped workload readiness, safe status transitions, least-privilege access, polling behavior, and sanitized errors. This phase adds no status endpoint or cluster mutation.
- **Phase 2J.5h:** implement the authenticated `GET /api/v1/gitops/apps/{app_name}/status` endpoint, typed status snapshots, an injectable reader boundary, and a pure exact-SHA status evaluator. Fake-reader tests cover pending, synced, progressing, deployed, degraded, missing, and unavailable states; no live cluster reader or mutation is added.
- **Phase 2J.5i:** add opt-in live read-only status integration through the Kubernetes Python client. The reader uses a management custom-object GET plus label-scoped namespaced Deployment, Service, and Pod LIST calls, keeps `unavailable` as the safe default mode, requires separate server-controlled workload access, and adds no cluster mutation or Secret reads.
- **Phase 2J.5i.1:** add explicit server-controlled management and workload kubeconfig context selection so a shared local multi-cluster kubeconfig cannot route either status reader through its current context accidentally.
- **Phase 2J.5j:** execute and record the successful [live API deploy and status smoke test](../operations/gitops-api-deploy-status-smoke-test.md). Commit `33e7df4f2fcf6d71d00bc94e51daaee11083e8b6` progressed from HTTP `202` `pushed_waiting_for_argocd` to HTTP `200` `deployed`; the Root Application was `Synced` and `Healthy`, the observed revision matched, and all workload readiness checks passed.
- **Phase 2J.5j.1:** complete non-root workload hardening with a numeric Pod identity, RuntimeDefault seccomp, disabled privilege escalation, and dropped Linux capabilities after Trivy KSV-0118 identified the initial smoke manifest.
- **Phase 2J.5j.2:** complete read-only-root hardening with nginx-compatible writable runtime paths through `emptyDir` volumes, addressing Trivy KSV-0014 without granting host filesystem access.
- The backend GitOps deploy, Argo CD reconciliation, workload readiness, and live read-only status chain is verified end to end and CI-clean.
- **Phase 2J.6:** add the Frontend GitOps Deploy Form to the Deployments page. The authenticated UI submits user-provided images to `POST /api/v1/gitops/apps`, polls the read-only status endpoint every three seconds with a two-minute bound, exposes manual refresh, and stops automatically at `deployed` or `degraded`. The frontend calls backend HTTP APIs only and performs no GitHub, Argo CD, or Kubernetes operations.
- V1 accepts a user-provided container image and does not require CI, an image build, or a registry push.
- All V1 app manifests target the pre-created `devdeploy-apps` namespace.
- App deletion remains unimplemented because the Root Application currently uses `prune=false`.

Planned milestones:

- **Phase 2J.7 (next):** polish live GitOps status presentation after the frontend deploy flow is exercised against the local multi-cluster environment.
- Define safe prune/delete behavior before claiming GitOps deletion is complete.
- Design and validate workload ingress exposure separately before presenting a local app URL as reachable.

Expected output:

- A sample app eventually deploys through:

  ```text
  UI -> Backend -> GitOps Repository -> Argo CD -> devdeploy-workload
  ```

- Generated workload folders are deterministic and render through Kustomize.
- Argo CD remains the only normal workload applier.
- No automatic delete behavior is claimed while the safe prune model remains unresolved.

## 16. Phase 2K - Observability and Status Integration

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

## 17. Phase 2L - Security Hardening Pass

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

## 18. Commit and PR Strategy

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

## 19. Validation Checklist

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
- Root Application `devdeploy-workloads-root` targets `devdeploy-workload/devdeploy-apps`.
- GitOps source path `gitops/workloads/devdeploy-apps` renders.
- Demo app deploys through the GitOps path.
- Demo app URL works at `http://<app-name>.localhost:8081`.
- Delete flow removes Git state and uses the separately reviewed safe-prune policy before reporting cluster deletion complete.
- No normal workload deployment occurs directly from backend.
- No normal workload deployment occurs directly from GitHub Actions.
- No secrets appear in Git, logs, API responses, or browser localStorage.

## 20. Rollback and Recovery Strategy

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

## 21. Definition of Done for Phase 2

Phase 2 is complete when:

- `devdeploy-mgmt` can be created locally.
- DevDeploy Hub runs in `devdeploy-mgmt`.
- `devdeploy-workload` can be created locally.
- Argo CD in `devdeploy-mgmt` can deploy to `devdeploy-workload`.
- Root Application `devdeploy-workloads-root` exists.
- Root Application `devdeploy-workloads-root` targets `devdeploy-workload/devdeploy-apps`.
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

## 22. Future Phase Handoff

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
