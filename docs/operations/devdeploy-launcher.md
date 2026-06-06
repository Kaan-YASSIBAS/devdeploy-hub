# DevDeploy Launcher Preflight

This document explains the Phase 2B DevDeploy Launcher skeleton for Windows PowerShell.

The launcher currently performs read-only host preflight checks and writes sanitized structured status for future backend and Setup Wizard integration. It does not create clusters yet.

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

If a required port such as `8080` is busy, the launcher exits with a failed status. Preview mode still writes the deterministic kind config files so users can inspect the planned cluster configuration, but the configs cannot be used until the busy ports are freed.

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

The `next_actions` array contains safe, non-destructive guidance. For example:

- If port `8080` is busy, it tells the user to free port `8080` before creating DevDeploy local clusters.
- If all required preflight checks pass, it suggests running `-GenerateKindConfigs`.
- If kind config previews are generated and all required checks pass, it points to the future cluster creation step.

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

This first launcher version is read-only.

It does not:

- Create kind clusters.
- Delete kind clusters.
- Install ingress-nginx.
- Install Argo CD.
- Install Helm charts.
- Run `kubectl apply`.
- Run `kubectl delete`.
- Deploy workloads.
- Modify Kubernetes runtime resources.

## Phase 2B Role

Phase 2B introduces the host-side launcher contract.

The Setup Wizard and backend should eventually consume this launcher status instead of assuming that an in-cluster backend can verify host tools such as Docker, kind, kubectl, Helm, ports, kubeconfigs, or filesystem state.

Future phases may extend the launcher to:

- Create or verify `devdeploy-mgmt`.
- Create or verify `devdeploy-workload`.
- Register `devdeploy-workload` with Argo CD.

Normal workload deployment must remain GitOps-only:

```text
UI -> Backend -> GitHub/GitOps Repository -> Argo CD -> Workload Kubernetes Cluster
```
