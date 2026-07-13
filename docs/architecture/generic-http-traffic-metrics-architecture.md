# Generic HTTP Traffic Metrics Architecture

## 1. Overview

This document defines the target architecture for generic HTTP traffic metrics in DevDeploy Hub managed workloads.

DevDeploy Hub can already read workload-cluster observability data through the backend, and CPU, memory, pod, restart, and replica metrics are available when the workload observability stack is installed. HTTP request rate, 4xx rate, 5xx rate, and latency remain empty for simple workloads such as `recover-nginx` because the application container does not expose Prometheus HTTP metrics.

The goal is to add a generic telemetry path for arbitrary user-provided HTTP container images without requiring users to install exporters, dashboards, ServiceMonitors, port-forwards, or application-specific instrumentation.

The product truth model remains unchanged:

- PostgreSQL domain records are product truth.
- The GitOps repository is desired state.
- Argo CD applies desired state to the workload cluster.
- Kubernetes and Prometheus are runtime and telemetry truth.
- The browser reads telemetry only through authenticated DevDeploy backend APIs.

Normal workload deployment remains GitOps-only:

```text
UI -> Backend -> GitOps Repository -> Argo CD -> devdeploy-workload
```

## 2. Design Goals

- Show request rate, 4xx rate, 5xx/error rate, and optional latency for managed HTTP workloads.
- Support arbitrary user-provided HTTP images without modifying the application container.
- Keep application-native Prometheus metrics supported when an application already exposes them.
- Avoid nginx-only exporters or assumptions about a specific web server.
- Keep generated manifests deterministic and GitOps-compatible.
- Keep preview, destroy, recover, and status flows stable.
- Keep telemetry platform installation Launcher-managed.
- Keep local-first operation portable across user machines.
- Keep metrics optional and honest when unavailable.
- Avoid broad Kubernetes permissions, arbitrary proxying, and client-controlled telemetry targets.

## 3. Non-Goals

- This document does not implement runtime code.
- This document does not change current Monitoring empty-state behavior.
- This document does not add dependencies or generated manifests.
- This document does not install a service mesh.
- This document does not require user applications to expose Prometheus metrics.
- This document does not expose Prometheus, Loki, Grafana, Kubernetes, or ClusterIP URLs to the browser.
- This document does not introduce CI image builds or source-to-image workflows.
- This document does not make the backend apply or delete normal workloads.

## 4. Current Baseline

The workload observability foundation already defines:

- Prometheus, Loki, Grafana, Alloy, kube-state-metrics, and node-exporter in `devdeploy-workload/monitoring`.
- Backend-mediated reads through server-controlled Kubernetes Service proxy paths.
- No arbitrary PromQL or LogQL from the browser.
- Narrow workload observability credentials separate from normal workload credentials.
- Product pages that treat metrics as enrichment, not product truth.

The remaining gap is HTTP application traffic telemetry. Kubernetes resource metrics can show that a pod is running, but they cannot infer request counts or HTTP status code classes unless traffic is measured by the application, ingress, proxy, mesh, or logs.

## 5. Approach Evaluation

| Approach | Generic workload compatibility | Request/status visibility | Latency visibility | Manifest impact | Resource cost | Operational complexity | Fit for V1 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Application-native Prometheus metrics | Low to medium; depends on each image | Good when implemented by app | Good when implemented by app | Optional scrape metadata only | Low | Medium because every app differs | Support as optional, not primary |
| NGINX/Ingress Controller metrics | Medium; only ingress traffic is visible | Good for externally routed traffic | Limited to ingress path | Requires ingress and stable routing | Low | Medium | Useful later, not enough for Service/preview traffic |
| Managed Envoy telemetry sidecar/proxy | High for HTTP workloads | Good for all Service traffic through proxy | Good with Envoy histograms | Deployment and Service generation changes | Medium | Medium | Recommended target |
| Service mesh | High | Good | Good | Significant platform and traffic model changes | High | High | Too heavy for local V1 |
| Access-log-derived metrics through Alloy/Loki | Medium; depends on log format | Inconsistent without standardized logs | Poor to medium | No app manifest change if logs exist | Medium | Medium to high | Useful fallback, not canonical |
| Hybrid model | High | Good | Good | Controlled by telemetry mode | Medium | Medium | Recommended product model |

## 6. Recommended Target Architecture

Use a hybrid model:

1. **Managed Envoy telemetry proxy for generic HTTP workloads.**
   DevDeploy generates an Envoy sidecar inside the workload pod. The Kubernetes Service targets the proxy listener, and the proxy forwards to the application container over `localhost`.

2. **Application-native Prometheus metrics as an optional enrichment.**
   If the app exposes its own metrics, DevDeploy can scrape or query them separately and show app-specific charts without relying on them for generic request/error rate.

3. **Ingress-controller and log-derived metrics as later secondary signals.**
   These can help explain external traffic and troubleshooting, but they should not be the canonical V1 request-rate source.

This architecture is generic for HTTP apps because the application container does not need to know Prometheus, Envoy, Loki, Grafana, or DevDeploy. DevDeploy controls the generated proxy configuration and the stable labels used for queries.

## 7. Why Envoy Sidecar Is The Target

The managed proxy model gives DevDeploy a consistent measurement point for HTTP traffic that enters the Kubernetes Service:

```text
Service port -> Envoy listener -> localhost:<app_container_port> -> app container
                         |
                         +-> Envoy admin/stats port scraped by Prometheus
```

Key properties:

- The application image remains user-provided and unmodified.
- The Service exposes the proxy listener, not the direct application port.
- The proxy emits request totals, status-code classes, and duration histograms.
- Prometheus discovers proxy metrics using DevDeploy labels.
- Preview and Service traffic can use the same stable Service endpoint.
- GitOps manifests remain deterministic.
- Destroy and recover remain normal manifest changes.
- Logs remain collected through Loki from pod/container logs.

The direct application port is still present inside the pod, but it is not the Service `targetPort`. It is reachable only within the pod network namespace and by other containers in the same pod.

## 8. Rejected Alternatives

### Application-native metrics only

This should remain supported, but it cannot be the default product answer. Many arbitrary images, including `nginx:latest`, do not expose the request and status metrics DevDeploy needs.

### NGINX or ingress-only metrics

Ingress metrics only measure traffic that enters through ingress. DevDeploy preview, internal Service calls, and non-ingress traffic may bypass ingress. It also does not help workloads that are not exposed through ingress yet.

### NGINX exporter sidecar

This is not generic. It assumes a specific server and configuration surface and would not work for arbitrary Python, Node, Java, Go, or custom HTTP containers.

### Service mesh

A mesh can solve this well, but it is too heavy for the local-first V1. It introduces CRDs, sidecar injection, control-plane lifecycle, policy surface, and troubleshooting cost that are not needed for the first product-grade path.

### Loki/access-log-derived metrics only

Logs are useful for troubleshooting and can be a fallback, but log formats are not stable across arbitrary images. Log-derived latency is especially unreliable unless every app uses a known structured format.

## 9. HTTP And Non-HTTP Classification

DevDeploy should model the service protocol explicitly.

Recommended domain fields:

- `protocol`: `http` or `tcp`
- `telemetry_enabled`: boolean
- `telemetry_mode`: `none`, `managed_proxy`, `native_prometheus`, or `hybrid`
- `app_container_port`: the application container port
- `service_port`: the Kubernetes Service port exposed to other clients
- `proxy_listener_port`: generated proxy listener port, for example `18080`
- `proxy_metrics_port`: generated proxy metrics/admin port, for example `19090`
- `native_metrics_path`: optional, default empty
- `native_metrics_port`: optional, default empty

For V1, new HTTP services should expose telemetry as an explicit option in the product model. Existing records should default to `telemetry_enabled=false` until regenerated or opted in. After the managed proxy path is proven through live smoke tests, DevDeploy can consider enabling it by default for new HTTP services.

Non-HTTP services use `telemetry_mode=none` unless a later TCP metrics design is added. They should still receive Kubernetes readiness, replica, CPU, memory, restart, and log signals.

## 10. Generated Manifest Changes

When `protocol=http` and `telemetry_mode=managed_proxy` or `hybrid`, generated manifests should change as follows.

Deployment:

- Keep the application container and existing security defaults.
- Add an Envoy sidecar container with:
  - a listener on `proxy_listener_port`
  - an upstream cluster pointing to `127.0.0.1:<app_container_port>`
  - an admin or metrics listener on `proxy_metrics_port`
  - resource requests and limits
  - non-root security context where supported by the selected image
  - read-only root filesystem when compatible
- Add a generated ConfigMap for Envoy configuration.
- Mount only the Envoy config into the Envoy container.
- Do not mount secrets into the proxy unless a future TLS mode requires it.
- Do not expose the direct app container port through the Service.

Service:

- Keep the Service name stable.
- Keep the selector stable.
- Set the public Service `targetPort` to the Envoy listener port name, for example `http-proxy`.
- Do not add the Envoy metrics/admin port to the user-facing Service.

Metrics discovery:

- Prefer a platform-managed PodMonitor or ServiceMonitor that selects pods with `devdeploy.io/telemetry=managed-proxy`.
- Scrape only the proxy metrics port.
- Do not require every application folder to own a ServiceMonitor in V1 unless the selected chart setup makes that simpler.

App kustomization:

- Include the generated Envoy ConfigMap only when telemetry proxy is enabled.
- Keep resource ordering deterministic.

## 11. Prometheus Discovery And Labels

Prometheus should discover managed proxy metrics through stable labels.

Required generated labels:

```text
app.kubernetes.io/name=<app-name>
app.kubernetes.io/managed-by=devdeploy
app.kubernetes.io/part-of=devdeploy-workloads
devdeploy.io/service-id=<service-definition-id>
devdeploy.io/deployment-id=<deployment-record-id>
devdeploy.io/app-name=<app-name>
devdeploy.io/telemetry=managed-proxy
```

The `service-id` and `deployment-id` labels should be stable product identifiers, not display names. The app name remains useful for Kubernetes and UI filtering, but database IDs avoid ambiguity after renames or recovery flows.

The scrape job should preserve these labels on recorded metrics. If raw Envoy metric labels are inconsistent across versions, DevDeploy should create recording rules that normalize them into DevDeploy-owned metric names.

## 12. Normalized Metric Contract

DevDeploy UI and backend queries should prefer normalized recording-rule metrics instead of raw Envoy metrics.

Recommended normalized counters and histograms:

```text
devdeploy_workload_http_requests_total{
  namespace,
  app,
  service_id,
  deployment_id,
  pod,
  status_class
}

devdeploy_workload_http_request_duration_seconds_bucket{
  namespace,
  app,
  service_id,
  deployment_id,
  pod,
  le
}
```

Raw Envoy metrics should be mapped into these normalized series by platform-managed Prometheus rules. Application-native metrics can later be mapped into the same shape only when the app owner explicitly opts in and the metric contract is known.

The `status_class` values should be:

- `2xx`
- `3xx`
- `4xx`
- `5xx`
- `unknown`

## 13. PromQL Query Strategy

Backend-generated PromQL should be scoped by namespace and stable DevDeploy labels. The browser must not submit arbitrary PromQL.

Request rate:

```promql
sum by (namespace, app, service_id, deployment_id) (
  rate(devdeploy_workload_http_requests_total{
    namespace="devdeploy-apps",
    service_id="$service_id",
    deployment_id="$deployment_id"
  }[5m])
)
```

4xx rate:

```promql
sum by (namespace, app, service_id, deployment_id) (
  rate(devdeploy_workload_http_requests_total{
    namespace="devdeploy-apps",
    service_id="$service_id",
    deployment_id="$deployment_id",
    status_class="4xx"
  }[5m])
)
```

5xx rate:

```promql
sum by (namespace, app, service_id, deployment_id) (
  rate(devdeploy_workload_http_requests_total{
    namespace="devdeploy-apps",
    service_id="$service_id",
    deployment_id="$deployment_id",
    status_class="5xx"
  }[5m])
)
```

Error rate:

```promql
sum by (namespace, app, service_id, deployment_id) (
  rate(devdeploy_workload_http_requests_total{
    namespace="devdeploy-apps",
    service_id="$service_id",
    deployment_id="$deployment_id",
    status_class=~"4xx|5xx"
  }[5m])
)
```

P95 latency:

```promql
histogram_quantile(
  0.95,
  sum by (le, namespace, app, service_id, deployment_id) (
    rate(devdeploy_workload_http_request_duration_seconds_bucket{
      namespace="devdeploy-apps",
      service_id="$service_id",
      deployment_id="$deployment_id"
    }[5m])
  )
)
```

To avoid double counting:

- Count at the proxy listener only.
- Do not combine ingress metrics and proxy metrics in the same primary chart.
- Sum per-pod proxy rates by stable DevDeploy identifiers.
- Do not multiply by replica count.
- Do not join request counters with kube-state-metrics replica data.

When no traffic exists, Prometheus may return empty vectors or zero rates depending on scrape history. The backend should return an honest `no_data` or zero-rate state rather than marking the workload unhealthy.

## 14. Preview Compatibility

The backend preview route should continue to derive targets from owned DeploymentRecord and runtime Service data. When telemetry proxy is enabled:

- The Service points to the proxy listener.
- Preview traffic through the Service is measured by the proxy.
- The preview backend route still does not expose ClusterIP.
- The browser still receives only a DevDeploy backend preview URL.

No preview client should be able to choose an upstream host, port, service, or namespace.

## 15. Health And Readiness Semantics

Health must remain honest:

- If the application container is not ready, the Deployment should not be reported healthy.
- If the proxy is not ready, the Service path should not be reported healthy.
- If the proxy is ready but the app returns 5xx, runtime may be available while HTTP health is degraded.
- If Prometheus cannot scrape proxy metrics, traffic charts should show unavailable or no data without marking the Deployment failed by itself.

The proxy should not hide application failures. It should forward upstream status codes and expose them as telemetry.

## 16. Security And Failure Isolation

Generated proxy configuration must be server-generated and deterministic.

Rules:

- No arbitrary proxy target from the client.
- No external upstream hostnames in V1.
- Upstream target is only `127.0.0.1:<validated_app_container_port>`.
- Metrics/admin port is not exposed through the user-facing Service.
- Proxy container uses non-root, dropped capabilities, no privilege escalation, resource limits, and no host networking.
- No `hostPath` volumes.
- No service account token mount unless required by Kubernetes defaults and explicitly justified.
- No tokens, certificates, or user secrets in Envoy config.
- Backend Prometheus queries are generated from owned domain records and validated identifiers.

If the proxy fails, it should affect only that workload pod. It must not affect other workloads or the platform observability stack. Resource requests and limits should prevent a busy workload proxy from starving the node.

## 17. Backward Compatibility And Migration

Existing ServiceDefinition and DeploymentRecord rows should remain valid.

Migration rules:

- Add nullable or defaulted telemetry fields.
- Existing records default to `telemetry_enabled=false` and `telemetry_mode=none`.
- Existing generated manifests are not rewritten automatically.
- Runtime-only untracked resources do not receive DevDeploy HTTP metrics.
- Users can enable telemetry on a future update/recover/redeploy path that regenerates manifests.
- Rollback can disable telemetry by setting `telemetry_enabled=false` and regenerating direct Service-to-app manifests.

This avoids surprising live changes to working deployments.

## 18. User Experience

For HTTP services with managed telemetry enabled, the UI can show:

- Request rate.
- 4xx rate.
- 5xx/error rate.
- P95 latency.
- No-traffic state.
- Metrics unavailable state.
- Proxy unhealthy state.

For HTTP services without telemetry enabled, the UI should explain that HTTP traffic metrics are not enabled yet and continue showing Kubernetes readiness, replicas, CPU, memory, restarts, logs, and GitOps status.

For non-HTTP services, HTTP metrics should be hidden or shown as not applicable.

## 19. Implementation Phases

### Phase 2J.28b - Domain And API Foundation

- Add domain fields for protocol, telemetry mode, telemetry enablement, and proxy ports.
- Add validation for HTTP versus non-HTTP service settings.
- Add read models that report telemetry capability without changing manifests.
- Keep existing records defaulted to no telemetry.

### Phase 2J.28c - Manifest Generation

- Add deterministic Envoy sidecar and ConfigMap generation for opted-in HTTP services.
- Update Service targetPort to the proxy listener only when telemetry is enabled.
- Add generated labels required for Prometheus discovery.
- Add tests for direct app port isolation, deterministic YAML, and security context.

### Phase 2J.28d - Prometheus Discovery And Queries

- Add or verify a platform-managed PodMonitor or ServiceMonitor for managed proxy metrics.
- Add Prometheus recording rules that normalize raw proxy metrics.
- Add backend-generated PromQL queries for request rate, 4xx, 5xx, errors, and latency.
- Preserve no-data and unavailable states.

### Phase 2J.28e - Frontend And Live Smoke

- Show traffic metrics on service/deployment detail surfaces.
- Show no-data, not-enabled, and unavailable states distinctly.
- Run a live HTTP workload smoke test that sends requests through the Service or preview path.
- Verify Prometheus sees request counters and status classes.

### Later Phases

- Optional application-native metrics mapping.
- Ingress traffic comparison metrics.
- Access-log-derived fallback analytics.
- Explicit telemetry disable/rollback operation.
- Per-route traffic views.
- Multi-cluster metrics federation.

## 20. Final Recommendation

DevDeploy Hub should implement a hybrid telemetry model with a managed Envoy sidecar as the V1 generic HTTP metrics path. It is the smallest architecture that gives consistent request, status-code, and latency visibility for arbitrary HTTP images while preserving GitOps, local-first portability, and security boundaries.

Application-native metrics should remain supported as enrichment, but they should not be required for the core request/error-rate product experience. Service mesh and log-derived metrics should be postponed until the product needs their additional complexity.
