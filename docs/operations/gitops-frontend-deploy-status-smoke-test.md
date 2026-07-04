# Frontend GitOps Deploy And Status Smoke Test Result

## Purpose

This document records the successful Phase 2J.6a manual verification of the Frontend GitOps Deploy Form against the real backend deploy and live read-only status APIs.

The verified path was:

```text
Frontend -> Backend GitOps API -> Git repository -> Argo CD -> devdeploy-workload
         -> Backend read-only status API -> Frontend status card
```

The frontend did not call GitHub, Argo CD, or Kubernetes directly.

## Recorded Successful Run

The test used:

- App name: `ui-status-smoke-nginx`.
- Image: `nginx:latest`.
- Replicas: `1`.
- Container port: `80`.
- Service port: `80`.
- Service type: `ClusterIP`.
- Commit: `e5d8cb791b8bfc4be35e176369f6376d59912647`.
- Commit message: `deploy: add ui-status-smoke-nginx workload`.

The GitOps commit changed:

```text
gitops/workloads/devdeploy-apps/apps/ui-status-smoke-nginx/deployment.yaml
gitops/workloads/devdeploy-apps/apps/ui-status-smoke-nginx/kustomization.yaml
gitops/workloads/devdeploy-apps/apps/ui-status-smoke-nginx/service.yaml
gitops/workloads/devdeploy-apps/kustomization.yaml
```

## Frontend Result

The Deployments page completed the workflow and displayed:

- High-level status `deployed`.
- The short commit and observed revision.
- Root Application state `Synced / Healthy`.
- Commit observed as `true`.
- Deployment replicas `1/1` with `1` available.
- Service readiness as ready.
- Pod readiness `1/1`.

This confirms that the form did not treat the initial Git push response as deployment success. It continued polling the read-only status endpoint until the backend reported the live workload as deployed.

## Read-only Verification

Manual verification used read-only Git and Kubernetes queries only. It observed:

- The Git working tree was clean after deployment.
- Local HEAD, `origin/main`, and `origin/HEAD` pointed to `deploy: add ui-status-smoke-nginx workload`.
- Argo CD Root Application `devdeploy-workloads-root` was `Synced` and `Healthy`.
- Deployment `ui-status-smoke-nginx` was ready at `1/1`.
- Service `ui-status-smoke-nginx` was a ClusterIP Service on `80/TCP`.
- One selected Pod was `Running`, ready at `1/1`, with zero restarts.

No mutation command was used for verification.

## Execution Context

The smoke test used the local frontend and local backend. The in-cluster backend does not yet have the server-side GitOps repository workspace and live status-reader configuration mounted.

The Setup Wizard gate was bypassed only through local browser onboarding state for this frontend smoke test. That bypass did not change backend state, GitOps resources, Argo CD, or either Kubernetes cluster.

No token, password, kubeconfig content, local browser storage content, or screenshot is included in this record.

## Known UI And Integration Limitations

The following gaps were observed and do not invalidate the Phase 2J.6 deploy-form result:

- The new app appears in the temporary status card during the current UI session, but the Deployments list does not rediscover it after a page refresh yet.
- Dashboard counters, Services, Deployments, Cluster, Logs, and Monitoring are not yet fully connected to the new GitOps-created workload model.
- The Cluster page may have a namespace selected other than `devdeploy-apps`.
- Prometheus and Loki are not fully configured for this path, so Monitoring and Logs may show unavailable or empty states.
- The in-cluster platform backend still needs a controlled server-side GitOps repository and status-reader configuration.

These are future integration tasks. The verified scope for this phase is the frontend form, backend GitOps publication, Argo CD reconciliation, and live read-only status presentation.

## Cleanup Limitation

The Root Application still uses `prune=false`. The smoke workload is not considered safely deleted by removing its Git files, and this procedure does not define cleanup.

The live app may remain until the separate delete and prune behavior is designed and verified.

See [GitOps API Deploy And Status Smoke Test](./gitops-api-deploy-status-smoke-test.md) for the backend API procedure and [Phase 2 Implementation Roadmap](../architecture/phase-2-implementation-roadmap.md) for follow-up work.
