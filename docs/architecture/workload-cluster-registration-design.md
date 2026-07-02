# Workload Cluster Registration Design

## 1. Overview

This document defines how the host-side DevDeploy Launcher should register the local `devdeploy-workload` kind cluster with Argo CD running in `devdeploy-mgmt`.

It refines the registration direction established by:

- [Multi-Cluster Redesign](./multi-cluster-redesign.md)
- [Bootstrapper / Launcher Design](./bootstrapper-launcher-design.md)
- [Argo CD Bootstrap Preparation](./argocd-bootstrap-preparation.md)
- [Security Boundaries and Credentials Model](./security-credentials-boundaries.md)
- [GitOps Workload Permission Design](./gitops-workload-permission-design.md)

Registration is a platform bootstrap operation. It is separate from GitOps repository configuration, Argo CD Application creation, and normal user workload deployment.

The normal workload path remains:

```text
UI -> Backend -> GitHub/GitOps Repository -> Argo CD -> devdeploy-workload
```

## 2. Network Problem

The workload kind kubeconfig exposed to the Windows host normally uses:

```text
https://127.0.0.1:58081
```

That endpoint is valid for host-side `kubectl`. It is not a valid Argo CD cluster endpoint because Argo CD runs inside a Pod in `devdeploy-mgmt`. From that Pod, `127.0.0.1` refers to the Pod itself, not the Windows host or the workload control plane.

The Launcher must therefore discover an endpoint that is:

- Reachable from a Pod in `devdeploy-mgmt`.
- Routed to the `devdeploy-workload` API server.
- Stable enough for the local cluster lifetime.
- Compatible with the API server certificate and CA.
- Verified before registration state is written.

The Launcher must never copy `https://127.0.0.1:58081` directly into the Argo CD cluster Secret.

## 3. Design Goals

- Register only `devdeploy-workload` through an explicit Launcher mode.
- Validate reachability from the management-cluster Pod network, not only from the host.
- Keep endpoint selection deterministic and visible in sanitized status.
- Use credentials dedicated to Argo CD rather than reusing unrelated backend credentials.
- Prefer namespace-scoped permissions for generated workloads.
- Keep raw kubeconfigs, tokens, certificates, keys, and CA content out of logs and status files.
- Make registration idempotent and recoverable.
- Keep registration independent from Application creation.

## 4. Non-Goals

This phase does not design or perform:

- Argo CD Application creation.
- GitOps repository credential configuration.
- User workload deployment.
- Existing or remote cluster onboarding.
- Cloud networking.
- Production certificate automation.
- Backend Kubernetes write access.
- GitHub Actions access to either Kubernetes cluster.

## 5. Endpoint Strategies

### 5.1 Docker Network Control-Plane Endpoint

Both kind clusters are represented by Docker node containers. A candidate endpoint is:

```text
https://devdeploy-workload-control-plane:6443
```

The Launcher should inspect the Docker networks attached to the management and workload control-plane containers. If they share a network, it should test whether the workload control-plane container name resolves and routes from a temporary probe Pod in `devdeploy-mgmt`.

Validation must include:

- DNS resolution or stable network address discovery.
- TCP connection to API port `6443`.
- TLS validation using the workload cluster CA.
- A Kubernetes API response, not only an open TCP socket.

Advantages:

- Traffic stays inside Docker networking.
- It does not depend on a host-published port.
- The endpoint naturally follows the kind control-plane container lifecycle.
- The control-plane hostname may already be represented in the kind API server certificate.

Risks:

- Container-name DNS behavior must be tested from the Pod network, not assumed.
- Docker network topology can vary by Docker Desktop or kind version.
- A container IP is not stable across recreation and must not be persisted as the preferred identity.
- TLS verification fails if the selected hostname is not in the API server certificate SANs.

### 5.2 Host Gateway Endpoint

The management cluster may be able to reach the host-published workload API port through:

```text
https://host.docker.internal:58081
```

or a discovered Docker gateway address.

Advantages:

- Uses the same published API port already exposed by the workload kind config.
- `host.docker.internal` is commonly available with Docker Desktop on Windows.
- It avoids reliance on cross-container DNS when the kind nodes do not share a usable name-resolution path.

Risks:

- Availability differs across Docker engines and platforms.
- A gateway IP may change and should not be hardcoded.
- The workload API certificate may cover `127.0.0.1` but not `host.docker.internal`.
- Disabling TLS verification to bypass a hostname mismatch is not acceptable as the default.

If this strategy is selected, the Launcher must validate the certificate identity. Future kind config generation may add a stable host-gateway DNS name to `apiServerCertSANs`. For an existing cluster, registration must fail safely when hostname verification cannot be satisfied rather than setting `insecure: true` silently.

### 5.3 Kubeconfig Rewriting

The Launcher can retrieve the workload kubeconfig, parse it as structured YAML, replace only the `clusters[].cluster.server` endpoint, and use the existing CA and authentication material to construct the registration input.

Advantages:

- Reuses the workload cluster's known CA and client configuration.
- Keeps endpoint selection separate from credential extraction.
- Supports either the Docker-network or host-gateway endpoint.
- Can be implemented deterministically with structured parsing.

Risks:

- The default kind client certificate is broadly privileged.
- Raw kubeconfig material is highly sensitive.
- Temporary files can leak credentials if handling is careless.
- Rewriting the endpoint does not solve TLS hostname mismatch by itself.

Kubeconfig rewriting is a transport step, not the preferred authorization model. The Launcher should use it for discovery and CA information, then replace broad credentials with a dedicated registration identity where practical.

### 5.4 Argo CD CLI Registration

`argocd cluster add` can create registration resources from a local kubeconfig context.

Advantages:

- Follows a familiar Argo CD workflow.
- Can create some required ServiceAccount and RBAC resources automatically.

Risks:

- Depends on local Argo CD CLI installation and version compatibility.
- Depends on Argo CD API authentication or interactive login state.
- Makes endpoint rewriting and generated resource ownership less explicit.
- Is harder to make deterministic and auditable in a script-first local launcher.
- Common defaults may create broader permissions than DevDeploy requires.

For V1, direct Launcher management of the target credentials and Argo CD cluster Secret is preferred over `argocd cluster add`.

## 6. Preferred V1 Approach

V1 should use an explicit Launcher-managed registration flow:

```powershell
.\scripts\launcher\devdeploy-launcher.ps1 -RegisterWorkloadClusterWithArgoCD
```

Preferred endpoint order:

1. Discover and test the workload control-plane container endpoint over the shared Docker network.
2. Use `https://devdeploy-workload-control-plane:6443` only if Pod-level DNS, routing, Kubernetes API, and TLS validation all pass.
3. Test `host.docker.internal:58081` as a Windows Docker Desktop fallback.
4. Use the host-gateway strategy only if Pod-level routing and TLS identity validation pass.
5. Fail with actionable diagnostics if neither strategy is safe.

The Launcher must not persist a container IP when a verified stable hostname is available. It must not silently disable TLS verification.

After endpoint selection, the Launcher:

1. Creates or verifies a dedicated Argo CD registration identity in `devdeploy-workload`.
2. Builds the Argo CD cluster configuration in memory.
3. Creates or updates one labeled cluster Secret in `devdeploy-mgmt/argocd`.
4. Verifies the non-sensitive cluster Secret contract and authorization state.
5. Leaves the Argo CD Application count unchanged.

## 7. Endpoint Discovery and Probe Flow

The future registration mode should use this sequence:

1. Verify Docker, kind, kubectl, `devdeploy-mgmt`, `devdeploy-workload`, and management Argo CD readiness.
2. Inspect the Docker networks for both control-plane containers.
3. Generate an ordered list of candidate endpoints without credentials.
4. Create a short-lived probe Pod in `devdeploy-mgmt` with:
   - no mounted ServiceAccount token
   - non-root execution
   - read-only root filesystem where supported
   - no host networking
   - no privileged mode
5. From the probe, validate DNS, TCP, TLS, and a Kubernetes API response for each candidate.
6. Delete the probe Pod after the check, including failure paths.
7. Select only a candidate that passes all required checks.

Creating and deleting the probe Pod is allowed only inside the explicit future registration mode. Verification-only modes must not create probe resources and should use the persisted sanitized strategy plus non-mutating connection checks where possible.

The status file may record the endpoint strategy and host/port, but never query parameters, credentials, or TLS material.

## 8. Credential and RBAC Model

### Preferred scoped model

The preferred V1 identity is a dedicated ServiceAccount such as:

```text
namespace: devdeploy-workloads
name:      devdeploy-argocd-manager
```

The Launcher should create or verify the target namespace as platform bootstrap state. The ServiceAccount should receive a namespace-scoped Role and RoleBinding for only the resource types generated by DevDeploy, initially:

- Deployments and ReplicaSets.
- Pods for health observation.
- Services.
- Ingresses.
- ConfigMaps when generated workload configuration requires them.
- Events and relevant status reads.

The exact verbs should be derived from the generated manifest contract and Argo CD reconciliation requirements. Secret management should remain excluded until a separate secure workload-secret model exists.

The generated GitOps layout currently includes a Namespace manifest. Before enforcing namespace-scoped registration, namespace ownership must be made explicit: either the Launcher owns `devdeploy-workloads` and the GitOps source stops reconciling that Namespace, or a narrowly reviewed cluster-scoped permission is introduced. This must be resolved before the parent Application is created.

### Local-only MVP fallback

If scoped RBAC blocks the first local smoke implementation, a cluster-admin registration identity may be used only as a temporary local-kind fallback when all of these are true:

- The user explicitly selected the local MVP mode.
- Status and documentation mark the permission as broad and temporary.
- Credentials remain only in local cluster Secrets.
- No credential is committed to Git or written to launcher logs/status.
- A follow-up hardening item replaces it with scoped access before existing-cluster or non-local support.

Cluster-admin must not become the silent default for future external clusters.

Phase 2G.3 does not use this fallback. The identity is `kube-system/devdeploy-argocd-manager`, bound to a read-only registration role that permits selected metadata discovery but no workload writes. The Argo CD cluster Secret is limited to `devdeploy-workloads` with cluster-resource management disabled. Workload reconciliation permissions remain blocked on the namespace ownership decision described above and must be added before parent Application creation.

### Token lifecycle

Argo CD needs a durable credential. The implementation must deliberately choose between a restricted ServiceAccount token Secret with documented local-only lifecycle or a renewable token mechanism. Short-lived TokenRequest credentials must not be registered without an implemented rotation path.

Phase 2G.3 uses the local-only durable option: a manually requested `kubernetes.io/service-account-token` Secret named `devdeploy-argocd-manager-token`. The launcher reads the populated token and CA only in memory while reconciling the Argo CD cluster Secret. Their values are never printed, logged, or written to launcher status. Rotation remains future hardening work.

## 9. Argo CD Cluster Secret

The Launcher should create or update one Secret in `devdeploy-mgmt/argocd` with metadata equivalent to:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: devdeploy-workload-cluster
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: cluster
type: Opaque
```

Its data logically contains:

- `name`: stable Argo CD cluster name, `devdeploy-workload`.
- `server`: the verified Pod-reachable API endpoint.
- `config`: serialized authentication and TLS client configuration.

The document intentionally omits credential values. Implementation must build the Secret without placing decoded token, certificate, key, CA, or kubeconfig content in command arguments, console output, logs, or status JSON. Prefer stdin or an in-memory structured object over temporary credential files.

The operation should be idempotent:

- Create the Secret when absent.
- Compare non-sensitive metadata and a credential fingerprint when present.
- Update only when endpoint or credential state needs reconciliation.
- Never print a Secret diff containing data.

## 10. Launcher Modes

### Registration mode

Implemented explicit mode:

```powershell
-RegisterWorkloadClusterWithArgoCD
```

This mode:

- Consumes the fresh endpoint selected by the separate discovery mode.
- Create or reconcile the dedicated workload ServiceAccount and RBAC.
- Create or reconcile the Argo CD cluster Secret.
- Performs sanitized metadata and authorization verification.

It must not:

- Create an Argo CD Application.
- Configure a GitOps repository.
- Deploy a user workload.
- Modify backend or frontend resources.
- Expose credentials.

### Verification mode

Phase 2G.4 implements strict read-only registration verification:

```powershell
-VerifyWorkloadClusterRegistration
```

It reads cluster/Secret metadata, identity and RBAC metadata, authorization boundaries, Application inventory, and controller visibility evidence. It does not recreate credentials, patch RBAC, replace the cluster Secret, or create Applications. The verifier confirms that workload Deployment creation remains denied; registration readiness does not imply deployment permission.

## 11. Status Contract

Proposed sanitized shape:

```json
{
  "registered": false,
  "ready": false,
  "source_cluster": "devdeploy-mgmt",
  "source_namespace": "argocd",
  "target_cluster": "devdeploy-workload",
  "target_context": "kind-devdeploy-workload",
  "registration_method": "launcher-managed-cluster-secret",
  "endpoint_strategy": "not_selected",
  "server_endpoint": null,
  "cluster_secret_present": false,
  "cluster_secret_name": "argocd-cluster-devdeploy-workload",
  "cluster_secret_label_present": false,
  "service_account_namespace": "kube-system",
  "service_account_name": "devdeploy-argocd-manager",
  "service_account_present": false,
  "rbac_mode": "scoped-read-only-registration",
  "credential_lifecycle": "local-only-long-lived-service-account-token",
  "argocd_visible": null,
  "application_count": null,
  "write_rbac_configured": null,
  "mode": "not_started",
  "status": "not_started",
  "message": "Workload cluster registration has not been requested.",
  "checked_at": "<ISO-8601 timestamp>"
}
```

Allowed endpoint strategies should be stable identifiers such as:

- `docker_network_control_plane`
- `host_docker_internal`
- `docker_gateway`
- `not_selected`

`server_endpoint` may contain only the verified API URL, for example `https://devdeploy-workload-control-plane:6443`. It must not contain credentials, query parameters, or serialized configuration.

## 12. Verification Design

Registration is ready only when all required checks pass:

- `devdeploy-workload` exists and has a Ready node.
- The selected API endpoint is reachable from the `devdeploy-mgmt` Pod network.
- TLS validation succeeds against the workload CA and expected server identity.
- The dedicated ServiceAccount and required authorization bindings exist.
- The Argo CD cluster Secret exists with the expected label and name.
- Argo CD discovers the cluster.
- Argo CD reports a successful connection or an equivalent verified API probe succeeds using the registered identity.
- No Argo CD Application is created by registration.

If querying Argo CD connection status requires an Argo CD API session, the Launcher may use a short-lived credential held only in memory. It must not write the Argo CD administrator password or session token to logs/status. When API authentication is unavailable, `argocd_connection_status` should remain `unknown` rather than reporting a false success.

The Application count may remain `0` after successful registration. Registration success must not depend on Application creation.

## 13. Failure Recovery and Idempotency

- Existing matching registration should be verified rather than recreated blindly.
- A failed candidate endpoint must not be written to the cluster Secret.
- Partial ServiceAccount/RBAC state should be reported with actionable recovery guidance.
- A failed Secret update must not trigger automatic cluster deletion or Argo CD reinstall.
- Temporary probe resources should use deterministic labels and bounded cleanup.
- Credential rotation should replace the Argo CD cluster Secret atomically where practical.
- Removing registration must be a separate explicit future operation.

## 14. Security Boundaries

- Never log raw kubeconfig content.
- Never log bearer tokens.
- Never log client certificates or client keys.
- Never log CA certificate content.
- Never expose base64 Secret data in launcher status.
- Never pass Kubernetes credentials to GitHub Actions.
- Never store workload credentials in Git or browser storage.
- Never silently set Argo CD TLS verification to insecure.
- Keep registration credentials separate from backend observability credentials.
- Treat cluster-admin as a documented local-only fallback, not the preferred steady state.

## 15. Implementation Sequence

Recommended follow-up milestones:

1. **Completed in Phase 2G.2:** add explicit endpoint discovery with a guarded Pod-network probe, TLS validation, sanitized candidate reporting, and targeted cleanup.
2. **Completed in Phase 2G.3:** implement `-RegisterWorkloadClusterWithArgoCD` using the discovered endpoint, a launcher-managed cluster Secret, a durable local-only token, and read-only registration RBAC.
3. **Completed in Phase 2G.4:** implement strict read-only registration verification, including cluster Secret, endpoint, identity/RBAC boundary, controller visibility evidence, and Application inventory checks.
4. Finalize namespace ownership and add scoped workload reconciliation permissions before creating the parent Application.
5. Only then configure the GitOps repository and create parent Application `devdeploy-workloads`.

No runtime registration should begin until endpoint reachability and TLS identity behavior have been validated on the supported Windows Docker Desktop and kind versions.

The Phase 2G.2 local validation selected `devdeploy-workload-control-plane:6443` through the shared Docker network. The host-gateway candidate was network-reachable but did not pass hostname-aware TLS verification, and the Docker gateway candidate was unreachable. These are environment observations, not permanent assumptions; the Launcher must rediscover and revalidate candidates on each explicit discovery run.
