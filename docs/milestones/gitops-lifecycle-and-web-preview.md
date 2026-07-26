# GitOps Lifecycle and Web Preview Milestone

Date: 2026-07-26

DevDeploy Hub has reached a stable GitOps lifecycle and web preview milestone. The validated baseline now supports UI/API-driven GitOps deployment creation, deployment destroy cleanup through Argo CD pruning, product-domain service archiving/reactivation, and backend-owned app preview for HTTP workloads.

## What Was Completed

- GitOps deployment create flow works for user-provided container images.
- GitOps deployment delete/destroy flow removes desired manifests and prunes workload resources.
- Argo CD Root Application remains `Synced` and `Healthy` after create and destroy operations.
- Destroy cleanup removes workload `Deployment`, `Service`, and `Pod` resources without manual `kubectl delete`.
- `ServiceDefinition` records are archived when their last deployment is destroyed and reactivated safely on recreate.
- Kubernetes client token refresh handling was fixed earlier so platform health does not regress to false authentication failures.
- Web preview works through DevDeploy backend-owned preview routes and pod port-forward transport.
- `podinfo` preview was validated in a real browser.
- `nginx` create/delete smoke testing passed.
- CI is green.

## Current Validated Flows

- Create `nginx`, wait for healthy runtime, then delete it and confirm cleanup.
- Create `podinfo`, open backend-owned preview, and confirm the browser UI renders.
- Delete and recreate workloads without leaving stale active deployment records.
- Recover product-domain service identity by reactivating archived service definitions when a deployment is recreated.

## Preview Security Model

- Preview URLs are DevDeploy backend routes, not ClusterIP or arbitrary upstream URLs.
- Preview uses pod port-forward transport to the owned workload pod.
- Preview sessions are deployment-scoped and short-lived.
- The main DevDeploy user JWT is not exposed to workload apps.
- DevDeploy `Cookie` and `Authorization` headers are not forwarded upstream.
- Preview runtime authentication is scoped to preview routes.
- Workload RBAC remains minimal and only allows the required read/port-forward access.

## Persistent Smoke App

`podinfo` is intentionally kept running as a persistent preview smoke app. Because of this, `devdeploy-apps` is no longer expected to be empty after the milestone.

Expected namespace state:

- `deployment.apps/podinfo`
- `service/podinfo`
- one running `podinfo-*` pod

`nginx` remains the create/delete cleanup smoke workload. `podinfo` remains the preview/runtime smoke workload.

## Smoke Test Checklist: nginx

- Create `nginx` with image `nginx:latest`.
- Confirm the deployment becomes ready.
- Confirm the service is created.
- Delete/destroy the deployment through DevDeploy.
- Confirm Git no longer references the app.
- Confirm Argo CD Root Application returns `Synced` / `Healthy`.
- Confirm `nginx` `Deployment`, `Service`, and `Pod` are gone.

## Smoke Test Checklist: podinfo

- Create or keep `podinfo` with image `ghcr.io/stefanprodan/podinfo:latest`.
- Confirm the deployment becomes ready.
- Confirm the service is created.
- Open DevDeploy web preview.
- Confirm the browser UI renders.
- Confirm runtime requests route through `/api/v1/deployment-records/{id}/preview/...`.
- Confirm preview does not expose the main user JWT or forward DevDeploy auth headers upstream.
- Leave `podinfo` running as the persistent preview smoke app unless a later phase changes the baseline.

## Expected Baseline State

- Argo CD Root Application: `Synced` / `Healthy`.
- `devdeploy-apps` namespace contains the persistent `podinfo` smoke app.
- No `nginx` smoke workload remains after cleanup testing.
- CI is green.
- GitOps workload manifests are not changed by this documentation note.

## Next Phases

Next: Deployment update/edit flow.

After that: Setup Wizard / first-run platform setup.