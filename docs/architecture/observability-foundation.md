# Observability Foundation

This document defines the Phase 2J.27a observability foundation for the local-first, multi-cluster DevDeploy Hub architecture.

## Context

DevDeploy Hub uses two local kind clusters:

- `devdeploy-mgmt`: platform components, including frontend, backend, PostgreSQL, Argo CD, and optional observability frontends.
- `devdeploy-workload`: user workloads in `devdeploy-apps`.

The product source-of-truth model remains:

- PostgreSQL/domain records are product truth.
- The GitOps repository is desired state.
- Kubernetes and Argo CD are runtime truth.
- The frontend communicates only with authenticated DevDeploy backend APIs.

The frontend must not call Kubernetes, Prometheus, Loki, Grafana, Argo CD, or Git repositories directly.

## Historical Implementation

The repository still contains the original local observability stack under `infra/terraform/local`:

- `kube-prometheus-stack` in namespace `monitoring`
- Prometheus
- Grafana
- kube-state-metrics
- node-exporter
- Loki
- Grafana Alloy for Kubernetes log collection
- Grafana datasource provisioning for Loki

The older docs in `infra/monitoring/README.md` and `infra/logging/README.md` describe a single-cluster local setup and port-forward based access. Those docs remain useful as historical implementation evidence, but they are not the final multi-cluster product model.

## Current Repository State

The backend already has authenticated observability routes under `/api/v1/observability`:

- Kubernetes inventory and summaries
- Prometheus metric summary and time-series queries
- Loki log query endpoints
- Observability health checks

The frontend already has Monitoring and Logs pages that call the backend API. Settings already has integration health cards.

The Phase 2J.27a foundation keeps those surfaces, but hardens health reporting and clarifies configured, connected, unavailable, degraded, and optional states.

## Selected Component Placement

The selected V1 direction is workload-local collection with backend-mediated read APIs:

- Prometheus: workload cluster, namespace `monitoring`
- Loki: workload cluster, namespace `monitoring`
- Log collector: workload cluster, namespace `monitoring`
- kube-state-metrics: workload cluster, namespace `monitoring`
- node-exporter: workload cluster when required by the selected chart
- Grafana: optional, preferably management cluster or internal-only, not required by DevDeploy product pages

The backend runs in `devdeploy-mgmt` and reads observability systems through server-controlled configuration. The browser never receives internal service URLs or credentials.

Phase 2J.27a does not complete the cross-cluster transport path. If Prometheus
and Loki run in `devdeploy-workload`, the management backend cannot rely on
workload-cluster service DNS names directly. The next bootstrap phase should
choose one controlled access method, such as Kubernetes API service proxying via
the server-side workload kubeconfig, or an explicitly provisioned internal route.
The older direct service DNS settings remain useful for same-cluster and
historical local setups, but they are not the final multi-cluster access model.

## Alternatives Considered

### Entire stack in workload cluster

This is the smallest fit for user workload metrics and logs. It avoids cross-cluster scraping for the V1 local environment and keeps workload runtime signals close to the resources they describe.

### Entire stack in management cluster

This centralizes platform components but requires cross-cluster scraping, kubeconfig handling, and additional RBAC before the product needs it. It is better suited to future multi-workload-cluster expansion.

### Central services in management, collectors in workload

This is the target-compatible future model. It supports multiple workload clusters cleanly, but it is more complex than needed for the first local MVP foundation.

## Backend Access Path

The backend is the only product API for observability data.

For Phase 2J.27a, the backend exposes:

- `GET /api/v1/observability/health`: backward-compatible Kubernetes, Prometheus, and Loki health.
- `GET /api/v1/observability/status`: richer component status including Grafana.

Both endpoints require authentication. `/health` intentionally keeps the older
three-component response shape for existing clients. `/status` is the new
capability contract for Settings and later setup/runtime views.

Component statuses are:

- `connected`
- `not_configured`
- `degraded`
- `unavailable`
- `optional`

`connected` requires a successful bounded live check or a fresh cached
successful check. `not_configured` means server-side configuration is absent.
`unavailable` means configuration exists but the component could not be reached
or returned an unsuccessful response. `degraded` is reserved for unreadable or
unexpected health responses. `optional` is used only for unconfigured Grafana,
because Grafana is not required for DevDeploy Monitoring or Logs.

The API returns safe capability flags, message codes, and checked timestamps. It does not return internal URLs, bearer tokens, service account data, certificates, or raw upstream exceptions.

Namespace-level Kubernetes, metrics, and logs endpoints remain platform
administrator-only in this foundation phase. Owner-scoped application logs and
metrics must be added through DeploymentRecord or ServiceDefinition identity in
a later phase; the browser cannot submit arbitrary PromQL or LogQL.

## Query Boundaries

Metric and log APIs remain server-generated and bounded:

- No arbitrary PromQL from the browser.
- No arbitrary LogQL from the browser.
- No arbitrary upstream URL, namespace, service, path, or proxy target from the browser.
- Namespace, pod, range, step, and limits are validated server-side.
- Upstream HTTP requests use bounded timeouts and do not follow redirects.
- Upstream JSON responses are size-limited before parsing.

Owner-scoped application log APIs remain a follow-up phase. The existing namespace log endpoint is a foundation and should not be expanded into arbitrary LogQL.

## Security Boundaries

Frontend responses must not include:

- Prometheus internal service URL
- Loki internal service URL
- Grafana admin credentials
- Kubernetes service account tokens
- cluster certificates
- kubeconfig contents
- raw network exception text
- unrestricted query strings

Backend observability access is read-only. The backend must not use shell, subprocess, or `kubectl` for observability queries.

## Resource Sizing and Retention

The local stack should stay developer-machine friendly:

- single-replica Prometheus/Loki modes
- conservative CPU and memory requests/limits
- short local retention
- no production HA topology
- no cloud object storage dependency

Existing Terraform values already point in this direction for local Loki storage with `emptyDir`. Future launcher bootstrap should preserve this local-first sizing.

Fresh backend configuration should leave Prometheus and Loki URLs empty until
the selected transport is provisioned. Local development may set explicit
localhost URLs. Multi-cluster runtime configuration must not assume that a
backend pod in `devdeploy-mgmt` can resolve workload-cluster service DNS.

## Bootstrap Direction

The repository already has Terraform-based Helm installation for the older local stack. Phase 2J.27a does not perform live installation.

The future launcher-backed bootstrap should:

1. Install or verify a `monitoring` namespace in `devdeploy-workload`.
2. Install or verify kube-prometheus-stack with local-safe values.
3. Install or verify Loki in single-binary or equivalent local-safe mode.
4. Install or verify Grafana Alloy or the selected collector.
5. Configure backend environment variables or Secrets with the selected internal access path.
6. Verify `/api/v1/observability/status` reports connected components.

## Failure Behavior

Health checks are intentionally non-fatal to product pages:

- Product counts and deployment records must not depend on Prometheus.
- Logs are unavailable if Loki is unavailable.
- Time-series metrics are unavailable if Prometheus is unavailable.
- Grafana is optional and must not block DevDeploy Monitoring or Logs pages.

The UI should show honest not configured, unavailable, degraded, or connected states instead of indefinite loading.

## Follow-Up Phases

- Phase 2J.27b: workload observability stack bootstrap design or launcher implementation.
- Phase 2J.27c: bounded Prometheus metric APIs for workload-domain views.
- Phase 2J.27d: owner-scoped Loki logs for DeploymentRecord and ServiceDefinition identities.
- Phase 2J.27e: Dashboard operational analytics using domain records first and metrics as enrichment.
