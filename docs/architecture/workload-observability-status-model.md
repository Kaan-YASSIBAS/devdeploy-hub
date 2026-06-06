# Workload Observability and Status Model

## 1. Overview

This document defines how DevDeploy Hub observes and displays health, sync, logs, metrics, and status for management and workload clusters in the local-first multi-cluster architecture.

The higher-level architecture is defined in:

- [Multi-Cluster Redesign](./multi-cluster-redesign.md)
- [Bootstrapper / Launcher Design](./bootstrapper-launcher-design.md)
- [Setup Wizard Multi-Cluster Lifecycle Design](./setup-wizard-multi-cluster-lifecycle.md)
- [GitOps Repository Layout and Argo CD Application Model](./gitops-repository-argocd-model.md)
- [Localhost Networking and Port Strategy](./localhost-networking-port-strategy.md)

In the target architecture:

- DevDeploy platform components run in the management cluster: `devdeploy-mgmt`.
- User applications run only in the workload cluster: `devdeploy-workload`.
- Argo CD runs in `devdeploy-mgmt` and deploys user workloads to `devdeploy-workload`.
- Management UI is exposed at `http://devdeploy.localhost:8080`.
- Workload apps are exposed at `http://<app-name>.localhost:8081`.

Normal workload deployment remains GitOps-only:

```text
UI -> Backend -> GitHub/GitOps Repository -> Argo CD -> Workload Kubernetes Cluster
```

The backend may read Kubernetes and Argo CD state for observability when credentials are scoped appropriately. It must not mutate normal user workload resources as part of status collection.

## 2. Design Goals

- Distinguish management cluster health from workload cluster health.
- Combine database, GitOps, Argo CD, Kubernetes, logs, metrics, and URL reachability into useful user-facing status.
- Keep V1 simple with one parent Argo CD Application named `devdeploy-workloads`.
- Supplement limited parent Application status with Kubernetes resource queries filtered by DevDeploy labels.
- Keep backend workload access read-only.
- Keep logs, metrics, and status safe by avoiding secret exposure.
- Preserve compatibility with future App of Apps observability.
- Use the same status model for demo apps and normal user apps.

## 3. Non-Goals

- This document does not implement runtime code.
- This document does not change backend, frontend, Kubernetes manifests, or workflows.
- This document does not require full Prometheus or Loki federation in V1.
- This document does not add Kubernetes write permissions.
- This document does not allow backend direct deployment or deletion of normal workloads.
- This document does not make GitHub Actions deploy directly to clusters.
- This document does not require full per-app Argo CD Applications in V1.

## 4. Observability Scope

DevDeploy Hub should observe two different surfaces.

Management cluster observability:

- DevDeploy platform health.
- Argo CD health.
- PostgreSQL health.
- Management ingress health.
- Platform namespace and component readiness.

Workload cluster observability:

- Workload Kubernetes API reachability.
- Workload ingress readiness.
- Generated workload namespace health.
- User app Deployments, Pods, Services, and Ingress resources.
- User app logs.
- Basic user app metrics when available.
- App URL reachability where safe and practical.

The UI should avoid mixing these into one ambiguous cluster health result. Management health answers "is DevDeploy Hub running?" Workload health answers "can user apps run and be reached?"

## 5. Management Cluster Status Model

Management cluster health should include:

- Kubernetes API reachability for `devdeploy-mgmt`.
- DevDeploy frontend availability.
- DevDeploy backend availability.
- PostgreSQL readiness.
- Argo CD availability.
- Management ingress readiness.
- Required platform namespaces.
- Required platform components.

Recommended management status values:

- `healthy`: Required platform components are available.
- `degraded`: Platform is partially available but one or more non-critical checks are failing.
- `unavailable`: Required platform checks fail.
- `unknown`: Status cannot be determined safely.

Management status should not include user app health.

## 6. Workload Cluster Status Model

Workload cluster health should include:

- Kubernetes API reachability for `devdeploy-workload`.
- Workload ingress controller readiness.
- Generated workload namespace existence.
- User app Deployments.
- User app Pods.
- User app Services.
- User app Ingress resources.
- Optional URL reachability checks.

Recommended workload status values:

- `healthy`: Workload cluster is reachable and required workload infrastructure is ready.
- `degraded`: Cluster is reachable but one or more workload infrastructure checks are failing.
- `unavailable`: Cluster API or required workload infrastructure is unavailable.
- `unknown`: Status cannot be determined safely.

Workload status should not imply the DevDeploy management platform is healthy.

## 7. Application Status Sources

Application status should combine several sources:

- DevDeploy database deployment record.
- GitOps deployment request status.
- Argo CD sync and health status.
- Kubernetes Deployment readiness.
- Pod readiness and restart counts.
- Service existence.
- Ingress existence.
- Optional URL reachability.
- Logs availability.
- Basic metrics availability.

No single source should be treated as the complete truth.

Example:

- A GitOps request may be `workflow_triggered`.
- Argo CD may still be `syncing`.
- Kubernetes Deployment may not yet have ready replicas.
- The URL may not be reachable until ingress and pods are ready.

The UI should show these as related signals rather than flattening them into a misleading success state too early.

## 8. Argo CD Status Mapping

In V1, Argo CD uses a single parent Application:

```text
devdeploy-workloads
```

This Application tracks:

```text
infra/kubernetes/generated/workloads
```

Because V1 uses one parent Application, per-app Argo CD status may be limited.

Recommended V1 behavior:

- Use parent Application sync status to show whether generated workload Git state is being applied.
- Use parent Application health as a workload tree health signal.
- Use Kubernetes resource queries to derive per-app status.
- Avoid claiming precise per-app Argo CD sync status when only parent status is available.

Possible status mapping:

| Argo CD Signal | UI Meaning |
| --- | --- |
| Parent Application synced and healthy | Workload GitOps tree is applied and generally healthy |
| Parent Application out of sync | GitOps updates are pending sync |
| Parent Application progressing | Argo CD is applying workload changes |
| Parent Application degraded | One or more workload resources are unhealthy |
| Parent Application missing/unreachable | GitOps status unavailable |

Future App of Apps can improve this with one Application per user app.

## 9. Kubernetes Resource Status Mapping

V1 should supplement parent Argo CD status with read-only Kubernetes queries filtered by DevDeploy labels:

```text
app.kubernetes.io/managed-by=devdeploy-hub
devdeploy.io/application=<app-name>
```

Relevant resources:

- Deployment
- ReplicaSet, if needed for rollout details
- Pod
- Service
- Ingress
- Events, if read access is available and safe

Recommended app-level mapping:

- `Pending`: GitOps request exists but Kubernetes resources are not visible yet.
- `GitOps Updating`: Repository update or workflow is in progress.
- `Syncing`: Argo CD is applying changes or resources are not fully reconciled.
- `Healthy`: Deployment desired replicas are available, pods are ready, and required Service/Ingress resources exist.
- `Degraded`: Resources exist but readiness, rollout, pod health, or ingress checks fail.
- `Unavailable`: Required resources are missing or cluster access is unavailable.
- `Unknown`: Status cannot be determined safely.
- `Deleting`: Delete request has been made and GitOps prune is expected.

Deployment readiness should consider:

- Desired replicas.
- Available replicas.
- Updated replicas.
- Progressing conditions.
- ProgressDeadlineExceeded conditions.

Pod readiness should consider:

- Pod phase.
- Ready container count.
- Restart count.
- Waiting or terminated container reasons.

## 10. Logs Model

User app logs should come from workload cluster pods.

V1 log model:

- Logs page reads workload app logs filtered by namespace, app label, pod, and container where possible.
- Demo app logs use the same model as normal apps.
- Management cluster logs are separate from workload app logs.
- Management logs should be clearly labeled as platform logs.

If Loki is present in `devdeploy-mgmt`, workload logs may be forwarded later. V1 should not require full Loki federation before app status is useful.

Log safety rules:

- Do not expose Kubernetes secrets.
- Do not print credentials in backend logs.
- Avoid returning raw stack traces in UI-facing errors.
- Apply reasonable limits to log queries.
- Show unavailable state when logs cannot be loaded.

## 11. Metrics Model

V1 metrics may remain basic.

Recommended baseline metrics:

- Pod CPU usage, if available.
- Pod memory usage, if available.
- Restart count.
- Desired replicas.
- Ready replicas.
- Available replicas.
- Basic request rate, if the app exposes metrics.
- Basic error rate, if the app exposes metrics.
- Optional URL health check results.

If Prometheus is present in `devdeploy-mgmt`, workload data may be scraped, remote-written, or forwarded later. V1 should not require a complete multi-cluster metrics federation design before showing Deployment and Pod readiness.

Metric availability should be explicit:

- Show real values when available.
- Show empty or unavailable states when metrics are missing.
- Do not generate fake metrics.
- Do not mark an app unhealthy only because optional metrics are unavailable.

## 12. URL and Ingress Reachability Status

Generated workload app URLs should follow the workload ingress pattern:

```text
http://<app-name>.localhost:8081
```

URL reachability can be useful, but it should not be the only source of health.

Recommended URL status values:

- `reachable`: HTTP check succeeds.
- `not_reachable`: URL check fails.
- `not_configured`: Ingress or expose option is disabled.
- `unknown`: Check cannot be performed safely.

URL status should be interpreted with Kubernetes status:

- Deployment healthy + URL not reachable may indicate ingress or DNS issue.
- URL reachable + Deployment degraded may indicate stale routing or partial availability.
- No Ingress should not be an error for internal-only workloads.

The backend should avoid sending sensitive headers or credentials during URL checks.

## 13. UI Status Model

The UI should display status in layers:

1. Management cluster health.
2. Workload cluster health.
3. GitOps/Argo CD status.
4. Per-app Kubernetes readiness.
5. Logs and metrics availability.
6. URL reachability.

Recommended user-facing app statuses:

- `Pending`
- `GitOps Updating`
- `Syncing`
- `Healthy`
- `Degraded`
- `Unavailable`
- `Unknown`
- `Deleting`

The UI should show the reason behind a status when available.

Examples:

- "Waiting for Argo CD sync."
- "Deployment has 0/1 available replicas."
- "Pod restart count increased."
- "Ingress exists, but URL is not reachable."
- "Workload cluster is unavailable."
- "Metrics are not configured for this app."

Status copy should avoid implying direct backend deployment.

## 14. Backend Read-Only Access Boundaries

The backend may read:

- DevDeploy database records.
- GitOps request records.
- Argo CD Application status.
- Kubernetes workload resources.
- Kubernetes management resources needed for platform status.
- Logs and metrics from configured observability systems.

The backend must not:

- Directly apply normal user workload manifests.
- Directly delete normal user workload resources.
- Patch, scale, restart, or mutate normal user workload resources as part of status collection.
- Expose tokens, kubeconfigs, database passwords, or secret values.

Kubernetes permissions should be scoped to read-only verbs where possible:

- `get`
- `list`
- `watch`

Write permissions for normal workload lifecycle remain outside the backend and belong to GitOps/Argo CD flow.

## 15. Error and Degraded States

The status model should degrade gracefully.

Examples:

- If Argo CD is unavailable, show GitOps status as unavailable but still show database request state.
- If workload Kubernetes API is unavailable, show GitOps request and Argo CD parent status where available.
- If metrics are unavailable, show readiness and logs where available.
- If logs are unavailable, do not hide Deployment readiness.
- If URL checks fail, show whether Kubernetes resources are otherwise healthy.

The backend should avoid returning HTTP 500 for partial observability failures. It should return structured status where possible and reserve 500 for critical unexpected failures.

Error messages must be safe:

- No secrets.
- No raw tokens.
- No kubeconfig content.
- No full internal query strings when they may include sensitive selectors.

## 16. V1 Implementation Recommendation

V1 should use a practical layered model:

1. Keep one parent Argo CD Application named `devdeploy-workloads`.
2. Read parent Application sync and health status.
3. Read workload Kubernetes resources using DevDeploy labels.
4. Merge database deployment records, GitOps request status, Argo CD parent status, and Kubernetes readiness.
5. Show per-app status derived primarily from Kubernetes resources in `devdeploy-workload`.
6. Keep logs and metrics optional but visible when configured.
7. Use URL reachability as a helpful signal, not the only health source.
8. Keep management and workload cluster health separate in the UI.
9. Use the same model for demo app and normal app status.
10. Keep backend Kubernetes access read-only.

This gives useful application status before full App of Apps observability exists.

## 17. Future App of Apps Observability

Future App of Apps can improve per-app observability.

In that model:

- Each user app has its own Argo CD Application.
- The UI can map app status directly to that Application.
- Per-app sync history is clearer.
- Per-app health status is clearer.
- Per-app rollback and lifecycle history become easier.
- Delete flow can prune a single app Application cleanly.

Future per-app Application manifests may live under:

```text
infra/argocd/applications/workloads/apps/<app-name>-application.yaml
```

The V1 label-based Kubernetes status model should still remain useful as a fallback and validation layer.

## 18. Future Enhancements

Future enhancements may include:

- Prometheus federation or remote write for workload cluster metrics.
- Loki or Alloy forwarding from workload cluster pods.
- Per-app Argo CD Applications.
- Per-app sync and rollback history.
- Kubernetes Events integration.
- Ingress reachability diagnostics.
- Synthetic URL checks.
- Deployment event timeline generated from GitOps, Argo CD, and Kubernetes events.
- More detailed pod/container failure reasons.
- Per-app SLO or availability views.
- Alerting from logs and metrics.

These enhancements should preserve the core boundary: normal user workloads are declared in Git, applied by Argo CD, and observed through read-only status paths.
