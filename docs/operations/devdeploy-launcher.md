# DevDeploy Launcher Preflight

This document explains the DevDeploy Launcher skeleton for Windows PowerShell.

The launcher writes sanitized structured status for future backend and Setup Wizard integration. Default preflight mode and kind config preview mode are read-only. Management cluster creation happens only when `-CreateManagementCluster` is explicitly passed. Workload cluster creation happens only when `-CreateWorkloadCluster` is explicitly passed. Management ingress, PostgreSQL, and Argo CD bootstrap happen only through their explicit switches. Local frontend image build and management-cluster image load happen only when `-BuildManagementFrontendImage` or `-LoadManagementFrontendImage` is explicitly passed.

## Run The Preflight

From the repository root:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\launcher\devdeploy-launcher.ps1
```

To keep console output minimal:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\launcher\devdeploy-launcher.ps1 -Quiet
```

This is the default read-only preflight mode. It checks the host and writes status, but it does not generate cluster configs unless requested.

## Configure A Local GitOps Repository Path

To explicitly initialize or verify the local MVP GitOps source structure:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\launcher\devdeploy-launcher.ps1 -ConfigureGitOpsRepository
```

The default repository path is the current DevDeploy repository root. An explicit Git worktree root, sanitized repository URL, and branch may be supplied:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\launcher\devdeploy-launcher.ps1 `
  -ConfigureGitOpsRepository `
  -GitOpsRepoPath "C:\path\to\gitops-repo" `
  -GitOpsRepoUrl "https://github.com/example/devdeploy-gitops.git" `
  -GitOpsBranch "main"
```

The mode requires a readable existing Git worktree. It creates or verifies:

```text
gitops/
  workloads/
    devdeploy-apps/
      kustomization.yaml
      apps/
        .gitkeep
```

The initial kustomization contains `resources: []` when there are no app directories. Existing app directories are preserved. A structurally valid existing root kustomization is also preserved; an empty or incomplete file is repaired deterministically from existing app directory names.

The launcher performs required structural validation itself. If `kubectl` is available, it also attempts a read-only `kubectl kustomize` render. That render is optional for local-path initialization and is reported as a warning rather than a false repository failure when the external process cannot access the selected path.

This first implementation uses `provider: local_path` to validate the directory and status contracts before GitHub API integration. The product target remains Setup Wizard-managed GitHub authorization with create-new and existing-repository choices.

This mode does not:

- Create or connect an Argo CD Application or AppProject.
- Create a GitHub repository or call the GitHub API.
- Add a GitHub Actions workflow.
- Commit or push generated files.
- Generate a sample application.
- Deploy or delete a workload.
- Build or load an image.
- Run database migrations.
- Run Helm.
- Mutate either kind cluster.

## Bootstrap The GitOps Root Application

After local GitOps repository configuration, workload registration, and namespace-scoped deploy permission verification are ready, explicitly create or reconcile the first Root Application:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\launcher\devdeploy-launcher.ps1 -BootstrapGitOpsRootApplication
```

This guarded mode reconciles exactly one resource in `devdeploy-mgmt`:

```text
Application argocd/devdeploy-workloads-root
```

The Application contract is:

- Repository URL: sanitized URL from `platform_bootstrap.components.gitops_repository`.
- Revision: `main`.
- Source path: `gitops/workloads/devdeploy-apps`.
- Destination server: `https://devdeploy-workload-control-plane:6443`.
- Destination namespace: `devdeploy-apps`.
- Project: `default`.
- Automated sync: enabled.
- `prune: false`.
- `selfHeal: true`.
- `CreateNamespace=false`.

Before applying the Application, the launcher verifies both clusters, management Argo CD, the registered workload cluster Secret, namespace-scoped deployment permissions, the configured repository URL, the empty GitOps source path, and the existing destination namespace. It captures Deployment, Service, and Ingress inventory before and after reconciliation and fails if unexpected workload objects appear.

The current empty source contains only `kustomization.yaml` and `apps/.gitkeep`, so this phase creates no user workload. The launcher does not create a Namespace, AppProject, repository credential, GitHub repository, workflow, image, database resource, or sample application.

A public repository can be read without an Argo CD repository credential. A private repository may leave the Application in an unknown or error sync state until a separately reviewed credential mechanism is added. The Application can still be reported as present with `status: warning`; tokens and provider error payloads are never copied into launcher status.

## Verify The GitOps Root Application

After bootstrap, run the strict read-only verifier:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\launcher\devdeploy-launcher.ps1 -VerifyGitOpsRootApplication
```

This mode reads the existing `argocd/devdeploy-workloads-root` Application as JSON and verifies its identity, unique expected-Application count, project, source, destination, automated sync settings, sync status, and health status. It also reads `devdeploy-apps` and requires the empty-root baseline to contain zero Deployments, Services, and Ingresses.

The verifier uses explicit contexts and `kubectl get` only. It does not read the current kubectl context, call GitHub, inspect repository credentials, run Helm, reconcile RBAC or namespaces, apply an Application, or modify either cluster. A missing Application or workload namespace produces a sanitized failed verification result without attempting repair.

Results are written to the normal launcher status file:

```text
.devdeploy/local/status/launcher-status.json
```

The component `platform_bootstrap.components.gitops_root_application` includes `mode: verify`, `verified`, source and destination match booleans, sync-policy booleans, `synced`, `healthy`, and a sanitized `actual` object. Its nested `workload_namespace` object reports namespace presence and Deployment, Service, and Ingress counts. Successful verification keeps `platform_bootstrap.status: partial` because the user workload flow remains intentionally unvalidated.

This empty-root result is the required baseline before the [GitOps Workload Manifest Design](../architecture/gitops-workload-manifest-design.md) introduces app folders in later Phase 2J steps.

## Generate Kind Config Previews

To run preflight and generate deterministic kind config previews:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\launcher\devdeploy-launcher.ps1 -GenerateKindConfigs
```

The generated preview files are written to:

```text
.devdeploy/local/kind/devdeploy-mgmt.yaml
.devdeploy/local/kind/devdeploy-workload.yaml
```

These files are local runtime previews under `.devdeploy/`. They are intentionally not committed.

Preview mode still does not:

- Create kind clusters.
- Delete kind clusters.
- Install ingress-nginx.
- Install Argo CD.
- Run `kubectl apply`.
- Run `kubectl delete`.
- Install Helm charts.

## Create Or Verify The Management Cluster

To explicitly create or verify only the management cluster:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\launcher\devdeploy-launcher.ps1 -CreateManagementCluster
```

This guarded mode:

- Runs the preflight checks.
- Generates or verifies `.devdeploy/local/kind/devdeploy-mgmt.yaml`.
- Creates `devdeploy-mgmt` only if it does not already exist.
- Verifies `devdeploy-mgmt` with safe read-only checks.
- Does not recreate an existing `devdeploy-mgmt` cluster.
- Does not delete clusters.
- Does not create `devdeploy-workload`.
- Does not install ingress-nginx.
- Does not install Argo CD.
- Does not deploy DevDeploy backend, frontend, or PostgreSQL.
- Does not run `kubectl apply`.
- Does not run `kubectl delete`.
- Does not run `helm install`.

Manual verification commands:

```powershell
kind get clusters
kubectl config get-contexts
kubectl --context kind-devdeploy-mgmt get nodes
```

If required preflight checks fail, the launcher does not create the cluster. If creation fails, the launcher records a failed status and does not perform automatic cleanup.

## Create Or Verify The Workload Cluster

To explicitly create or verify only the workload cluster:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\launcher\devdeploy-launcher.ps1 -CreateWorkloadCluster
```

This guarded mode:

- Runs the preflight checks.
- Generates or verifies `.devdeploy/local/kind/devdeploy-workload.yaml`.
- Creates `devdeploy-workload` only if it does not already exist.
- Verifies `devdeploy-workload` with safe read-only checks.
- Does not recreate an existing `devdeploy-workload` cluster.
- Does not modify or recreate `devdeploy-mgmt`.
- Does not delete clusters.
- Does not install ingress-nginx.
- Does not install Argo CD.
- Does not configure Argo CD cluster access.
- Does not deploy DevDeploy backend, frontend, PostgreSQL, or user workloads.
- Does not run `kubectl apply`.
- Does not run `kubectl delete`.
- Does not run `helm install`.

Manual verification commands:

```powershell
kind get clusters
kubectl --context kind-devdeploy-workload get nodes
```

If required preflight checks fail, the launcher does not create the workload cluster. If creation fails, the launcher records a failed status and does not perform automatic cleanup.

## Bootstrap Management Ingress

To explicitly install or verify only management ingress-nginx in `devdeploy-mgmt`:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\launcher\devdeploy-launcher.ps1 -BootstrapManagementIngress
```

This is the first explicit platform bootstrap mode. It:

- Runs the preflight checks.
- Verifies `devdeploy-mgmt` is Ready.
- Uses Helm only in this explicit mode.
- Installs or verifies the pinned `ingress-nginx` Helm chart in `devdeploy-mgmt`.
- Uses namespace `ingress-nginx`.
- Uses release name `ingress-nginx`.
- Configures ingress-nginx for local kind host port mappings.
- Waits for the ingress-nginx controller to become Ready.
- Writes `platform_bootstrap.components.ingress_nginx` status.

This mode does not:

- Install Argo CD.
- Install PostgreSQL.
- Deploy DevDeploy backend.
- Deploy DevDeploy frontend.
- Register `devdeploy-workload` in Argo CD.
- Install anything into `devdeploy-workload`.
- Create user workloads.
- Run `kubectl apply`.
- Run `kubectl delete`.
- Run `helm install` outside this explicit mode.
- Delete clusters or perform destructive cleanup.

Manual verification commands:

```powershell
kubectl --context kind-devdeploy-mgmt get ns
kubectl --context kind-devdeploy-mgmt get pods -n ingress-nginx
kubectl --context kind-devdeploy-mgmt get svc -n ingress-nginx
helm --kube-context kind-devdeploy-mgmt list -n ingress-nginx
```

`http://devdeploy.localhost:8080` may still not serve the DevDeploy UI after this step. The frontend and backend are not installed by management ingress bootstrap.

## Bootstrap Management PostgreSQL

To explicitly create or verify the DevDeploy platform namespace and install or verify PostgreSQL only in `devdeploy-mgmt`:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\launcher\devdeploy-launcher.ps1 -BootstrapManagementPostgres
```

This explicit platform bootstrap mode:

- Runs the preflight checks.
- Verifies `devdeploy-mgmt` is Ready.
- Creates or verifies namespace `devdeploy` in `devdeploy-mgmt`.
- Uses Helm only in this explicit mode.
- Installs or verifies the pinned Bitnami PostgreSQL chart in namespace `devdeploy`.
- Uses release name `devdeploy-postgres`.
- Configures local development database values:
  - database: `devdeploy`
  - username: `devdeploy`
  - persistence: disabled
- Waits for the PostgreSQL StatefulSet to become Ready.
- Verifies the PostgreSQL service exists.
- Writes `platform_bootstrap.components.postgres` status.

This mode does not:

- Install DevDeploy backend.
- Install DevDeploy frontend.
- Install Argo CD.
- Register `devdeploy-workload` in Argo CD.
- Install anything into `devdeploy-workload`.
- Create user workloads.
- Run `kubectl apply`.
- Run `kubectl delete`.
- Delete clusters or perform destructive cleanup.

Manual verification commands:

```powershell
kubectl --context kind-devdeploy-mgmt get ns devdeploy
kubectl --context kind-devdeploy-mgmt get pods -n devdeploy
kubectl --context kind-devdeploy-mgmt get svc -n devdeploy
helm --kube-context kind-devdeploy-mgmt list -n devdeploy
```

The DevDeploy UI is still not available after this step because backend and frontend are not installed yet.

## Build The Management Frontend Image

To explicitly build and verify the local frontend image:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\launcher\devdeploy-launcher.ps1 -BuildManagementFrontendImage
```

This mode:

- Requires a reachable local Docker daemon.
- Verifies the frontend Dockerfile, package files, and management frontend kustomization exist.
- Builds `devdeploy-frontend:local` from the `frontend` context.
- Passes the non-secret build argument `VITE_API_BASE_URL=/api/v1`.
- Verifies the resulting image with `docker image inspect`.
- Writes `platform_bootstrap.components.frontend_image` status.

This mode does not load the image into kind, deploy frontend manifests, create or update Secrets, install Helm charts, create clusters, or mutate either DevDeploy cluster.

Manual verification:

```powershell
docker image inspect devdeploy-frontend:local --format '{{.Id}} {{.Created}}'
```

## Load The Management Frontend Image

To explicitly load the existing local frontend image into `devdeploy-mgmt`:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\launcher\devdeploy-launcher.ps1 -LoadManagementFrontendImage
```

This guarded mode verifies Docker, kind, the local image, management API reachability, and Ready-node status before running:

```text
kind load docker-image devdeploy-frontend:local --name devdeploy-mgmt
```

It updates `platform_bootstrap.components.frontend_image` with load attempt and result fields. If the local image is missing, run `-BuildManagementFrontendImage` first.

This mode does not build the image, deploy frontend manifests, run `kubectl apply` or `kubectl delete`, create or update Secrets, install Helm charts or Argo CD, create clusters, or mutate `devdeploy-workload`.

## Bootstrap The Management Frontend

To explicitly reconcile only the frontend platform manifests into `devdeploy-mgmt`:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\launcher\devdeploy-launcher.ps1 -BootstrapManagementFrontend
```

This mode verifies the management cluster, namespace, ingress-nginx, backend health, and frontend manifest resource kinds before applying only:

```text
platform/management/frontend
```

It waits for `deployment/devdeploy-frontend`, verifies the Service and hostless Ingress contracts, checks the page through a temporary Service port-forward, and attempts host ingress checks for `/` and `/api/v1/health`. Host ingress failures are reported as warnings when the rollout and in-cluster Service check are healthy.

This explicit mode is the only frontend mode that may run `kubectl apply`, and it does so only against `platform/management/frontend` in `devdeploy-mgmt`. It does not build or load images, update Secrets, apply backend manifests, run `kubectl delete`, install Helm charts or Argo CD, create clusters, or mutate `devdeploy-workload`.

## Bootstrap Management Argo CD

To explicitly install or upgrade Argo CD only in `devdeploy-mgmt`:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\launcher\devdeploy-launcher.ps1 -BootstrapManagementArgoCD
```

This guarded mode:

- Verifies Helm, kubectl, `devdeploy-mgmt`, Ready node capacity, and management ingress-nginx.
- Adds or refreshes the official `https://argoproj.github.io/argo-helm` repository.
- Installs or upgrades release `argocd` in namespace `argocd`.
- Pins chart `argo/argo-cd` to version `10.1.0`.
- Configures hostless HTTP ingress at `http://localhost:8080/argocd` using ingress class `nginx`.
- Configures Argo CD base href and root path as `/argocd` so redirects and static assets use the path prefix correctly.
- Waits for the server, repo-server, application-controller, Redis, and optional ApplicationSet workloads.
- Verifies the server Service, Ingress, local UI route, and initial admin Secret metadata.
- Writes sanitized status under `platform_bootstrap.components.argocd`.

The launcher does not read or print the Argo CD admin password. It checks only whether `argocd-initial-admin-secret` exists; Secret data is not written to console output, logs, or `launcher-status.json`.

This phase does not register `devdeploy-workload`, create Argo CD cluster Secrets or Applications, configure a GitOps repository, or deploy user workloads. Those remain separate later phases.

Manual verification:

```powershell
kubectl --context kind-devdeploy-mgmt -n argocd get pods,svc,ingress
helm --kube-context kind-devdeploy-mgmt -n argocd list
Invoke-WebRequest http://localhost:8080/argocd -UseBasicParsing
```

## Verify Management Argo CD

To run strict read-only verification of the installed Argo CD release:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\launcher\devdeploy-launcher.ps1 -VerifyManagementArgoCD
```

This mode reads only from `devdeploy-mgmt` and namespace `argocd`. It verifies the deployed Helm release and pinned chart version, core workload readiness, server Service, hostless `/argocd` Ingress, UI route, initial admin Secret metadata, and Argo CD Application count.

The resulting `platform_bootstrap.components.argocd` object uses `mode: verify` and reports `application_count`. The launcher never reads or prints the admin password or any base64 Secret data.

This mode does not run Helm install or upgrade, mutate Kubernetes resources, register `devdeploy-workload`, create cluster Secrets or Applications, configure repositories, or deploy workloads. Workload registration remains a later phase.

## Discover The Workload Cluster Endpoint

To discover which workload Kubernetes API endpoint is reachable and TLS-valid from inside `devdeploy-mgmt`:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\launcher\devdeploy-launcher.ps1 -DiscoverWorkloadClusterEndpoint
```

This explicit mode:

- Rejects the host-only kubeconfig endpoint `https://127.0.0.1:58081` for Argo CD Pod use.
- Inspects the management and workload kind control-plane Docker networks.
- Tests the shared Docker-network control-plane hostname, `host.docker.internal`, and a discovered Docker gateway when available.
- Creates only the labeled temporary Pod `devdeploy/devdeploy-endpoint-probe` in `devdeploy-mgmt`.
- Uses the workload cluster CA in memory to verify network reachability, certificate trust, and hostname identity.
- Deletes only that deterministic temporary probe Pod after the test.
- Writes sanitized results to `platform_bootstrap.components.workload_cluster_endpoint`.

The status includes the selected strategy and endpoint, candidate reachability/TLS booleans, and cleanup result. It never includes raw kubeconfig, CA content, bearer tokens, client certificates, or private keys.

This mode does not register the workload cluster, create an Argo CD cluster Secret, create workload ServiceAccounts or RBAC, create Applications, deploy workloads, or mutate `devdeploy-workload`.

## Register The Workload Cluster With Argo CD

After endpoint discovery succeeds, explicitly register `devdeploy-workload` with Argo CD in `devdeploy-mgmt`:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\launcher\devdeploy-launcher.ps1 -RegisterWorkloadClusterWithArgoCD
```

This mode consumes the fresh, TLS-verified endpoint recorded by `-DiscoverWorkloadClusterEndpoint`. It rejects the host-only `https://127.0.0.1:58081` endpoint and fails with guidance to rerun discovery when the persisted result is missing, invalid, or older than 24 hours.

For the local MVP, the launcher reconciles:

- ServiceAccount `kube-system/devdeploy-argocd-manager` in `devdeploy-workload`.
- A local-only long-lived ServiceAccount token Secret in `devdeploy-workload`.
- A read-only ClusterRole and ClusterRoleBinding for registration discovery and metadata checks. It grants no workload deployment write access.
- Cluster Secret `argocd/argocd-cluster-devdeploy-workload` in `devdeploy-mgmt`, labeled `argocd.argoproj.io/secret-type=cluster`.

The durable token is an explicit local-kind simplification. Launcher status reports it as a warning and marks credential rotation as future hardening work. The cluster Secret is restricted to the future `devdeploy-workloads` namespace with cluster-resource management disabled. Workload write permissions remain a separate future step before parent Application creation. The token, CA data, kubeconfig, client credentials, and cluster Secret config are never printed or written to status/logs.

Registration is idempotent: rerunning the mode reconciles the same named resources and reuses its own fresh persisted, TLS-verified endpoint provenance when the separate discovery component is no longer present in the latest status document. It does not create an Argo CD Application, configure a Git repository, deploy a user workload, run Helm, build/load images, or touch the backend database. The Argo CD Application count therefore remains unchanged.

## Verify Workload Cluster Registration

To verify the existing registration without reconciling any resource:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\launcher\devdeploy-launcher.ps1 -VerifyWorkloadClusterRegistration
```

This strict read-only mode uses kubectl and does not require Helm. It verifies:

- Both kind clusters and their kubectl contexts are usable.
- Management Argo CD is installed and sufficiently healthy.
- Cluster Secret `argocd/argocd-cluster-devdeploy-workload` has the expected type, label, cluster name, and non-loopback server endpoint.
- ServiceAccount `kube-system/devdeploy-argocd-manager`, its token Secret metadata, read-only ClusterRole, and ClusterRoleBinding exist.
- The identity can read registration metadata but cannot create Deployments.
- Argo CD controller visibility when current controller logs contain assignment evidence.
- The current Argo CD Application count.

Only the Secret `name` and `server` fields are decoded in memory. The verifier never reads or prints the Secret config, bearer token, CA data, client certificate, or key. If fresh endpoint-discovery provenance is unavailable, `endpoint_tls_verified` is reported as `null` rather than inventing a successful TLS check.

The mode does not run `kubectl apply`, `delete`, or `patch`; it does not run Helm install/upgrade, create Applications, grant workload write RBAC, deploy workloads, build/load images, run database migrations, or modify backend/frontend resources.

## Grant Workload Deploy Permissions

To explicitly grant Argo CD namespace-scoped workload permissions:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\launcher\devdeploy-launcher.ps1 -GrantWorkloadDeployPermissions
```

This guarded mode reconciles only:

- Launcher-owned namespace `devdeploy-apps` in `devdeploy-workload`.
- Role `devdeploy-apps/devdeploy-argocd-deployer`.
- RoleBinding `devdeploy-apps/devdeploy-argocd-deployer` to `kube-system/devdeploy-argocd-manager`.
- The non-sensitive `namespaces=devdeploy-apps` and `clusterResources=false` scope fields on the existing Argo CD cluster Secret.

The Role permits reviewed namespaced workload resources, including Deployments, StatefulSets, DaemonSets, Services, ConfigMaps, Secrets, ServiceAccounts, PVCs, Ingresses, Jobs, CronJobs, HPAs, and PodDisruptionBudgets. Pods, Events, and ReplicaSets remain read-only.

After reconciliation, the launcher uses impersonated `kubectl auth can-i` checks. It requires expected writes inside `devdeploy-apps` while confirming that RBAC resources, CRDs, namespaces, cluster role bindings, and Deployment writes in `default` remain denied. It also rejects cluster-admin or any unexpected cluster-wide binding for the registration ServiceAccount.

This mode does not create an Argo CD Application or workload, run Helm, build/load images, run database migrations, modify backend/frontend resources, rotate registration credentials, or perform broad deletion. Tokens, Secret config, certificates, keys, CA data, and Secret values are never written to status or logs.

## Verify Workload Deploy Permissions

To verify the existing namespace-scoped permission boundary without reconciling resources:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\launcher\devdeploy-launcher.ps1 -VerifyWorkloadDeployPermissions
```

This strict read-only mode verifies:

- Namespace `devdeploy-apps` exists.
- ServiceAccount `kube-system/devdeploy-argocd-manager` exists.
- Role and RoleBinding `devdeploy-argocd-deployer` exist in `devdeploy-apps`.
- The RoleBinding references the expected Role and ServiceAccount.
- Deployment, Service, Ingress, ConfigMap, and Secret writes are allowed in `devdeploy-apps`.
- Role, RoleBinding, ClusterRole, ClusterRoleBinding, CRD, namespace, and outside-namespace Deployment writes remain denied.
- Effective cluster-admin access is absent.
- The Argo CD cluster Secret remains present and the Application inventory is readable.

The mode uses only read operations and impersonated `kubectl auth can-i` reviews. It does not run `apply`, `delete`, or `patch`; create Applications or workloads; run Helm; build/load images; run database operations; or modify backend/frontend resources.

## Verify The Management Frontend

To run strict read-only verification of the deployed frontend:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\launcher\devdeploy-launcher.ps1 -VerifyManagementFrontend
```

This mode verifies the management cluster and namespace, ingress-nginx, backend health, frontend Deployment and image, Ready Pods, Service port mapping, hostless Ingress, the frontend page through a temporary port-forward, and the frontend/backend host ingress routes.

It only runs read-only Kubernetes queries, temporary port-forwarding, and HTTP requests. It does not apply, patch, delete, restart, build, load, install, or otherwise mutate platform or workload resources.

## Initialize The Management Backend Database

The management backend Deployment now runs `python -m app.db.migrate` in a hardened init container before the API container starts. It reads only `DATABASE_URL` from the existing backend Secret, applies Alembic migrations idempotently, and blocks backend startup if migration fails. Backend readiness then verifies that the current database revision matches the Alembic head at `/api/v1/health/ready`.

The launcher command below remains a developer recovery and verification fallback for an already-deployed platform; it is not required during normal platform startup.

After PostgreSQL and the backend are Ready, initialize or advance the management database schema with:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\launcher\devdeploy-launcher.ps1 -InitializeManagementBackendDatabase
```

This explicit mode verifies the management cluster, PostgreSQL, backend Pod, backend runtime Secret keys, and Alembic files before running `alembic -c /app/alembic.ini upgrade head` inside the existing backend container. It then verifies the current Alembic revision and confirms the `users` table exists without printing database credentials or table data.

The mode is idempotent for an already-current schema. It does not run `Base.metadata.create_all`, reset or drop the database, delete data, redeploy platform components, update Secrets, build or load images, install charts, create clusters, or mutate `devdeploy-workload`.

## What It Checks

The launcher checks:

- Docker CLI availability.
- Docker daemon reachability.
- kind CLI availability.
- kubectl CLI availability.
- git CLI availability.
- Helm CLI availability.
- Required localhost ports:
  - `58080`
  - `8080`
  - `8443`
  - `58081`
  - `8081`
  - `8444`
- Existing kind clusters.
- Current kubectl context, if available.

Docker, Docker daemon, kind, kubectl, and required ports are treated as blocking checks. Git and Helm are warnings in this first read-only skeleton because the script does not yet perform repository or chart bootstrap.

If a required port such as `8080` is busy before the matching DevDeploy cluster exists, the launcher exits with a failed status. Preview mode still writes deterministic kind config files so users can inspect the planned cluster configuration, but the configs cannot be used until blocking ports are freed.

After a DevDeploy cluster exists, its expected ports may already be occupied by that cluster. In that case, the launcher treats the port usage as expected instead of a blocking failure:

- `58080`, `8080`, and `8443` are expected when `devdeploy-mgmt` exists.
- `58081`, `8081`, and `8444` are expected when `devdeploy-workload` exists.

## Diagnose kind API Port Mapping Integrity

Default preflight now verifies each existing DevDeploy kind cluster through read-only Docker, kubeconfig, and Kubernetes checks. It confirms that the expected control-plane container exists and is running, `6443/tcp` is published to the fixed host API port, the kubeconfig context points to that port, and `GET /readyz` succeeds.

Cluster summaries include:

- `control_plane_container`
- `container_running`
- `api_port_published`
- `expected_api_port`
- `actual_api_port`
- `kubeconfig_reachable`
- `integrity_status`
- `recommended_action`

Integrity statuses are `ok`, `cluster_missing`, `container_missing`, `container_stopped`, `api_port_unpublished`, `api_port_mismatch`, `kubeconfig_unreachable`, `docker_unavailable`, and `unknown`. A broken management mapping is blocking for management operations. A broken workload mapping is blocking for default preflight and workload operations, but remains a warning for management-only modes that do not require the workload API.

A Docker Desktop or WSL integration failure may leave `devdeploy-mgmt-control-plane` or `devdeploy-workload-control-plane` running while `docker port <container> 6443/tcp` returns no host mapping. Symptoms include `kubectl` refusing connections to `127.0.0.1:58080` or `127.0.0.1:58081`, and `kind export kubeconfig` being unable to discover the published API server port.

Recovery is intentionally manual:

1. Run `wsl --shutdown`.
2. Fully quit Docker Desktop.
3. Restart Docker Desktop and wait until its engine is ready.
4. Rerun the launcher preflight.
5. Recreate only the affected kind cluster if `6443/tcp` is still unpublished.

The launcher does not stop Docker Desktop, delete clusters, recreate clusters, export kubeconfig, or mutate Kubernetes as part of this diagnostic.

The authenticated backend endpoint `GET /api/v1/platform/cluster-health` provides the UI with a coarse, sanitized API reachability status for both clusters. The product shell uses that status to warn when management services may be unstable or when workload runtime, untracked discovery, drift comparison, and reconcile validation may be unavailable. The backend does not inspect Docker or WSL; run launcher preflight for the detailed container and host port mapping diagnosis described above.

### Guided Recovery Plans

Launcher status always includes `management_recovery_plan` and `workload_recovery_plan`. A healthy cluster reports `required: false` with empty impact and step arrays. A missing, stopped, unreachable, or integrity-degraded cluster reports ordered guidance with:

- `required`
- `affected_cluster`
- `severity`
- `summary`
- `impact`
- `recommended_steps`
- `destructive_steps_required`
- `automatic_recovery_performed`
- `checked_at`

These plans are guidance only. The launcher prints the steps but does not execute recovery commands, stop containers, delete or recreate clusters, mutate Kubernetes, or change GitOps state.

### Plan Workload Cluster Rebootstrap

To generate a workload-only rebootstrap plan from the current read-only diagnostics:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\launcher\devdeploy-launcher.ps1 -PlanWorkloadRebootstrap
```

This mode is intentionally separate from all execution modes and cannot be combined with cluster creation, bootstrap, registration, permission, repository, or Application switches. It writes the normal sanitized status and log files, adds `workload_rebootstrap_plan` to `launcher-status.json`, and prints `PLAN ONLY - no commands were executed.`

The structured plan includes:

- Current workload status and integrity diagnosis.
- Whether management is healthy and a warning when workload-only recovery may not be sufficient.
- The management cluster, PostgreSQL, Argo CD, GitOps repository, and product records that the plan preserves.
- Non-destructive Docker Desktop and WSL recovery steps.
- A user-confirmation-required manual deletion command shown as text only.
- Existing explicit launcher modes for workload creation, endpoint discovery, Argo CD registration, and namespace-scoped permissions.
- Read-only post-rebootstrap validation and Recover, Redeploy, or Reconcile guidance.

The plan does not invoke the displayed deletion command, run `-CreateWorkloadCluster`, start or stop Docker, modify kubeconfig, mutate Kubernetes, update GitOps manifests, or synchronize Argo CD. Manual recreation may remove runtime resources from `devdeploy-workload`; it does not require recreating `devdeploy-mgmt`, and management PostgreSQL data remains outside the affected cluster.

#### Workload API Port Unpublished

Typical symptoms are:

- `docker ps` shows `devdeploy-workload-control-plane` as running.
- `docker port devdeploy-workload-control-plane 6443/tcp` returns no host mapping.
- `kubectl --context kind-devdeploy-workload get nodes` cannot reach `127.0.0.1:58081`.
- Launcher integrity reports `api_port_unpublished`.

Try non-destructive recovery first:

1. Run `wsl --shutdown`.
2. Fully quit Docker Desktop.
3. Restart Docker Desktop and wait for the engine to become ready.
4. Rerun launcher preflight.

If the mapping is still broken, recreate only `devdeploy-workload` through its explicit launcher mode and then rebootstrap workload cluster access from management and Argo CD. Do not recreate `devdeploy-mgmt` for a workload-only failure. Workload runtime resources may be lost, but DevDeploy product records in the management database and GitOps manifests remain. Managed deployments can then use Recover or Redeploy after workload access is healthy.

For a stopped workload control-plane container, the plan first suggests `docker start devdeploy-workload-control-plane`, followed by another preflight. The launcher does not run that command itself.

#### Management Cluster Warning

Management failures are more severe because `devdeploy-mgmt` hosts the frontend, backend, PostgreSQL, and Argo CD. Symptoms can include an unreachable `127.0.0.1:58080`, unavailable platform services, and failed database access. Try launcher preflight and the Docker Desktop/WSL restart sequence first. Do not recreate `devdeploy-mgmt` unless platform data is backed up or local data loss has been explicitly accepted.

Port check details include:

- `port`
- `address`
- `required`
- `expected_cluster`
- `existing_cluster_detected`
- `blocking`

## Status Output

Structured status is written to:

```text
.devdeploy/local/status/launcher-status.json
```

The status file is a stable contract intended for future backend and Setup Wizard integration.

Top-level fields:

- `schema_version`
- `contract`
- `mode`
- `generated_at`
- `launcher_version`
- `host_os`
- `shell`
- `repo_root`
- `status`
- `summary`
- `management_cluster`
- `workload_cluster`
- `platform_bootstrap`
- `checks`
- `artifacts`
- `ports`
- `next_actions`

`schema_version` is currently `"1"`.

`contract` is currently:

```text
devdeploy-launcher-status
```

`mode` is one of:

- `preflight`
- `kind_config_preview`
- `management_cluster_create`
- `workload_cluster_create`
- `management_ingress_bootstrap`
- `management_postgres_bootstrap`
- `management_frontend_image_build`
- `management_frontend_image_load`
- `management_frontend_bootstrap`
- `management_frontend_verify`
- `management_argocd_bootstrap`
- `management_argocd_verify`
- `workload_cluster_endpoint_discovery`
- `workload_cluster_argocd_registration`
- `workload_cluster_argocd_registration_verify`
- `workload_deploy_permissions_grant`
- `workload_deploy_permissions_verify`
- `gitops_repository_configure`
- `gitops_root_application_bootstrap`
- `management_backend_database_initialize`

`status` is one of:

- `ok`
- `warning`
- `failed`

Required failed checks make the overall status `failed`. Optional failed checks and warnings make the overall status `warning` unless a required check failed.

The `summary` object includes:

- `total_checks`
- `ok_checks`
- `warning_checks`
- `failed_checks`
- `required_failed_checks`
- `optional_failed_checks`
- `blocking`
- `message`

The `management_cluster` object gives backend and Setup Wizard code a stable management cluster readiness summary without parsing individual check IDs. It includes:

- `name`
- `context`
- `exists`
- `api_reachable`
- `node_ready`
- `ready_nodes`
- `total_nodes`
- `status`
- `message`
- `checked_at`

Management cluster status values are:

- `missing`: `devdeploy-mgmt` does not exist yet.
- `ready`: `devdeploy-mgmt` exists, the API is reachable, and at least one node is Ready.
- `degraded`: `devdeploy-mgmt` exists, but API or node readiness checks failed.
- `unknown`: status could not be determined safely.

The `workload_cluster` object gives backend and Setup Wizard code a stable workload cluster readiness summary without parsing individual check IDs. It includes:

- `name`
- `context`
- `exists`
- `api_reachable`
- `node_ready`
- `ready_nodes`
- `total_nodes`
- `status`
- `message`
- `checked_at`

Workload cluster status values are:

- `missing`: `devdeploy-workload` does not exist yet.
- `ready`: `devdeploy-workload` exists, the API is reachable, and at least one node is Ready.
- `degraded`: `devdeploy-workload` exists, but API or node readiness checks failed.
- `unknown`: status could not be determined safely.

The default status contract does not install platform components. Mutating operations require explicit switches. Creating `devdeploy-workload` only prepares the empty workload cluster for future bootstrap phases.

The `platform_bootstrap` object summarizes platform component bootstrap state. Its `argocd` component reports the pinned chart, release, namespace, core resource readiness, ingress host, UI access, and initial admin Secret presence without exposing credentials.

It also includes `devdeploy_namespace`, which reports whether the management `devdeploy` namespace exists.

Current component keys:

- `ingress_nginx`
- `postgres`
- `backend`
- `backend_database`
- `frontend_image`
- `frontend`
- `argocd`
- `gitops_repository`
- `gitops_root_application`

`platform_bootstrap.status` may be:

- `not_started`: no platform bootstrap component is installed or verified yet.
- `partial`: management ingress-nginx is Ready, but remaining platform components are not implemented yet.
- `degraded`: a component exists but is not fully Ready.
- `failed`: an explicit bootstrap step failed.
- `unknown`: status could not be determined safely.

Each check includes:

- `id`
- `label`
- `status`
- `message`
- `details`
- `checked_at`

Check `details` include `required: true` or `required: false` where applicable.

Stable check statuses are:

- `ok`
- `warning`
- `failed`
- `skipped`

The `ports` object includes the selected default ports:

- `management_api`: `58080`
- `management_http`: `8080`
- `management_https`: `8443`
- `workload_api`: `58081`
- `workload_http`: `8081`
- `workload_https`: `8444`

The `artifacts` object always includes:

- `status_path`
- `log_path`
- `kind_config_directory`

When `-GenerateKindConfigs` is used, it also includes:

- `management_kind_config`
- `workload_kind_config`

When `-CreateManagementCluster` is used, it includes:

- `management_kind_config`

When `-CreateWorkloadCluster` is used, it includes:

- `workload_kind_config`

When `-BootstrapManagementIngress` is used, the local status includes:

- `platform_bootstrap`
- `platform_bootstrap.components.ingress_nginx`

When `-BootstrapManagementPostgres` is used, the local status includes:

- `platform_bootstrap`
- `platform_bootstrap.devdeploy_namespace`
- `platform_bootstrap.components.postgres`

When `-DiscoverWorkloadClusterEndpoint` is used, the local status includes:

- `platform_bootstrap`
- `platform_bootstrap.components.workload_cluster_endpoint`

When `-RegisterWorkloadClusterWithArgoCD` is used, the local status includes:

- `platform_bootstrap.components.argocd_workload_cluster`

That component reports the selected endpoint strategy, cluster Secret and ServiceAccount names, RBAC mode, registration readiness, Argo CD visibility based on the cluster Secret contract, and Application count. It contains no credential material.

When `-VerifyWorkloadClusterRegistration` is used, the same component includes `mode: verify`, `service_account_present`, `write_rbac_configured`, and read-only verification results. Successful verification remains `status: warning` with `ready: true` while workload write RBAC and the parent Application are intentionally absent.

When `-GrantWorkloadDeployPermissions` is used, status includes:

- `platform_bootstrap.components.workload_deploy_permissions`

The component reports the managed namespace, Role/RoleBinding presence, separate read and write scopes, allowed resource summary, cluster-admin detection, managed/outside namespace authorization results, RBAC/CRD/namespace management boundaries, and Application count. The registration component also reports `write_rbac_configured: true` after successful grant verification.

When `-VerifyWorkloadDeployPermissions` is used, the same component reports `mode: verify`, ServiceAccount presence, RoleBinding subject/reference validity, and the current authorization boundary. Successful verification preserves `platform_bootstrap.components.argocd_workload_cluster.write_rbac_configured: true` and keeps platform status `partial` until the GitOps Application model is configured.

The namespaced Role uses `read_scope: namespace-read-all`: `get`, `list`, and `watch` cover all API groups and resources within `devdeploy-apps` so Argo CD can build its destination cache and compare discovered resource types. Its `write_scope: namespace-workload-allowlist` remains limited to the documented workload resources. Grant and verification modes explicitly confirm representative non-allowlisted writes remain denied; RBAC, CRD, namespace, cluster-wide, and outside-namespace write boundaries are unchanged.

When `-ConfigureGitOpsRepository` is used, status includes:

- `platform_bootstrap.components.gitops_repository`

The component reports `provider: local_path`, the resolved Git worktree path, sanitized repository URL, branch, fixed source path, directory and kustomization readiness, optional `kustomize_render_succeeded`, and whether GitHub credentials or integration are configured. It never contains a GitHub token or credential-bearing URL. Successful local-path configuration keeps `platform_bootstrap.status: partial` because no Root Application or workload exists yet.

When `-BootstrapGitOpsRootApplication` is used, status includes:

- `platform_bootstrap.components.gitops_root_application`

The component reports the sanitized source contract, destination, sync policy, Application presence, sync and health status, Application count, and whether any Deployment, Service, or Ingress appeared during bootstrap. `ready` describes the validated Application contract; `status` may be `warning` while repository access, destination cache access, or Argo CD reconciliation is still pending. Platform bootstrap remains `partial` until the normal user workload flow is validated.

When `-VerifyGitOpsRootApplication` is used, the same component reports strict read-only verification under `mode: verify`. It exposes pass/fail booleans for the expected Application count, source, revision, destination, project, automated sync, disabled prune and namespace creation, enabled self-heal, Synced status, Healthy status, and the empty `devdeploy-apps` workload inventory. Expected and actual repository URLs are sanitized, and no Secret, token, kubeconfig, certificate, key, or raw command payload is stored.

The `next_actions` array contains safe, non-destructive guidance. For example:

- If port `8080` is busy, it tells the user to free port `8080` before creating DevDeploy local clusters.
- If all required preflight checks pass, it suggests running `-GenerateKindConfigs`.
- If kind config previews are generated and all required checks pass, it points to the future cluster creation step.
- If `devdeploy-mgmt` is ready and `devdeploy-workload` is missing, it suggests running `-CreateWorkloadCluster`.
- If both clusters are ready, it points to the future Argo CD and platform bootstrap step.
- If management ingress-nginx is Ready, it points to future PostgreSQL, backend, frontend, and Argo CD bootstrap phases.
- If PostgreSQL is Ready, it points to future backend and frontend bootstrap phases.

## Logs

Sanitized launcher logs are written to:

```text
.devdeploy/local/logs/devdeploy-launcher.log
```

The launcher avoids printing or writing secret values. It does not print kubeconfig contents and does not store raw command output that may contain credentials.

## Local Directories

The launcher creates these local directories if they do not exist:

```text
.devdeploy/local/status
.devdeploy/local/logs
.devdeploy/local/kind
```

These paths are local launcher working directories. They are not Kubernetes manifests and are not part of the GitOps desired state.

## Read-Only Scope

Default preflight mode and kind config preview mode are read-only.

They do not:

- Create kind clusters.
- Delete kind clusters.
- Install ingress-nginx.
- Install Argo CD.
- Install Helm charts.
- Run `kubectl apply`.
- Run `kubectl delete`.
- Deploy workloads.
- Modify Kubernetes runtime resources.

`-CreateManagementCluster` may create only `devdeploy-mgmt`.

`-CreateWorkloadCluster` may create only `devdeploy-workload`.

`-BootstrapManagementIngress` may install or verify only ingress-nginx in `devdeploy-mgmt`.

`-BootstrapManagementPostgres` may create or verify only the `devdeploy` namespace and PostgreSQL in `devdeploy-mgmt`.

## Phase 2B / 2C Role

Phase 2B introduced the host-side launcher contract and kind config preview. Phase 2C adds guarded management and workload cluster creation.

The Setup Wizard and backend should eventually consume this launcher status instead of assuming that an in-cluster backend can verify host tools such as Docker, kind, kubectl, Helm, ports, kubeconfigs, or filesystem state.

Future phases may extend the launcher to:

- Register `devdeploy-workload` with Argo CD.

Normal workload deployment must remain GitOps-only:

```text
UI -> Backend -> GitHub/GitOps Repository -> Argo CD -> Workload Kubernetes Cluster
```
