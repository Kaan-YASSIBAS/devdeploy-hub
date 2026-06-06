# Localhost Networking and Port Strategy

## 1. Overview

This document defines the localhost networking, port mapping, ingress, and app URL strategy for the DevDeploy Hub local-first multi-cluster architecture.

The higher-level architecture is defined in:

- [Multi-Cluster Redesign](./multi-cluster-redesign.md)
- [Bootstrapper / Launcher Design](./bootstrapper-launcher-design.md)
- [Setup Wizard Multi-Cluster Lifecycle Design](./setup-wizard-multi-cluster-lifecycle.md)
- [GitOps Repository Layout and Argo CD Application Model](./gitops-repository-argocd-model.md)

In the target architecture:

- DevDeploy platform components run in the management cluster: `devdeploy-mgmt`.
- User applications run only in the workload cluster: `devdeploy-workload`.
- Argo CD runs in `devdeploy-mgmt` and deploys user workloads to `devdeploy-workload`.
- Normal workload deployment remains GitOps-only:

```text
UI -> Backend -> GitHub/GitOps Repository -> Argo CD -> Workload Kubernetes Cluster
```

V1 should provide stable localhost access without routine `kubectl port-forward`.

## 2. Design Goals

- Provide predictable local URLs for the DevDeploy UI and user apps.
- Keep management UI/API traffic separate from workload app traffic.
- Avoid routine `kubectl port-forward` for normal usage.
- Make required host ports explicit and visible to users.
- Let the Bootstrapper / Launcher perform host-side port checks before cluster creation.
- Keep the Setup Wizard as a status and guidance surface, not a host command executor.
- Support a simple V1 HTTP path while preserving future HTTPS and custom domain options.
- Avoid URL strategies that require every generated app to be aware of a path prefix.

## 3. Non-Goals

- This document does not implement port checks.
- This document does not modify kind configs.
- This document does not modify Kubernetes manifests.
- This document does not install ingress-nginx.
- This document does not implement TLS automation.
- This document does not add cloud load balancers.
- This document does not change the GitOps deployment flow.
- This document does not allow the backend or GitHub Actions to deploy directly to Kubernetes.

## 4. Cluster Networking Roles

The two clusters have different networking responsibilities.

`devdeploy-mgmt`:

- Hosts DevDeploy Hub UI.
- Hosts DevDeploy backend API.
- Hosts PostgreSQL.
- Hosts Argo CD.
- Hosts platform observability components when used for management.
- Provides local access to the platform UI/API through management ingress.

`devdeploy-workload`:

- Hosts generated user applications.
- Hosts workload ingress for user app access.
- Receives desired state from Argo CD running in `devdeploy-mgmt`.
- Does not host DevDeploy platform services.

The management cluster is the control plane for the product. The workload cluster is the execution target for user apps.

## 5. Default Port Plan

V1 should use stable default localhost ports.

Management cluster defaults:

| Purpose | Address |
| --- | --- |
| Kubernetes API server | `127.0.0.1:58080` |
| HTTP ingress | `127.0.0.1:8080` |
| HTTPS ingress | `127.0.0.1:8443` |
| DevDeploy UI URL | `http://devdeploy.localhost:8080` |

Workload cluster defaults:

| Purpose | Address |
| --- | --- |
| Kubernetes API server | `127.0.0.1:58081` |
| HTTP ingress | `127.0.0.1:8081` |
| HTTPS ingress | `127.0.0.1:8444` |
| User app URL pattern | `http://<app-name>.localhost:8081` |

The management and workload clusters should use separate ingress ports. This avoids ambiguity between platform traffic and user application traffic.

## 6. Management Cluster Access

The management cluster should expose the DevDeploy Hub UI and API through management ingress.

Recommended V1 URL:

```text
http://devdeploy.localhost:8080
```

The management ingress should route:

- Frontend UI traffic to DevDeploy frontend.
- API traffic to DevDeploy backend.
- Optional platform access paths, if explicitly designed later.

The management ingress must not route generated user apps. User apps belong to the workload cluster.

## 7. Workload Cluster App Access

User applications should be exposed through workload ingress.

Recommended V1 URL pattern:

```text
http://<app-name>.localhost:8081
```

Examples:

```text
http://payment-api.localhost:8081
http://nginx-demo.localhost:8081
```

Generated app ingress rules should target services in `devdeploy-workload`, not platform services in `devdeploy-mgmt`.

## 8. Host-Based Routing Strategy

V1 should prefer host-based routing.

Host-based routing maps each app to its own local hostname:

```text
http://payment-api.localhost:8081
http://frontend-demo.localhost:8081
http://podinfo.localhost:8081
```

Benefits:

- Apps can serve from root path `/`.
- Static asset paths are less likely to break.
- Browser callbacks and redirects are easier to reason about.
- Frontend router configuration is simpler.
- Generated ingress is closer to production-style host routing.
- App URLs are predictable and user-friendly.

The `.localhost` domain is reserved for local use and commonly resolves to loopback without manual hosts file edits in modern environments.

## 9. Why Path-Based Routing Is Not Preferred for V1

Path-based routing would use URLs such as:

```text
http://localhost:8081/apps/payment-api
```

This is not preferred for V1 because many apps expect to run at `/`.

Path prefixes can break:

- Static asset URLs.
- Absolute links.
- Frontend router base paths.
- OAuth or callback URLs.
- Redirect behavior.
- Cookie path assumptions.
- Reverse proxy assumptions.

Path-based routing may still be useful later for specific platform features, previews, or proxy-style app access. It should not be the default for generated workloads in V1.

## 10. kind extraPortMappings Strategy

The Launcher should generate kind configs with explicit `extraPortMappings`.

Management cluster example intent:

```yaml
apiVersion: kind.x-k8s.io/v1alpha4
kind: Cluster
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

Workload cluster example intent:

```yaml
apiVersion: kind.x-k8s.io/v1alpha4
kind: Cluster
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

The selected ports should be part of setup status so the Setup Wizard and Settings pages can display them.

## 11. Port Discovery and Conflict Handling

The Launcher is responsible for host-side port checks.

Required V1 ports:

- `58080` for management Kubernetes API.
- `8080` for management HTTP ingress.
- `8443` for management HTTPS ingress.
- `58081` for workload Kubernetes API.
- `8081` for workload HTTP ingress.
- `8444` for workload HTTPS ingress.

V1 behavior:

- Check required ports before creating clusters.
- Fail before cluster creation if required ports are busy.
- Show actionable messages that identify the busy port and expected use.
- Do not silently choose random ports for user-facing endpoints.
- Do not proceed with partial port mappings that would make URLs inaccurate.

Future versions may allow explicit custom ports or suggested alternatives, but automatic random selection should not be the default because it makes documentation, UI links, and troubleshooting less predictable.

## 12. Ingress Controller Placement

ingress-nginx may run in both clusters.

Management cluster:

- Runs management ingress.
- Routes DevDeploy UI/API traffic.
- May route Argo CD UI later if explicitly designed.

Workload cluster:

- Runs workload ingress.
- Routes generated user app traffic.
- Receives generated app Ingress resources from GitOps.

Generated user app ingress must target workload ingress only. It must not point to management cluster resources.

## 13. Generated Ingress Rules for User Apps

Generated user app ingress should follow the host-based pattern:

```text
<app-name>.localhost
```

The browser URL should include the workload HTTP port:

```text
http://<app-name>.localhost:8081
```

Generated ingress rules should:

- Use the app's Kubernetes-safe name as the host prefix.
- Route `/` to the generated Service.
- Use the generated app namespace, such as `devdeploy-workloads`.
- Use workload ingress class settings only.
- Be omitted when expose/ingress is not enabled.

Generated app ingress must not:

- Route to DevDeploy backend or frontend services.
- Depend on management cluster ingress.
- Require app code to know a path prefix.

## 14. Localhost DNS Behavior

V1 should rely on `.localhost` hostnames where possible.

Examples:

```text
devdeploy.localhost
payment-api.localhost
nginx-demo.localhost
```

The `.localhost` name is reserved for loopback use. This generally avoids editing the host file for each generated app.

The Launcher should still verify behavior where practical and provide troubleshooting guidance if a user's OS, browser, VPN, proxy, or DNS tooling interferes with `.localhost` resolution.

Fallback options for future versions:

- `127.0.0.1` with explicit Host header guidance for diagnostics.
- A local DNS helper.
- hosts file management with explicit user consent.
- custom local domain support.

## 15. HTTPS and TLS Position for V1

V1 should use HTTP by default.

HTTPS ports should be reserved or documented:

- Management HTTPS: `8443`.
- Workload HTTPS: `8444`.

TLS automation is postponed.

Reasons:

- Local trusted certificates add setup complexity.
- Browser trust stores differ by OS.
- Certificate lifecycle and renewal need clear ownership.
- HTTP is acceptable for the first local-only default when bound to `127.0.0.1`.

The design should remain compatible with future TLS support through:

- Local development certificates.
- mkcert-style workflows.
- user-provided certificates.
- custom domains.

## 16. Setup Wizard Visibility

The Setup Wizard should display selected networking values clearly.

Recommended fields:

- Management cluster API server address.
- Management UI URL.
- Management HTTP and HTTPS ingress ports.
- Workload cluster API server address.
- Workload app URL pattern.
- Workload HTTP and HTTPS ingress ports.
- Port check status.
- Runtime limitation messages when checks are running in Kubernetes mode.

The Wizard should not run host port checks directly from the browser. It should display results from backend setup/status APIs and Launcher-provided status.

## 17. Failure and Recovery Cases

Expected failure cases:

- Required port is busy before cluster creation.
- A cluster exists but was created with different port mappings.
- `.localhost` resolution behaves unexpectedly.
- ingress-nginx is not ready.
- Generated app ingress exists but workload Service has no ready endpoints.
- Management UI URL is unavailable.
- Workload app URL is unavailable.

Recommended recovery behavior:

- Fail early if required ports are busy.
- Explain which process or port is blocking setup when possible.
- If an existing cluster has incompatible port mappings, recommend recreate or explicit recovery action.
- Do not silently recreate clusters.
- Do not silently switch ports after cluster creation.
- Show whether the failure is host port, ingress controller, DNS, service, pod readiness, or GitOps sync related.

## 18. Security Boundaries

Security boundaries:

- Bind local ingress and API ports to `127.0.0.1` by default.
- Do not expose local platform services on all network interfaces by default.
- Do not store port configuration with secret values.
- Do not store tokens or kubeconfigs in browser localStorage.
- Do not let backend directly deploy or delete normal user workloads.
- Do not let GitHub Actions deploy directly to clusters.
- Keep generated user app ingress in `devdeploy-workload`.
- Keep platform ingress in `devdeploy-mgmt`.

If future versions support non-loopback binding, the UI and Launcher must require explicit user consent and clear security warnings.

## 19. V1 Implementation Recommendation

V1 should use:

- `devdeploy-mgmt` for platform components.
- `devdeploy-workload` for user apps.
- Management UI URL:

  ```text
  http://devdeploy.localhost:8080
  ```

- User app URL pattern:

  ```text
  http://<app-name>.localhost:8081
  ```

- Management API server:

  ```text
  127.0.0.1:58080
  ```

- Workload API server:

  ```text
  127.0.0.1:58081
  ```

- HTTP as the primary local path.
- HTTPS ports reserved for future use.
- ingress-nginx in both management and workload clusters.
- Launcher-owned port checks and kind config generation.
- Setup Wizard display of chosen ports and URL patterns.

This gives stable local access while preserving the management/workload cluster separation.

## 20. Future Enhancements

Future enhancements may include:

- Explicit custom port selection during setup.
- Suggested alternative ports when defaults are busy.
- Local trusted HTTPS certificates.
- Custom local domains.
- Local DNS helper.
- hosts file management with user consent.
- Per-app URL previews in the deployment flow.
- Ingress health diagnostics.
- Automatic app URL reachability checks.
- More advanced routing modes for apps that support path prefixes.

These enhancements should preserve the core boundary: user workloads are declared in Git, applied by Argo CD, and exposed through workload cluster ingress.
