# DevDeploy Launcher Preflight

This document explains the DevDeploy Launcher skeleton for Windows PowerShell.

The launcher writes sanitized structured status for future backend and Setup Wizard integration. Default preflight mode and kind config preview mode are read-only. Management cluster creation happens only when `-CreateManagementCluster` is explicitly passed. Workload cluster creation happens only when `-CreateWorkloadCluster` is explicitly passed. Management ingress bootstrap happens only when `-BootstrapManagementIngress` is explicitly passed. Management PostgreSQL bootstrap happens only when `-BootstrapManagementPostgres` is explicitly passed. Local frontend image build happens only when `-BuildManagementFrontendImage` is explicitly passed.

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

This status contract does not mean platform components are installed. It does not install ingress-nginx, Argo CD, DevDeploy backend, DevDeploy frontend, PostgreSQL, Helm charts, or user workloads. Creating `devdeploy-workload` only prepares the empty workload cluster for future bootstrap phases.

The `platform_bootstrap` object summarizes platform component bootstrap state. In this phase `ingress_nginx` and `postgres` can become Ready. Backend, frontend, and Argo CD remain `not_started`.

It also includes `devdeploy_namespace`, which reports whether the management `devdeploy` namespace exists.

Current component keys:

- `ingress_nginx`
- `postgres`
- `backend`
- `frontend_image`
- `frontend`
- `argocd`

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
