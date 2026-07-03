# GitOps Workload Permission Design

## 1. Overview

This document defines the V1 authorization boundary that will allow Argo CD in `devdeploy-mgmt` to reconcile user workloads in `devdeploy-workload` without cluster-admin or cluster-wide write access.

It builds on:

- [Multi-Cluster Redesign](./multi-cluster-redesign.md)
- [Workload Cluster Registration Design](./workload-cluster-registration-design.md)
- [GitOps Repository and Argo CD Model](./gitops-repository-argocd-model.md)
- [Security and Credentials Boundaries](./security-credentials-boundaries.md)

This phase is design only. It does not create a namespace, RBAC resource, Argo CD Application, repository, or workload.

## 2. Current State

- `devdeploy-workload` is registered with Argo CD through the launcher-managed Secret `argocd/argocd-cluster-devdeploy-workload`.
- The selected API endpoint is `https://devdeploy-workload-control-plane:6443` using strategy `docker_network_control_plane`.
- The registration identity is `kube-system/devdeploy-argocd-manager`.
- Registration RBAC is `scoped-read-only-registration`.
- Argo CD can discover the cluster but cannot create or update user workloads.
- Workload write RBAC is intentionally absent.
- The Argo CD Application count is `0` at the time of this design.
- Platform bootstrap remains `partial` until deployment permissions, GitOps source configuration, and the parent Application are implemented.

Registration visibility and deployment authorization are separate capabilities. A healthy registration must not imply that Argo CD has workload write access.

## 3. V1 Namespace Strategy

### Decision

V1 uses one Launcher-owned namespace:

```text
devdeploy-apps
```

All GitOps-managed user workloads target this namespace initially.

This boundary:

- Avoids cluster-wide write access.
- Separates user workloads from management platform components.
- Gives local reset and troubleshooting a deterministic scope.
- Simplifies initial RBAC, status, and lifecycle verification.
- Leaves a clear migration path to per-application namespaces.

The Launcher owns namespace creation and lifecycle. Argo CD does not receive permission to create, update, patch, or delete namespaces in V1.

### Future per-application namespaces

A later model may use names such as:

```text
devdeploy-app-<app-name>
```

That model provides stronger isolation and cleaner per-app ownership, but requires dynamic namespace creation, namespace lifecycle policy, per-app RoleBindings, collision handling, cleanup rules, and an explicit ownership model in the backend and UI. These concerns are postponed from V1.

## 4. V1 RBAC Model

The existing ServiceAccount remains the Argo CD workload identity:

```text
kube-system/devdeploy-argocd-manager
```

Phase 2H.2 implements a namespaced Role and RoleBinding in `devdeploy-apps`:

```text
Role:        devdeploy-argocd-deployer
RoleBinding: devdeploy-argocd-deployer
```

The RoleBinding references the existing ServiceAccount across namespaces. The existing read-only registration ClusterRole and ClusterRoleBinding remain separate and unchanged.

### Write permissions

The implemented Role permits `get`, `list`, `watch`, `create`, `update`, `patch`, and `delete` for:

| API group | Resources | Purpose |
| --- | --- | --- |
| Core (`""`) | `configmaps`, `secrets`, `services`, `serviceaccounts`, `persistentvolumeclaims` | Application configuration, credentials references, networking, workload identities, and namespaced storage claims |
| `apps` | `deployments`, `statefulsets`, `daemonsets` | V1 workload controllers |
| `networking.k8s.io` | `ingresses` | Local workload ingress |
| `batch` | `jobs`, `cronjobs` | Batch workloads |
| `autoscaling` | `horizontalpodautoscalers` | Namespaced workload autoscaling |
| `policy` | `poddisruptionbudgets` | Namespaced availability policy |

Secret access is confined to `devdeploy-apps`. Secret values must never be copied into Launcher status or logs. Git remains unsuitable for raw secret values; a separate workload-secret delivery model is still required for sensitive production-style inputs.

### Namespace read permissions

Argo CD discovery and comparison require visibility across namespaced resource types, including APIs that may be introduced by Kubernetes or installed extensions. Maintaining a specific read list caused repeated comparison failures as additional resources were discovered. The Role therefore permits `get`, `list`, and `watch` for all API groups and resources within `devdeploy-apps`:

```yaml
- apiGroups: ["*"]
  resources: ["*"]
  verbs: ["get", "list", "watch"]
```

Because this is a namespaced Role and RoleBinding, the wildcard does not grant access to cluster-scoped resources or other namespaces. It also grants no write verb. Resources such as `resourceclaims`, `resourcequotas`, `limitranges`, `replicationcontrollers`, pods, events, and replicasets are readable for cache, comparison, and health evaluation but are not writable unless they also appear in the explicit workload write allowlist above.

### Explicitly prohibited permissions

V1 does not grant Argo CD permission to manage:

- Namespaces.
- Roles, RoleBindings, ClusterRoles, or ClusterRoleBindings.
- CustomResourceDefinitions.
- Nodes, storage classes, admission policies, or Pod Security configuration.
- Cluster-scoped resources generally.
- Any resource outside `devdeploy-apps` through a workload write binding.

Cluster-admin, wildcard write verbs, and cluster-wide wildcard grants are prohibited.

## 5. Namespace and Registration Secret Ownership

The Launcher owns:

- Namespace `devdeploy-apps`.
- Role `devdeploy-apps/devdeploy-argocd-deployer`.
- RoleBinding `devdeploy-apps/devdeploy-argocd-deployer`.

Argo CD owns only resources declared by the GitOps source inside `devdeploy-apps`. Once this model is implemented, generated GitOps content must not include a Namespace manifest because namespace ownership belongs to the Launcher.

The current Argo CD cluster Secret restricts reconciliation to `devdeploy-workloads`. Granting V1 permissions therefore requires a minimal scope update to that Secret:

```text
namespaces: devdeploy-apps
clusterResources: "false"
```

This is the only registration Secret change expected from the future permission-grant mode. Endpoint, CA, bearer token, and other credential fields remain unchanged unless a separate registration repair is explicitly requested.

## 6. Future Launcher Modes

### `-GrantWorkloadDeployPermissions`

This explicit mutating mode will:

1. Verify both clusters and the existing Argo CD registration.
2. Create or verify namespace `devdeploy-apps` in `devdeploy-workload`.
3. Create or update the namespaced Role with the reviewed V1 rules.
4. Create or update the RoleBinding to `kube-system/devdeploy-argocd-manager`.
5. Update only the Argo CD cluster Secret namespace scope when it still targets `devdeploy-workloads`.
6. Verify namespace-wide reads and allowed writes in `devdeploy-apps` through `kubectl auth can-i` checks.
7. Verify writes to read-only resources remain denied.
8. Verify equivalent writes remain denied in representative namespaces outside `devdeploy-apps`.
9. Write sanitized status without credential or Secret values.

The mode must be idempotent. It must not create an Argo CD Application, Git repository, workload, cluster-scoped write binding, or cluster-admin grant.

### `-VerifyWorkloadDeployPermissions`

Phase 2H.3 implements this strict read-only mode. It:

1. Verify namespace, Role, and RoleBinding metadata.
2. Verifies the RoleBinding subject and Role reference.
3. Verifies the ServiceAccount has namespace-wide read access and can perform expected allowlisted workload writes in `devdeploy-apps`.
4. Verifies Role, RoleBinding, ClusterRole, ClusterRoleBinding, CRD, namespace, and representative outside-namespace writes remain denied.
5. Verifies effective cluster-admin access is absent.
6. Reports the current Application count without requiring it to be zero after applications exist.
7. Writes only sanitized status.

Authorization checks must use `kubectl auth can-i` or equivalent review APIs. Verification must not create test resources.

## 7. Status Contract

Launcher status will add:

```text
platform_bootstrap.components.workload_deploy_permissions
```

Suggested shape:

```json
{
  "granted": false,
  "ready": false,
  "target_cluster": "devdeploy-workload",
  "target_context": "kind-devdeploy-workload",
  "managed_namespace": "devdeploy-apps",
  "service_account_namespace": "kube-system",
  "service_account_name": "devdeploy-argocd-manager",
  "rbac_scope": "namespace",
  "role_name": "devdeploy-argocd-deployer",
  "role_binding_name": "devdeploy-argocd-deployer",
  "cluster_admin": false,
  "read_scope": "namespace-read-all",
  "write_scope": "namespace-workload-allowlist",
  "can_read_managed_namespace_resources": true,
  "read_resource_groups": ["*"],
  "read_resources_summary": ["*"],
  "write_resource_groups": ["", "apps", "networking.k8s.io", "batch", "autoscaling", "policy"],
  "allowed_resources_summary": [
    "read:*",
    "write:services",
    "write:configmaps",
    "write:secrets",
    "write:serviceaccounts",
    "write:persistentvolumeclaims",
    "write:deployments",
    "write:statefulsets",
    "write:daemonsets",
    "write:ingresses",
    "write:jobs",
    "write:cronjobs",
    "write:horizontalpodautoscalers",
    "write:poddisruptionbudgets"
  ],
  "can_write_managed_namespace": null,
  "can_write_outside_managed_namespace": null,
  "can_manage_rbac": null,
  "can_manage_crds": null,
  "can_manage_namespaces": null,
  "status": "not_started",
  "message": "Workload deployment permissions have not been granted.",
  "checked_at": "<ISO-8601 timestamp>"
}
```

Stable status values should be `not_started`, `ready`, `warning`, and `error`. A successful grant requires `cluster_admin: false`, managed-namespace writes allowed, and representative outside-namespace writes denied.

Status and logs may contain resource names, API groups, verbs, and boolean authorization results. They must not contain bearer tokens, CA data, certificates, private keys, Secret values, or serialized cluster Secret configuration.

## 8. GitOps Application Compatibility

The upcoming parent Application will use:

```text
cluster:   devdeploy-workload
namespace: devdeploy-apps
```

Its initial source may be organized under:

```text
workloads/devdeploy-apps/
```

The initial model may use one parent Application for all V1 workloads. The namespace boundary does not prevent a future App of Apps design: later per-app Applications can target dedicated namespaces after Launcher-managed namespace and RoleBinding lifecycle support exists.

Repository updates remain separate from cluster authorization. GitHub Actions may generate, validate, and update Git state according to repository policy, but must not apply resources directly. Argo CD remains the only normal workload applier.

## 9. Security Boundaries

- Never grant cluster-admin for workload deployment.
- Never grant cluster-wide workload read or write access in V1.
- Never allow Argo CD to manage Kubernetes RBAC resources or CRDs in V1.
- Never allow Argo CD to create or delete namespaces in V1.
- Never print or persist bearer tokens, certificates, private keys, CA data, or Secret values outside Kubernetes Secrets.
- Keep registration/read visibility separate from deployment/write permission.
- Keep namespace bootstrap and RBAC reconciliation as explicit Launcher operations.
- Keep backend and GitHub Actions outside direct Kubernetes workload mutation.
- Keep Argo CD as the only normal user workload applier.

## 10. Failure and Recovery Rules

- If namespace creation succeeds but RBAC reconciliation fails, report partial state and retry idempotently; do not delete the namespace automatically.
- If the Role differs from the reviewed contract, fail closed and report the rule mismatch without dumping credentials or Secret values.
- If outside-namespace writes are allowed, mark status `error` and stop before parent Application creation.
- If the cluster Secret scope update fails, keep platform status `partial` and do not create the parent Application.
- Permission revocation or namespace reset must be a separate explicit future operation.
- Never repair a permission failure by adding cluster-admin, wildcard write verbs, or cluster-wide wildcard grants.

## 11. Non-Goals

- No Launcher implementation in this phase.
- No Kubernetes mutation or RBAC creation.
- No namespace creation.
- No Argo CD Application creation.
- No GitHub or GitOps repository creation.
- No user workload deployment.
- No per-app namespace lifecycle.
- No external-cluster permission model.

## 12. Implementation Sequence

1. **Completed in Phase 2H.2:** implement `-GrantWorkloadDeployPermissions` with deterministic namespace, Role, RoleBinding, cluster Secret scope reconciliation, and authorization boundary checks.
2. **Completed in Phase 2H.3:** implement `-VerifyWorkloadDeployPermissions` as strict read-only metadata and authorization verification.
3. Validate managed-namespace writes and outside-namespace denial without creating test resources.
4. Define the GitOps source migration to `devdeploy-apps` and remove Namespace ownership from generated workload content.
5. Configure repository access and create the parent Application only after permission verification is `ready`.
