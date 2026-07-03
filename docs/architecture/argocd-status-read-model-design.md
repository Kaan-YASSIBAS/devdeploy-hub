# Argo CD Status Read Model Design

## 1. Purpose

This document defines how DevDeploy Hub should correlate a Git commit published by the GitOps deploy API with:

- Reconciliation of `argocd/devdeploy-workloads-root` in `devdeploy-mgmt`.
- Readiness of the corresponding workload resources in `devdeploy-workload/devdeploy-apps`.

The current deploy endpoint returns `pushed_waiting_for_argocd` after a successful Git push. The status read model adds observation only. It does not become a second deployment path and does not change the rule that Argo CD is the normal workload applier.

This design builds on:

- [Backend GitOps Commit Flow Design](./backend-gitops-commit-flow-design.md)
- [GitOps Workload Manifest Design](./gitops-workload-manifest-design.md)
- [Workload Observability and Status Model](./workload-observability-status-model.md)
- [Security Boundaries and Credentials Model](./security-credentials-boundaries.md)

## 2. Scope

In scope:

- A read-only application deployment status model.
- Correlation of a requested commit SHA with the Root Application revision.
- Root Application sync, health, conditions, and bounded operation-state reads.
- Label-scoped Deployment, Service, and Pod status reads.
- Stable status transitions and error codes.
- Pending and timeout behavior.
- A safe future API response contract.
- Sanitization and least-privilege access requirements.

Out of scope:

- Argo CD force sync or refresh mutation.
- Kubernetes resource mutation.
- Direct `kubectl apply`, `patch`, `delete`, `create`, or `replace` operations.
- Direct backend deployment.
- Per-app Argo CD Application implementation.
- Frontend implementation.
- Delete or prune behavior.
- Ingress generation or reachability.
- CI or image build behavior.

## 3. Status Problem

`POST /api/v1/gitops/apps` currently confirms only that:

1. Workload manifests were written.
2. The expected files were committed.
3. The commit was pushed to the configured remote branch.

Its success status, `pushed_waiting_for_argocd`, does not prove that:

- Argo CD has observed the commit.
- The Root Application is synced.
- Kubernetes accepted the desired resources.
- The Deployment rollout completed.
- The Service exists.
- The required Pods are running and ready.

A separate read model is therefore required. Repository publication and deployment observation must remain distinct states.

## 4. Correlation Inputs

The status reader requires only server-controlled context plus safe request identifiers:

| Input | Value or rule |
| --- | --- |
| App name | Validated DNS-style app name |
| Workload namespace | `devdeploy-apps` |
| Expected commit | `commit_sha` returned by the deploy API |
| Root Application | `devdeploy-workloads-root` |
| Root Application namespace | `argocd` |
| Management cluster | `devdeploy-mgmt` |
| Workload cluster | `devdeploy-workload` |

Workload resources must carry all established labels:

```text
app.kubernetes.io/name=<app-name>
app.kubernetes.io/managed-by=devdeploy
app.kubernetes.io/part-of=devdeploy-workloads
```

The reader should query by both namespace and labels, then verify expected resource names. A label match alone is not sufficient if multiple resources create ambiguity.

The API must validate `commit_sha` as a full hexadecimal Git object ID. A SHA must never be compared lexicographically to decide whether one revision is newer.

## 5. Root Application Read Model

The management-cluster reader should retrieve only `argocd/devdeploy-workloads-root` and project these fields:

- `metadata.name`
- `metadata.namespace`
- `spec.source.repoURL`, sanitized before output
- `spec.source.path`
- `spec.source.targetRevision`
- `status.sync.status`
- `status.sync.revision`
- `status.health.status`
- `status.conditions`, with bounded and sanitized messages
- `status.operationState.phase`, timestamps, and revision when present

Raw operation messages, repository credentials, credential-bearing URLs, manifests, diffs, and parameter values must not be returned.

### Commit observation

The pushed commit is observed when either:

1. `status.sync.revision` exactly equals `commit_sha`; or
2. The observed revision is a later commit and a read-only ancestry check against the controlled Git repository confirms that `commit_sha` is its ancestor.

The second rule prevents a rapidly advancing `main` branch from leaving an already-applied commit permanently marked pending. If ancestry cannot be checked safely, `observed_commit_match` should be `null` and the result should remain pending or unknown. A different SHA is not, by itself, proof that the observed revision is older.

### Root status interpretation

| Condition | Interpretation |
| --- | --- |
| Application missing | `unknown` with `argocd_application_missing` |
| Expected commit not yet observed | `pushed_waiting_for_argocd` with `argocd_revision_pending` |
| Expected commit observed, sync not yet `Synced` | `argocd_observing` |
| Sync is `OutOfSync` | `argocd_observing` with `argocd_out_of_sync` unless a failure condition exists |
| Expected commit observed and sync is `Synced` | `argocd_synced`, then evaluate workload resources |
| Health is `Degraded` or a failure condition is present | `degraded` with `argocd_degraded` |

No status read may trigger a refresh, sync, retry, rollback, or other mutation.

## 6. Workload Resource Read Model

Workload reads target only `devdeploy-workload/devdeploy-apps` and the requested app labels.

### Deployment

Read:

- Existence and expected name.
- `spec.replicas` as desired replicas.
- `metadata.generation`.
- `status.observedGeneration`.
- `status.readyReplicas`.
- `status.availableReplicas`.
- `status.updatedReplicas`.
- Conditions, reduced to type, status, reason, and a sanitized bounded message.

`deployment_ready` is true when:

- The Deployment exists unambiguously.
- Desired replicas are greater than zero.
- `observedGeneration >= generation`.
- Available and ready replicas are at least desired replicas.
- Updated replicas are at least desired replicas.
- No `ProgressDeadlineExceeded` or active `ReplicaFailure` condition exists.

### Service

Read:

- Existence and expected name.
- `spec.type`.
- `spec.clusterIP` presence, without treating the address as a public URL.
- Port name, port, target port, and protocol.

`service_ready` is true when the expected `ClusterIP` Service exists and its `http` port matches the generated workload contract. The expected port should come from trusted GitOps operation metadata or the controlled manifest, not from an arbitrary status-query override.

### Pods

Read Pods by all managed labels and summarize:

- Total Pod count.
- Running Pod count.
- Ready Pod count based on the Pod `Ready` condition.
- Restart count summed from container statuses.
- Waiting reasons from an allowlisted or sanitized bounded set.
- Latest phase summaries and relevant condition reasons.

`pods_ready` is true when at least the desired replica count is both `Running` and Ready. Known failure reasons such as `CrashLoopBackOff`, `ImagePullBackOff`, `ErrImagePull`, and `CreateContainerConfigError` should produce a degraded signal rather than an indefinite progressing state.

### Aggregate workload status

`workload_ready` is true only when `deployment_ready`, `service_ready`, and `pods_ready` are all true.

The reader must not retrieve Secret data, Pod environment values, mounted credential content, or full logs. Events may be added later as a separate bounded troubleshooting signal.

## 7. High-Level Status States

The future status endpoint should expose one of these stable states:

| Status | Meaning |
| --- | --- |
| `pushed_waiting_for_argocd` | Commit was pushed but is not yet confirmed in the observed Root Application revision |
| `argocd_observing` | Argo CD observed the commit but reconciliation is not yet synced |
| `argocd_synced` | Root Application is synced to a revision containing the commit; workload evaluation is not complete |
| `workload_progressing` | Root Application is synced and healthy enough to continue, but workload resources are not ready |
| `deployed` | Root Application contains the commit and is synced/healthy, and all required workload resources are ready |
| `degraded` | Argo CD or app-scoped workload signals show a confirmed failure |
| `unknown` | Required data is missing, ambiguous, unavailable, or cannot be read safely |

Recommended transition sequence:

```text
pushed_waiting_for_argocd
  -> argocd_observing
  -> argocd_synced
  -> workload_progressing
  -> deployed
```

Any observed failure may transition to `degraded`. Reader unavailability, permission denial, ambiguous labels, or unresolvable revision correlation should return `unknown` with a stable error code.

Missing workload resources immediately after Argo CD observes the commit are `workload_progressing`, not automatically degraded. They become degraded only when an Argo CD failure, rollout failure, or configured observation timeout provides evidence of failure.

## 8. Future API Response Model

Proposed endpoint:

```text
GET /api/v1/gitops/apps/{app_name}/status?commit_sha=<sha>
```

It must require existing backend authentication. `app_name` and `commit_sha` must be validated, and all cluster/repository configuration must remain server-controlled.

Example response shape:

```json
{
  "status": "workload_progressing",
  "app_name": "api-smoke-nginx",
  "namespace": "devdeploy-apps",
  "commit_sha": "<COMMIT_SHA>",
  "observed_revision": "<OBSERVED_REVISION>",
  "root_application": {
    "name": "devdeploy-workloads-root",
    "sync_status": "Synced",
    "health_status": "Healthy",
    "observed_commit_match": true
  },
  "workload": {
    "deployment_ready": true,
    "service_ready": true,
    "pods_ready": false,
    "desired_replicas": 1,
    "ready_replicas": 0,
    "available_replicas": 0,
    "pod_count": 1,
    "ready_pod_count": 0
  },
  "message": "Argo CD has synchronized the commit; workload readiness is pending.",
  "error_code": null
}
```

The response must not include:

- Git, Argo CD, or Kubernetes tokens.
- Kubeconfig content or paths supplied by a caller.
- Certificates or private keys.
- Kubernetes Secret values.
- Full Pod logs or environment variables.
- Raw unsanitized Argo CD condition or operation messages.
- Credential-bearing repository URLs.

## 9. Polling Model

The status endpoint should be read-only, idempotent, and short-lived.

- The frontend may poll every 2-5 seconds after receiving `pushed_waiting_for_argocd`.
- The backend should perform one bounded read pass per request.
- V1 should not hold a long-running HTTP request while waiting for reconciliation.
- Reads must use explicit client timeouts.
- Concurrent requests must not mutate shared status state.
- Server-side background workers and persisted status history are future options.

An observation timeout does not authorize mutation. A configurable warning threshold may retain a pending state with `argocd_revision_pending`; a longer threshold may return `unknown` with a safe timeout message. The user may retry the read. The backend must not respond by forcing synchronization or changing workloads.

## 10. Kubernetes Access Model

The browser must never supply a kubeconfig, ServiceAccount token, Argo CD token, API server address, namespace, or cluster context for this endpoint.

Possible read implementations:

### A. Management in-cluster identity

The backend in `devdeploy-mgmt` uses its ServiceAccount to read the Root Application in `argocd`. This is the preferred management-cluster path.

### B. Dedicated workload status identity

The backend uses a server-controlled, read-only identity to query `devdeploy-workload/devdeploy-apps`. The credential may be represented by a protected cluster connection or kubeconfig managed outside API input. It should be distinct from the Argo CD deploy credential because the backend does not need workload write privileges.

### C. Argo CD API

A future implementation may read selected state through the Argo CD API. Argo CD credentials must remain server-side and must not be exposed in frontend requests or responses.

V1 recommendation:

- Introduce a backend status-reader abstraction with separate management and workload clients.
- Use the in-cluster backend identity for namespaced Root Application reads.
- Use a dedicated least-privilege workload reader for `devdeploy-apps`.
- Keep all endpoints and credentials in server configuration.
- Fail closed with `permission_denied` or `status_reader_unavailable` when access is missing.

## 11. RBAC Model

Required management-cluster permission in namespace `argocd`:

The namespaced resource identifier is `applications.argoproj.io`.

| API group | Resource | Verbs |
| --- | --- | --- |
| `argoproj.io` | `applications` | `get`, `list`, `watch` |

Required workload-cluster permissions in namespace `devdeploy-apps`:

| API group | Resource | Verbs |
| --- | --- | --- |
| `apps` | `deployments` | `get`, `list`, `watch` |
| Core (`""`) | `services` | `get`, `list`, `watch` |
| Core (`""`) | `pods` | `get`, `list`, `watch` |
| Core (`""`), optional later | `events` | `get`, `list`, `watch` |

The backend status reader must not receive:

- `create`, `update`, `patch`, or `delete` verbs.
- Role or RoleBinding management.
- ClusterRole or ClusterRoleBinding management.
- Namespace management.
- Cluster-admin.
- Workload access outside the managed namespace.
- Secret data read permission.

The existing Argo CD workload deployment identity remains separate. Its ability to reconcile workloads must not be inherited by the backend status reader.

## 12. Failure And Error Handling

Stable error codes:

| Error code | Meaning |
| --- | --- |
| `argocd_application_missing` | Expected Root Application was not found |
| `argocd_revision_pending` | Root Application has not yet been confirmed at a revision containing the commit |
| `argocd_out_of_sync` | Root Application reports `OutOfSync` |
| `argocd_degraded` | Root Application reports degraded health or a failure condition |
| `workload_deployment_missing` | Expected Deployment is absent after the allowed progressing window |
| `workload_service_missing` | Expected Service is absent after the allowed progressing window |
| `workload_pods_not_ready` | Required Pods exist but are not ready |
| `workload_pod_crashloop` | A selected Pod reports a known crash or image/configuration failure reason |
| `status_reader_unavailable` | A configured cluster/API endpoint cannot be reached within timeout |
| `permission_denied` | The backend reader lacks required read permission |
| `unknown` | Data is ambiguous or cannot be classified safely |

Error responses must:

- Preserve stable codes while using concise safe messages.
- Avoid raw exception text and stack traces.
- Sanitize URLs, condition messages, waiting reasons, and operation-state details.
- Apply length limits to all upstream messages.
- Avoid logging request authorization headers or credential objects.
- Distinguish unavailable readers from unhealthy workloads.

## 13. Security Boundaries

- Status collection is read-only.
- The reader never forces Argo CD synchronization.
- The backend never applies or directly deploys workload resources.
- API callers cannot provide kubeconfigs or cluster credentials.
- Secret values and Pod environment values are never read.
- Full logs are not included in status responses.
- No cluster-admin or cluster-wide write access is granted.
- Separate least-privilege identities are used for management and workload reads.
- Repository URLs and upstream messages are sanitized before output.
- App names, commit SHAs, namespaces, and label selectors are validated before use.
- Timeouts and failures produce status only; they never trigger mutation.

## 14. Relationship To Per-App Argo CD Applications

The current Root Application represents the entire `gitops/workloads/devdeploy-apps` tree. Its sync and health fields are aggregate signals, so a degraded Root Application may be caused by a different app.

V1 should therefore:

- Correlate the pushed commit with the Root Application revision.
- Require stable per-app labels on every generated workload resource.
- Use label-scoped Kubernetes reads for app-specific readiness.
- Describe Root Application health as a shared GitOps-tree signal.
- Return `unknown` when labels are missing or multiple resources are ambiguous.

A future App of Apps model may create one Argo CD Application per workload. That would provide cleaner per-app sync, health, history, rollback, and lifecycle correlation. The V1 Root Application plus label-based workload read model must remain compatible with that migration, but it does not require per-app Applications now.

## 15. V1 Implementation Handoff

Phase 2J.5g defines the read model only. It adds no endpoint, client, RBAC resource, frontend behavior, or cluster mutation.

Phase 2J.5h implements the typed snapshots, injectable reader boundary, pure exact-SHA evaluator, safe error mapping, and authenticated `GET /api/v1/gitops/apps/{app_name}/status` endpoint. Tests use fake snapshots only. The default reader returns `status_reader_unavailable`, so this phase adds no live Kubernetes client, Argo CD API client, credential, RBAC resource, or cluster access.

Phase 2J.5i should implement the separate read-only management and workload readers, least-privilege runtime configuration, and live-cluster verification. Controlled Git ancestry support may also be added there; Phase 2J.5h intentionally supports exact SHA matching only.

Frontend polling should begin only after the live readers and least-privilege access model are implemented and verified.
