# Reliability and Failure Hardening

Date: 2026-09-06

Status: audit and design only

This document records the reliability audit of the current DevDeploy Hub create, update, destroy, recovery, runtime-status, and preview paths. It proposes guardrails for normal workload and infrastructure failures without changing the established ownership model:

- Database records are product truth.
- GitOps is desired-state truth.
- Argo CD reports reconciliation of Git desired state.
- Kubernetes reports workload runtime health.
- Runtime resources are not manually patched as the normal recovery path.

The recently observed host-local-only image failure is an expected registry/image-availability failure. The product defect is not that kind cannot pull an image known only to the host Docker daemon. The hardening requirement is to classify that failure accurately, keep Edit and Destroy available, and preserve consistency.

## Audit Scope and Current Architecture

The audit traced these current paths:

- Create: `POST /api/v1/gitops/apps` -> `DeployWorkloadOperationService` -> `GitOpsWorkloadWriter` -> Git commit/push -> `GitOpsProductRecordService`.
- Update: `PATCH /api/v1/deployment-records/{id}/gitops` -> `UpdateWorkloadOperationService` -> writer update -> Git commit/push -> `DeploymentRecordService.mark_gitops_updated`.
- Destroy: `POST /api/v1/deployment-records/{id}/destroy` -> `DestroyWorkloadOperationService` -> Git commit/push -> scoped Argo reconciliation/runtime cleanup -> `mark_destroyed`.
- Recovery/reconcile: DeploymentRecord endpoints regenerate deterministic manifests, request Argo reconciliation, and verify runtime readiness before reactivation where required.
- Status: `KubernetesGitOpsStatusReader` reads the Root Application plus Deployment, Service, and Pod state. `ProductRuntimeStatusService`, `DeploymentDriftService`, and `DeploymentReconcileStatusService` expose separate runtime, drift, and reconciliation views.
- Frontend progress: create, update, and destroy use React Query polling plus in-memory operation state in `DeploymentsPage`.
- Preview: an owner-scoped short-lived preview session reaches a Ready pod through Kubernetes pod port-forward. Sensitive DevDeploy headers are filtered before the upstream request.

## Findings

### Existing behavior to preserve

The following foundations are already safe and should be extended rather than rewritten:

- Writers validate names, paths, repository boundaries, expected changed paths, and deterministic manifest content.
- Managed GitHub operations use temporary clones, so normal in-cluster operations do not dirty the application source checkout.
- Update touches only the target app manifest set and no-change updates do not create commits.
- Create/update persist product desired fields only after a successful Git push.
- Destroy removes only the selected app directory and root Kustomization entry; an empty `resources: []` root is supported.
- The Root Application uses automated prune, self-heal, and allow-empty behavior.
- Destroy retries are owner-scoped and archived destroyed records can retry pending cleanup.
- Destroy cleanup checks the exact Git revision, successful Argo operation, resource identity, labels, and stable absence.
- Runtime snapshots already collect Deployment generations, replica counts, pod phases, restart counts, waiting reasons, and failure flags.
- Reconcile status already refuses to claim `synced` without Git revision, Root Application, drift, and runtime evidence.
- ServiceDefinition create/reuse, final-destroy archive, and recovery reactivation safeguards exist.
- Preview requires a Ready workload, uses a short-lived deployment-scoped session, limits response size/time, rejects unsafe paths and redirects, and strips DevDeploy credentials upstream.
- Kubernetes clients install the existing bearer-token refresh hook.

### Reliability gaps found

1. Runtime failures are collected but collapsed. `WorkloadSnapshot` detects `ImagePullBackOff`, `ErrImagePull`, `CrashLoopBackOff`, failed pods, restarts, and Deployment failure conditions. `DeploymentRuntimeStatusRead` exposes only `running`, `progressing`, `not_found`, or `unknown`; failures become generic `unknown` with a generic message. The frontend therefore cannot distinguish a real image failure from unavailable telemetry.

2. `desired_state="pending"` is overloaded as the long-lived state of an active published deployment. It is not a reliable operation-progress field. `status_summary` is free text, and some dashboard/frontend decisions depend on substring matching. Create versus update versus recovery, target revision, retryability, and terminal failure are not durably represented.

3. Frontend operation progress is process-local browser state. Refreshing the page loses create/update/destroy progress. A timeout can recover while that page stays open, but there is no durable operation identity from which a new page or a restarted backend can reconstruct the same timeline.

4. A successful Git push followed by failed DB persistence has an explicit sanitized error but incomplete automated repair. Create is the highest-risk case: a retry sees an existing app directory and can fail before product records are restored. Update leaves DB fields/commit behind Git until a deliberate retry or reconcile. Destroy is more recoverable because a repeated destroy can observe no Git changes and finish record archival.

5. The generic `PATCH /deployment-records/{id}` schema still permits changes to `app_name`, namespace, manifest path, commit SHA, and service linkage outside the GitOps update contract. This can violate immutable identity and create DB/GitOps/runtime divergence even though the dedicated GitOps update endpoint is safe.

6. Root Application health is global. `DeploymentReconcileStatusService` returns `degraded` for every evaluated record when the Root Application is globally Degraded or has a failure condition, before checking whether the individual Deployment/Service resource is the affected workload. One bad app can therefore make unrelated healthy apps look degraded.

7. Runtime exception handling loses cause. Broad catches convert permission denial, authentication/configuration failure, timeout, and network unreachability to the same `unknown` runtime result. This prevents accurate `cluster_unreachable` versus workload-failed messaging.

8. Create status compares the Root Application revision as an exact full SHA, while DeploymentRecord reconcile and destroy/recovery barriers support safe full/short SHA matching. The inconsistent rule can leave create polling waiting if a valid short revision is returned.

9. Update requests have no optimistic concurrency token or durable per-deployment operation lock. Concurrent updates can race from the same DB state; Git push rejection prevents silent remote overwrite, but the loser receives a generic operation failure and there is no structured retry contract.

10. Dashboard classification still infers completed/failed operations from commit presence and `status_summary` text. A commit proves publication, not runtime success. Missing runtime after a published commit can be classified as failed without a reconciliation grace period, while runtime `unknown` can be treated as pending even when the cause is infrastructure loss.

11. ServiceDefinition repair currently performs writes during list/read paths. It repairs archived services linked to active deployments and archives active services linked only to inactive records. The invariant is useful, but hidden writes during GET make failures and transaction timing harder to reason about.

12. The destroy path currently combines Root Application prune with a label-verified direct Kubernetes Deployment/Service cleanup safeguard after an exact-revision barrier. This is narrowly scoped and tested, but it is a second runtime mutation path. The target architecture should treat Argo prune as the normal path and reserve exact cleanup for an explicit, auditable recovery policy if it remains necessary.

13. Recovery readiness reports prolonged image-pull and crash-loop failures as generic pending until timeout because the recovery client checks availability but does not expose pod failure reasons.

14. Existing tests strongly cover deterministic writes, ownership, no-change commits, revision barriers, preview security, and lifecycle links, but there is no complete failure matrix for image pull, crash loop, interruption after push, concurrent update, and state reconstruction after restart.

## A. Canonical Deployment State Model

Do not encode every failure as a top-level product state. Use three orthogonal dimensions and derive one presentation state.

### Persisted truth

Keep `desired_state` narrowly about desired presence:

- `draft`: product record is not yet published.
- `pending`: legacy-compatible value meaning an active workload is desired in Git. It must not be interpreted as an operation still pending.
- `destroyed`: absence is desired and the record is archived.

In a later migration, `pending` may be renamed to `present`, but hardening should not require that breaking change.

Add durable latest-operation metadata, preferably as a small `deployment_operations` record rather than more free text:

- operation id/idempotency key
- deployment id and owner id
- kind: `create`, `update`, `destroy`, `recover`, or `reconcile`
- phase: `requested`, `git_published`, `reconciling`, `completed`, or `failed`
- target commit SHA
- sanitized reason code and message
- requested values/hash
- created/updated/completed timestamps

The operation row is written before Git mutation. Product desired fields still update only after Git publication succeeds. This lets a restart identify an interrupted operation without pretending the desired DB fields changed early.

### Observed dimensions

Reconciliation state remains:

- `synced`: the relevant commit or a newer verified desired state is observed and the app resources agree.
- `progressing`: Argo is processing the relevant revision.
- `drifted`: the relevant desired/runtime resources do not agree.
- `degraded`: Argo has failed for this workload or the workload-specific resource is degraded.
- `unknown`: evidence is incomplete.

Runtime condition should become:

- `ready`
- `progressing`
- `degraded`
- `missing`
- `unreachable`
- `unknown`

Runtime reason is a separate stable code:

- `image_pull_failed` for `ErrImagePull` or `ImagePullBackOff`
- `crash_looping` for `CrashLoopBackOff`
- `container_config_error`
- `pod_failed`
- `rollout_stalled`
- `deployment_missing`
- `service_missing`
- `cluster_unreachable`
- `permission_denied`
- `authentication_failed`
- `evidence_unavailable`

### Derived presentation state

The API should derive a compact state for UI use:

| Presentation state | Required evidence |
| --- | --- |
| `creating` | latest operation is create before Git publication |
| `awaiting_gitops` | operation intent exists and Git publication has not been confirmed |
| `awaiting_reconciliation` | target commit is published but not yet observed by Argo |
| `progressing` | commit is observed and workload rollout is making progress |
| `running` | workload-specific Git/Argo evidence agrees and Deployment, Service, and requested pods are Ready |
| `degraded` | a confirmed workload failure exists; use the separate reason code for image pull/crash loop/etc. |
| `update_pending` | latest operation is update and its target revision/runtime has not converged |
| `update_failed` | update Git publication failed, Argo failed for that revision, or runtime reached a confirmed failure |
| `destroy_pending` | absence is published or requested but active/runtime cleanup is not yet confirmed |
| `destroyed` | record is archived/destroyed and managed runtime resources are stably absent |
| `cluster_unreachable` | Kubernetes evidence cannot be read due to transport/auth/configuration failure |
| `reconciliation_unknown` | Argo evidence is missing or cannot be associated safely with this workload |

`image_pull_failed`, `crash_looping`, and `runtime_failed` should be reason codes under `degraded`, not parallel top-level lifecycle values. GitOps `Synced` means the declared manifests were applied; it never implies Kubernetes workload readiness.

Status precedence should be deterministic: destroyed/destroy-pending, infrastructure reachability, confirmed runtime failure, operation/reconciliation progress, running, then unknown.

## B. Create Failure Hardening

| Scenario | Expected classification | Recovery/action |
| --- | --- | --- |
| Invalid image syntax/value | validation failure before Git | Correct input; no DB/Git/runtime mutation |
| Nonexistent image/tag | `degraded` + `image_pull_failed` after pod evidence | Keep Edit and Destroy available |
| Host-local-only image | same as unavailable registry image | Explain that host Docker and kind node stores differ; Edit to registry image or Destroy |
| Private image without credentials | `degraded` + `image_pull_failed`; do not infer credential details from unsafe messages | Edit to accessible image or Destroy; image-pull secrets remain out of scope |
| Pod Pending while scheduling/pulling | `progressing` within bounded grace period | Continue polling; expose safe Kubernetes reason when known |
| CrashLoopBackOff/exit loop | `degraded` + `crash_looping` | Edit image/ports when relevant or Destroy |
| Container exits terminally | `degraded` + `pod_failed` | Edit or Destroy |
| Rollout never Ready | `progressing`, then `degraded` + `rollout_stalled` only after observed lack of progress and a bounded policy | Never fail solely because browser polling timed out |
| Git commit/push failure | operation `failed`; no product desired-state update | Safe retry using same operation intent |
| Argo delay | `awaiting_reconciliation`/`progressing` | Retry observation; remain actionable |
| Workload cluster unavailable | `cluster_unreachable` | Retry reads; do not mark workload failed |
| Management/Argo unavailable | `reconciliation_unknown` or infrastructure degraded | Runtime may still be shown independently if readable |

Create must not archive or hide the ServiceDefinition because runtime failed. A published failed workload remains an active managed deployment and must be excluded from untracked results by its active DeploymentRecord identity.

For push-succeeded/DB-failed create, the durable operation id and deterministic manifest hash should allow an owner-scoped `resume` path to verify the remote app directory and commit, then create/link product records exactly once. It must not create a second Git commit.

## C. Update Failure Hardening

- A valid deployment updated to a bad image becomes `update_failed` with runtime reason `image_pull_failed` once the target revision is observed. The previous product linkage remains intact.
- The same record remains editable. Updating to a valid registry image creates a new target revision and can return the workload to `running` without kubectl patching.
- Replicas or port updates while unhealthy must use the current Git desired state as the merge base and serialize operations per deployment. The API should reject or supersede an outstanding update explicitly rather than race silently.
- Git push failure must leave product desired fields and commit SHA unchanged; the durable operation records a retryable failure.
- Argo delay or cluster unreachability must remain pending/unknown, not failed.
- Backend restart must reconstruct update progress from operation target revision, current DeploymentRecord, Git/Argo revision, and runtime observations.
- No-change update remains a successful no-op with no commit and no rollout. It may close an operation intent as `completed/no_changes`.
- `service_definition_id`, app name, namespace, and managed manifest path remain immutable in update v1.

The generic DeploymentRecord PATCH route must be narrowed or reject GitOps-owned identity/desired fields. All GitOps-managed workload changes must pass through the dedicated GitOps PATCH endpoint.

## D. Destroy/Delete Hardening

Destroy must remain available from Running, Pending, image-pull failure, crash loop, degraded, update-pending, and reconciliation-unknown states when ownership and managed Git identity are known.

Expected sequence:

1. Persist destroy operation intent.
2. Remove only the app directory/root reference and push the destroy commit.
3. Store the target destroy revision and archive the DeploymentRecord as desired absent.
4. Request scoped normal Argo refresh/sync with prune for the Root Application.
5. Observe the exact revision and successful operation.
6. Confirm Deployment, Service, and pods are absent with a stabilization window.
7. Mark operation completed and archive the ServiceDefinition only when no other active non-destroyed record uses it.

Idempotency rules:

- Missing app directory/root entry is a no-change success, not a new commit.
- Already missing runtime resources are `not_required`, not failure.
- Partially missing Deployment or Service is valid cleanup progress.
- Repeating Destroy for an archived destroyed record retries observation/absence verification only.
- Repeated Destroy never restores manifests or creates resources.
- Argo/workload API outages leave `destroy_pending` and a retryable operation.
- Ownership-label mismatch blocks any direct recovery cleanup and reports a conflict.

Argo automated prune is the normal deletion mechanism. If the existing exact label-verified Kubernetes cleanup remains, define it as a bounded recovery safeguard after exact-revision success, never as the first or unscoped path.

## E. GitOps, DB, and Runtime Consistency

| State | Product interpretation | Safe action |
| --- | --- | --- |
| DB + GitOps + runtime | Managed deployment; classify revision and readiness | Normal Edit/Preview/Destroy |
| DB + GitOps, runtime missing | Progressing during grace; then degraded/runtime-missing after revision evidence | Reconcile, Edit, or Destroy |
| DB exists, GitOps missing, runtime exists | Managed record with desired-state loss, not untracked | Recover/reconcile Git; Destroy remains available |
| DB exists, GitOps/runtime missing | Draft, destroyed, or degraded according to persisted intent | Recover or complete Destroy |
| GitOps exists, DB missing | Discovered unmanaged-by-domain desired state | Do not count as active product; offer future owner-scoped import/repair |
| Runtime exists, DB/GitOps missing | Truly untracked runtime | Read-only display; never adopt/delete automatically |
| DB commit older than Argo revision | Use workload-specific manifest/runtime alignment to decide; newer root revision alone is not failure | `synced` only when expected resources align |
| Git push succeeded, DB persistence failed | Explicit inconsistent/recoverable operation | Resume from durable intent and remote evidence; no duplicate commit |
| DB desired fields updated, reconciliation pending | Active desired state with update/create operation pending | Keep polling; do not claim running until runtime agrees |
| Destroy commit pushed, prune pending | Archived desired-absent record with `destroy_pending` | Retry Argo observation and stable absence |

Existing drift comparison handles many DB/Git/runtime mismatches, but managed-GitHub mode cannot currently read manifests through `GitOpsManifestReader` unless a local repo root is configured. A future reader should inspect the trusted managed repository revision or record a verified manifest digest at publication. Until then, return `unknown`, not false alignment.

Repair must be explicit, owner-scoped, idempotent, and based on trusted server configuration. Never repair product truth by blindly adopting runtime-only resources.

## F. ServiceDefinition Consistency

Required invariant: every active, non-destroyed DeploymentRecord with a service link references an active ServiceDefinition owned by the same user.

Preserve current behavior:

- Create reuses the owner/name ServiceDefinition and reactivates it when archived.
- Update preserves `service_definition_id` and updates only relevant service defaults after Git success.
- Failed runtime or reconciliation does not archive the ServiceDefinition.
- Final destroy archives the ServiceDefinition only when active non-destroyed reference count is zero.
- Recovery reactivates the linked ServiceDefinition.
- Active managed names are excluded from untracked runtime discovery even when pods are unhealthy.

Hardening changes should move read-time repair into an explicit transactional invariant/repair service called by mutation or maintenance paths. Add a database-safe concurrency check around final-reference archival so concurrent create/destroy cannot archive a newly reused service.

## G. Preview Failure Behavior

- Not Ready, Pending, image-pull failure, or crash loop: return the existing safe unavailable response with a stable reason suitable for UI display; do not attempt port-forward.
- Rollout/update: return `not_ready` until the selected Ready pod represents the desired rollout.
- Backend restart: a new short-lived preview session can be issued from persisted ownership and live readiness; no in-memory session registry is required.
- Session expiry: return 401 scoped to preview; frontend can re-run access/session creation once.
- Upstream connection loss/timeout: return sanitized 503/504 without host, pod, token, or response-body leakage.
- Upstream 404 remains an upstream 404 for the requested preview path.

Preserve the current short-lived deployment-scoped preview token, owner checks, response limit, timeout, redirect rejection, path validation, and pod-port-forward RBAC. Never expose the main user JWT or forward `Authorization`, DevDeploy cookies, `X-DevDeploy-*`, proxy-auth, host, or forwarding headers to the workload.

## H. Frontend Operation UX

The UI should consume the canonical derived state and stable reason codes rather than infer operation state from `status_summary` strings.

| UI state | Meaning |
| --- | --- |
| Progressing | Git operation or observed rollout is actively advancing |
| Waiting | Commit/reconciliation/runtime evidence is delayed but no failure is confirmed |
| Degraded | Kubernetes or workload-specific Argo evidence confirms a problem |
| Failed | The requested Git/Argo operation itself failed, or runtime reached a confirmed failure policy |
| Recovered | A previously degraded operation reaches the requested healthy state |
| Completed | Create/update is healthy at target state, or destroy absence is verified |

Rules:

- Browser timeout changes `progressing` to neutral `waiting`, never directly to failed.
- Polling errors preserve the last trustworthy state and show that observation is unavailable.
- Image pull and crash loop show specific safe guidance: Edit image or Destroy.
- Edit and Destroy remain available for failed active records.
- A page reload reconstructs the current operation from the API.
- A timed-out operation can later transition to recovered/completed.
- Pending-delete runtime resources remain hidden from normal untracked lists or are explicitly labeled Deleting.
- Create/update/delete cards use the same canonical backend state mapper.

## I. Idempotency and Retry

| Operation | Current strength | Required hardening |
| --- | --- | --- |
| Create | Duplicate app directory is rejected; scoped commit/push | Add idempotency key and resume push-succeeded/DB-failed create |
| Update | Deterministic rewrite; no-change avoids commit | Serialize per deployment and use expected current commit/manifest hash |
| Destroy | Missing Git state is no-op; archived destroy retries cleanup | Persist operation before push and keep prune/absence verification resumable |
| Reconcile/recover | Deterministic manifests and revision/readiness checks | Surface terminal pod failures instead of generic pending |
| Preview session | Stateless signed, scoped, short-lived | Allow safe reissue; do not reuse across deployment ids |

Concurrent Git operations should use optimistic remote revision checks. A non-fast-forward is retryable only after recloning/re-reading desired state; never force push.

## J. Backend Restart and Process Interruption

On startup or first read, an operation reconciler should inspect durable pending operations without depending on an in-memory task:

- Before Git commit: mark abandoned intent retryable after a bounded age.
- After local commit but before push: managed temporary clone may be gone; verify remote before retrying.
- After push before DB product update: find the operation by id/expected content and finish DB persistence idempotently.
- During Argo wait: resume observation from target commit SHA.
- During destroy: resume exact-revision prune and stable-absence verification.
- During frontend polling: API state remains sufficient for a new browser session.
- During preview: the current request may fail safely; the next access request creates a fresh preview session.

Do not make backend startup block on workload reconciliation. Resume lazily or through a bounded background worker with per-operation leases.

## K. Infrastructure Failure Classification

| Failure | Classification | Blocking scope |
| --- | --- | --- |
| GitHub network unavailable | retryable `git_remote_unavailable` | Blocks new Git mutation only |
| GitHub credentials rejected | blocking `git_authentication_failed` | Blocks Git mutation until configuration is fixed |
| Argo API unavailable | retryable `reconciliation_unknown` | Does not erase known DB/runtime state |
| Workload API unavailable | retryable `cluster_unreachable` | Blocks runtime verification/preview; Git mutation policy may continue only when safe |
| Workload API forbidden | configuration degraded `permission_denied` | Blocks required observation, not reported as network loss |
| Management API unavailable | platform degraded/unreachable | Blocks Argo observation and may block mutations requiring it |
| Management API forbidden | reachable but permission-degraded | Do not classify as unreachable |
| Temporary general network loss | retryable | Preserve last persisted truth and operation intent |

Fatal should be reserved for invalid trusted configuration, unsafe repository shape/path, ownership conflict, or data that cannot be reconciled safely. User workload failure is never a platform-fatal condition.

## L. Local Image Behavior

Current contract:

- An image in the host Docker image store is not automatically present in the kind workload node.
- DevDeploy sends the image reference to GitOps unchanged.
- The workload cluster attempts to resolve/pull it according to Kubernetes image behavior.
- A failure is represented as `degraded` with `image_pull_failed` once observed.
- The user can Edit to a registry-accessible image or Destroy.
- Services, Dashboard, and Deployments continue treating the record as managed and active until Destroy.

A future, separate feature may offer `Load host-local image into local workload cluster`. It would need digest identity, architecture checks, explicit user consent, deterministic kind loading, restart/reconcile semantics, and clear non-portability labeling. It is out of scope for reliability hardening.

## M. Automated Failure Regression Matrix

### Unit tests

- Map `ErrImagePull` and `ImagePullBackOff` to degraded/image-pull reason.
- Map `CrashLoopBackOff`, failed pod phase, and Deployment failure condition separately.
- Keep ordinary Pending/ContainerCreating as progressing during grace.
- Keep API timeout, 401, 403, and malformed response distinct from workload failure.
- Verify workload-specific Argo degradation does not contaminate unrelated deployments.
- Verify full/short SHA matching consistently.
- Verify immutable GitOps identity fields cannot be changed by generic PATCH.
- Verify ServiceDefinition active/archive/reactivation and shared-reference concurrency rules.
- Verify preview unavailable/session/header/RBAC rules.
- Verify timeout is neutral and later recovery can complete.

### Integration tests

- Valid nginx create -> running -> destroy.
- podinfo preview and session reissue.
- replicas update and image update.
- nonexistent image and invalid tag -> image-pull failure.
- simulated host-local-only image -> same clean failure classification.
- CrashLoopBackOff workload.
- failed deployment -> edit to good image -> recovered/running.
- failed deployment -> destroy -> stable absence.
- destroy while reconciliation is pending.
- update during temporary Argo outage and later recovery.
- temporary workload API outage without false workload failure.
- duplicate app name and concurrent update conflict.
- no-change update produces no commit.
- Git push failure leaves product desired fields unchanged.
- push success/DB failure resumes without duplicate record or commit.
- backend restart reconstructs pending create/update/destroy.
- stale DB/Git/runtime matrix cases use the expected repair action.

Use fake Kubernetes/Argo/Git adapters and repository fixtures for deterministic CI. Assert call order and persisted state, not sleeps.

### Live smoke and chaos tests

- nginx create/update/destroy cleanup.
- persistent podinfo Ready/preview baseline.
- real invalid registry image -> visible image-pull failure -> edit to nginx/podinfo -> recovery.
- real crash-loop image/command only in an isolated test fixture designed for that purpose.
- pause network/API access briefly, verify neutral degraded observation, then restore.
- restart backend after Git publication and verify operation reconstruction.
- destroy a failed workload and confirm Root Application Synced/Healthy and no residual app resources.

Live chaos tests remain manual or scheduled opt-in jobs. Normal pull-request CI must not depend on GitHub availability, a live cluster, registry timing, or Docker Desktop.

## N. Implementation Phases

### Phase 1: Canonical runtime and failure classification

Goal: expose existing pod/Deployment evidence without multiplying lifecycle states.

Likely modules:

- `backend/app/services/gitops/kubernetes_status_reader.py`
- `backend/app/services/product_runtime_status.py`
- `backend/app/services/gitops/status_reader.py`
- runtime/reconcile schemas and focused tests

Work: add stable runtime condition/reason fields, preserve current fields for compatibility, distinguish infrastructure read failures, and make SHA matching consistent.

Risk: medium; status changes affect dashboard, deployment lists, and access checks.

Tests/live validation: unit matrices for waiting reasons and API failures; live invalid-image and crash-loop classification without changing lifecycle behavior.

### Phase 2: Workload-specific reconciliation and immutable API boundaries

Goal: prevent one Root Application failure from degrading every app and close non-GitOps mutation paths.

Likely modules:

- `backend/app/services/deployment_reconcile_status.py`
- `backend/app/api/v1/endpoints/deployment_records.py`
- `backend/app/schemas/deployment_record.py`
- drift/reconcile/product API tests

Work: evaluate per-resource Argo evidence where available, represent global Argo degradation separately, and reject identity/desired-state edits outside the GitOps endpoint.

Risk: medium-high because existing clients may use generic PATCH fields.

Tests/live validation: two workloads with one failed; healthy workload remains healthy; app name, namespace, commit, path, and linkage remain immutable.

### Phase 3: Durable operation intent, idempotency, and interruption recovery

Goal: make create/update/destroy reconstructable across DB errors, backend restart, and page reload.

Likely modules:

- Deployment operation model/repository/service and migration
- GitOps create/update/destroy endpoints
- Git adapter commit metadata/idempotency handling
- ServiceDefinition invariant service

Work: persist operation intent before Git mutation, serialize per deployment/app, store target revision, resume incomplete operations, and move hidden ServiceDefinition repair writes out of list paths.

Risk: high; this crosses database and Git transaction boundaries.

Tests/live validation: interruption at every boundary, push-success/DB-failure recovery, concurrent operations, no duplicate commits/records, restart/resume.

### Phase 4: Create/update/destroy recovery semantics

Goal: apply the canonical model to all lifecycle actions and make failed workloads normally editable/destroyable.

Likely modules:

- create/update/destroy/recovery orchestration services
- destroy runtime cleanup policy
- dashboard classification
- access/preview failure mapping

Work: bounded reconciliation grace, terminal runtime failure rules, Argo-prune-first destroy semantics, explicit fallback cleanup policy, and operation-based dashboard counts.

Risk: high for destroy; low-to-medium for create/update classification.

Tests/live validation: full consistency matrix, failed create -> edit recovery, destroy from each runtime state, Argo/workload outages, stable absence.

### Phase 5: Frontend degraded/failure/recovery UX

Goal: render durable backend state consistently after timeout, reload, and recovery.

Likely modules:

- `frontend/src/features/deployments/DeploymentsPage.tsx`
- GitOps progress/status components
- frontend types, translations, and tests

Work: query operation state, show specific safe reasons, keep Edit/Destroy actionable, preserve last trustworthy evidence, and reconstruct progress after reload.

Risk: medium; avoid regressions in the proven progress lifecycle.

Tests/live validation: create/update/destroy delays, polling failures, reload, backend restart, timeout then recovery, image-pull guidance.

### Phase 6: Automated regression and opt-in chaos suite

Goal: make the failure matrix repeatable without making CI flaky.

Likely modules:

- backend unit/integration fixtures
- frontend state tests
- opt-in live smoke scripts/documentation

Work: deterministic fake adapter tests in CI and a separately invoked local kind chaos checklist.

Risk: low to product behavior; medium maintenance cost.

Tests/live validation: all matrix entries above, with podinfo left as the documented persistent smoke app and temporary test workloads always removed.

## Highest-Risk Scenarios

1. Git push succeeds and create product persistence fails, leaving Git/runtime desired state without an owning DeploymentRecord.
2. Generic record PATCH changes immutable identity outside GitOps.
3. A single bad image degrades the Root Application and causes unrelated deployments to be reported degraded.
4. Backend restart loses operation progress at an uncertain Git/DB boundary.
5. Concurrent updates race and leave the losing user without a structured retry path.
6. Destroy is interrupted after Git publication but before DB archival or stable absence verification.
7. Runtime API failure is mistaken for workload failure, or workload failure is hidden as generic unknown.

## Acceptance Baseline

Hardening is complete when an invalid workload can remain visible as an active managed record, explain its safe failure reason, be edited to a good image or destroyed, survive backend/browser restarts, and leave DB, GitOps, ServiceDefinition, Argo, and runtime state reconcilable without manual kubectl mutation.

The persistent baseline remains:

- podinfo may remain running for preview smoke validation.
- nginx and failure-test workloads are temporary and must be removed after live tests.
- Root Application should return Synced/Healthy after cleanup.
- No reliability phase broadens RBAC, changes the GitOps repository structure, implements Setup Wizard/launcher packaging, or adds out-of-scope workload features.
