# GitOps Workload Manifest Design

## 1. Purpose

This document defines how DevDeploy Hub represents user workloads in the GitOps repository for V1 UI-managed GitOps continuous delivery.

V1 accepts a user-provided container image that is already available to the workload cluster. DevDeploy Hub later generates reviewed Kubernetes manifests, updates Git, and lets Argo CD reconcile those manifests into `devdeploy-workload`.

The normal workload path remains:

```text
UI -> Backend -> GitOps Repository -> Argo CD -> devdeploy-workload
```

The backend does not directly apply normal user workloads to Kubernetes.

This document extends the repository and Argo CD decisions in:

- [Multi-Cluster Redesign](./multi-cluster-redesign.md)
- [GitOps Repository Layout and Argo CD Application Model](./gitops-repository-argocd-model.md)
- [GitOps Repository and Root Application Design](./gitops-repository-root-application-design.md)
- [GitOps Workload Permission Design](./gitops-workload-permission-design.md)

## 2. Scope

### In scope for V1

- A user-provided container image.
- One Kubernetes Deployment per app.
- One Kubernetes Service per app.
- An optional Kubernetes Ingress per app.
- One deterministic folder per app.
- Kustomize composition inside each app folder.
- Registration of app folders in the root Kustomization.

### Out of scope for V1

- CI or image builds.
- GitHub Actions workflow generation.
- Docker build logs.
- Image registry pushes.
- Automated image tag promotion.
- StatefulSets.
- PersistentVolumeClaims.
- CronJobs.
- Advanced rollout strategies.
- Canary or blue-green deployment.
- One Argo CD Application per app.
- Dedicated AppProject enforcement.

These exclusions keep V1 focused on continuous delivery of existing images rather than source-to-image automation.

## 3. Repository Layout

The V1 workload tree is:

```text
gitops/workloads/devdeploy-apps/
  kustomization.yaml
  apps/
    <app-name>/
      kustomization.yaml
      deployment.yaml
      service.yaml
      ingress.yaml
```

Rules:

- The root `kustomization.yaml` owns the deterministic list of managed app folders.
- Each app folder owns only that app's Kubernetes resources.
- `ingress.yaml` exists only when ingress is enabled.
- `apps/.gitkeep` remains valid while the app tree is empty.
- A future backend writer adds or removes app folders and updates the root Kustomization through Git commits.
- App folders must not contain platform resources for `devdeploy-mgmt`.

## 4. Naming Rules

V1 app names must be compatible with a Kubernetes DNS-1123 label:

- Use lowercase ASCII letters, numbers, and hyphens only.
- Start and end with an alphanumeric character.
- Do not use consecutive path separators, dots, underscores, spaces, or uppercase letters.
- Use a recommended maximum length of 40 characters. Kubernetes permits longer labels in some fields, but the shorter product limit reserves space for future generated suffixes.

The initial generator should use the validated app name directly for generated resource names.

Example:

```text
App name:   nginx-demo
Deployment: nginx-demo
Service:    nginx-demo
Ingress:    nginx-demo
```

Folder names and Kubernetes resource names must come from the same validated value. User input must not be used as an arbitrary filesystem path.

## 5. Namespace Model

All V1 user workloads deploy to:

```text
devdeploy-apps
```

The namespace is pre-created by the Launcher workload deploy permission phase. The Root Application uses `CreateNamespace=false`, and generated app manifests explicitly set:

```yaml
metadata:
  namespace: devdeploy-apps
```

The backend must not create namespaces in V1. App manifests must not include a Namespace resource.

## 6. Deployment Manifest Contract

A generated Deployment must include:

- `apiVersion: apps/v1`.
- `kind: Deployment`.
- The validated app name in `metadata.name`.
- `metadata.namespace: devdeploy-apps`.
- Standard DevDeploy labels.
- A configurable replica count.
- An immutable selector that matches the Pod template labels.
- One initial application container.
- The user-provided image reference.
- The configured container port.

Required labels are:

```yaml
app.kubernetes.io/name: <app-name>
app.kubernetes.io/managed-by: devdeploy
app.kubernetes.io/part-of: devdeploy-workloads
```

Basic resource requests and limits, environment variables, health probes, multiple containers, and advanced Pod settings are future extensions. They are not mandatory in the first V1 manifest contract.

Example:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx-demo
  namespace: devdeploy-apps
  labels:
    app.kubernetes.io/name: nginx-demo
    app.kubernetes.io/managed-by: devdeploy
    app.kubernetes.io/part-of: devdeploy-workloads
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: nginx-demo
  template:
    metadata:
      labels:
        app.kubernetes.io/name: nginx-demo
        app.kubernetes.io/managed-by: devdeploy
        app.kubernetes.io/part-of: devdeploy-workloads
    spec:
      containers:
        - name: nginx-demo
          image: nginx:latest
          ports:
            - name: http
              containerPort: 80
              protocol: TCP
```

The example uses `nginx:latest` to demonstrate user-provided image input. Versioned or digest-pinned images are recommended for repeatable deployments.

## 7. Service Manifest Contract

A generated Service must include:

- `apiVersion: v1`.
- `kind: Service`.
- The validated app name in `metadata.name`.
- `metadata.namespace: devdeploy-apps`.
- The standard DevDeploy labels.
- `type: ClusterIP` by default.
- A selector matching the Deployment Pod labels.
- A service port mapped to the configured container `targetPort`.

Example:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: nginx-demo
  namespace: devdeploy-apps
  labels:
    app.kubernetes.io/name: nginx-demo
    app.kubernetes.io/managed-by: devdeploy
    app.kubernetes.io/part-of: devdeploy-workloads
spec:
  type: ClusterIP
  selector:
    app.kubernetes.io/name: nginx-demo
  ports:
    - name: http
      port: 80
      targetPort: http
      protocol: TCP
```

## 8. Ingress Manifest Contract

Ingress is optional in V1. When enabled, the generated manifest must include:

- `apiVersion: networking.k8s.io/v1`.
- `kind: Ingress`.
- The validated app name in `metadata.name`.
- `metadata.namespace: devdeploy-apps`.
- The standard DevDeploy labels.
- `spec.ingressClassName: nginx`.
- Hostless, path-based routing for local-first operation.
- A recommended path of `/apps/<app-name>`.
- `pathType: Prefix`.
- A backend reference to the app Service.

Example:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: nginx-demo
  namespace: devdeploy-apps
  labels:
    app.kubernetes.io/name: nginx-demo
    app.kubernetes.io/managed-by: devdeploy
    app.kubernetes.io/part-of: devdeploy-workloads
spec:
  ingressClassName: nginx
  rules:
    - http:
        paths:
          - path: /apps/nginx-demo
            pathType: Prefix
            backend:
              service:
                name: nginx-demo
                port:
                  name: http
```

This Ingress belongs to `devdeploy-workload`. It is separate from the management ingress in `devdeploy-mgmt`. This contract does not claim that the route is currently reachable through `localhost:8080`; workload-cluster ingress installation and host exposure require a separate design and implementation step.

Applications must also be compatible with their configured path prefix. Rewrite behavior, root-path assumptions, static asset paths, redirects, and callback URLs require later validation before path exposure can be considered generally reliable.

## 9. App Kustomization Contract

Each app folder contains its own `kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - deployment.yaml
  - service.yaml
  - ingress.yaml
```

When ingress is disabled, `ingress.yaml` is not created and is omitted:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - deployment.yaml
  - service.yaml
```

The resource order should remain deterministic to reduce Git diff noise.

## 10. Root Kustomization Update Contract

The current empty root is:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources: []
```

After adding `nginx-demo`, it becomes:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - apps/nginx-demo
```

The future backend writer must update this file whenever it adds or removes an app folder. Entries must be unique, reference existing app directories, and use deterministic lexical ordering.

## 11. GitOps Operation Model

A future backend GitOps operation will:

1. Validate the app name, image reference, replica count, container port, service port, and optional ingress settings.
2. Generate the app folder and only the enabled manifests.
3. Generate the app Kustomization.
4. Update the root Kustomization deterministically.
5. Validate the resulting Kustomize tree.
6. Commit the changes according to repository policy.
7. Push the commit to the configured GitOps repository.
8. Let Argo CD detect and sync the Git change automatically.

Repository policy may later require pull requests instead of direct commits. In either case, the backend does not run `kubectl apply` for normal user workloads, and GitHub Actions do not deploy directly to either cluster.

## 12. Delete Model

The current Root Application has `prune=false`. Removing an app folder or deleting its entry from the root Kustomization can stop Argo CD from tracking that desired state, but it does not guarantee that the live Kubernetes resources are deleted.

Consequences for V1 design:

- Removing an app from Git must not be presented as a completed cluster deletion.
- A safe delete flow needs an explicit prune and ownership design before implementation.
- The product must distinguish repository removal, Argo CD reconciliation, and confirmed workload deletion.
- App deletion is out of scope for this design phase.

No automatic deletion behavior is claimed by this document.

## 13. Status and Read Model

Future backend and UI work may read:

- Root Application sync and health status from Argo CD.
- Deployment rollout and replica status from `devdeploy-workload`.
- Pod, Service, and Ingress metadata through read-only Kubernetes APIs.
- GitOps request and commit state from the platform database and configured repository provider.

This phase does not implement a status API. The current Root Application represents all V1 workloads together, so per-app Argo CD health and lifecycle history are not yet available. One Argo CD Application per app remains a future model.

## 14. Security Boundaries

- Never grant cluster-admin for workload reconciliation.
- Argo CD must not create namespaces in V1.
- Generated workload manifests must not manage Roles, RoleBindings, ClusterRoles, ClusterRoleBindings, or CustomResourceDefinitions.
- Generated examples and status must not contain Secret values, tokens, kubeconfigs, certificates, private keys, or encoded credentials.
- V1 accepts a user-provided image reference; it does not build or push images.
- Registry credential handling is a separate future security design.
- The backend must sanitize repository errors, logs, status, and generated metadata.
- Generated filesystem paths must come only from validated app names.
- Platform resources remain in `devdeploy-mgmt`; generated app resources target only `devdeploy-workload` and namespace `devdeploy-apps`.

## 15. Example Full Tree

With `nginx-demo` and ingress enabled:

```text
gitops/workloads/devdeploy-apps/
  kustomization.yaml
  apps/
    .gitkeep
    nginx-demo/
      kustomization.yaml
      deployment.yaml
      service.yaml
      ingress.yaml
```

The root Kustomization lists `apps/nginx-demo`. The app Kustomization lists `deployment.yaml`, `service.yaml`, and `ingress.yaml`. All three resources use name `nginx-demo` and namespace `devdeploy-apps`.

The `.gitkeep` file may remain because it is not a Kustomize resource and does not affect rendering.

## 16. Implementation Sequence

1. **Phase 2J.1:** define this workload manifest contract.
2. **Phase 2J.2:** generate a reviewed sample app tree using the contract.
3. **Phase 2J.3:** verify that Argo CD applies the sample workload to `devdeploy-workload`.
4. **Phase 2J.4:** design the backend GitOps commit and failure-handling flow.
5. **Phase 2J.5:** implement the backend GitOps workload writer without direct cluster mutation.

