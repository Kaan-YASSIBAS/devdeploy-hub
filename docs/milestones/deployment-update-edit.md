# Deployment Update/Edit Milestone

Date: 2026-07-26

DevDeploy Hub has completed the first deployment update/edit milestone after the GitOps lifecycle and web preview baseline. The validated system now supports editing active GitOps-managed deployments through the backend API and frontend UI while preserving GitOps as desired-state truth, database/domain records as product truth, and Kubernetes/Argo CD as runtime and reconciliation truth.

## What Was Completed

- Backend update API was added for active GitOps-managed deployment records.
- Frontend edit modal was added for supported deployment fields.
- Update progress feedback was added so users can see the update continue while Argo CD reconciles and runtime state catches up.
- GitOps manifests are updated through the managed GitOps repository flow.
- Argo CD reconciles the updated desired state.
- Existing create, destroy/delete, and web preview flows remain stable.
- CI is green.

## Backend API Summary

Update endpoint:

```text
PATCH /api/v1/deployment-records/{deployment_id}/gitops
```

Supported partial request fields:

```json
{
  "image": "nginx:alpine",
  "replicas": 1,
  "container_port": 80,
  "service_port": 80,
  "preview_path": "/"
}
```

The API supports partial updates. Omitted fields retain their existing values. No-op updates return a safe no-change response. Database/domain records are updated only after the GitOps update succeeds.

## Frontend UX Summary

- Active GitOps-managed deployments show an edit/update action separate from destructive actions.
- The edit modal pre-fills current image, replica, port, and preview path values.
- Duplicate submissions are disabled while the update is running.
- Progress remains visible while DevDeploy pushes the GitOps update, Argo CD reconciles, and runtime readiness catches up.
- After reconciliation, deployment/service/dashboard/runtime data is refreshed.
- Access and web preview continue using the updated deployment metadata.

## Supported Update Fields

- image
- replicas
- container port
- service port
- preview path

## Immutable Fields

- deployment name / `app_name`
- namespace
- `service_definition_id`

Rename is intentionally out of scope for update v1 and should be treated as a separate future feature.

## GitOps Update Behavior

- The existing managed workload directory is updated in place.
- Deployment image, replica count, and container port are updated when changed.
- Service port and target port are updated when changed.
- Preview path is stored in product metadata and used by access/preview flows.
- The GitOps repository structure is unchanged.
- Runtime Kubernetes resources are observed, not manually patched as the source of truth.

## Argo CD Reconciliation Behavior

- Argo CD Root Application remains the reconciliation point for managed workloads.
- Updates are committed and pushed to Git, then reconciled by Argo CD.
- UI progress waits for database, runtime, and reconciliation evidence before showing completion.
- The update flow does not broaden Kubernetes RBAC.

## ServiceDefinition Behavior

- `service_definition_id` is preserved during updates.
- Updating a deployment does not silently rename or replace the linked service definition.
- Service definitions remain the product-domain representation for managed services.
- Existing service archive/reactivation behavior remains unchanged for create and destroy flows.

## Preview Behavior After Updates

- Web preview continues through DevDeploy-owned backend preview routes.
- Preview path updates are reflected in future access and preview URLs.
- The main user JWT is not exposed to workload apps.
- DevDeploy `Cookie` and `Authorization` headers are not forwarded upstream.
- Preview sessions remain deployment-scoped and short-lived.

## Live Validation Results

- `podinfo` replicas were updated from `1` to `2` through the UI.
- Argo CD reconciled successfully.
- The UI showed `2/2` ready.
- `podinfo` preview still worked after the update.
- `podinfo` replicas were updated from `2` back to `1` through the UI.
- Final `podinfo` state is `1/1` Running.
- `nginx` image update test passed from `nginx:latest` to `nginx:alpine`.
- `nginx` preview still worked after the image update.
- `nginx` delete cleanup worked.

## Current Baseline State

- GitOps create works.
- GitOps destroy/delete works.
- Deployment update/edit works for the v1 supported fields.
- Argo CD Root Application remains `Synced` / `Healthy`.
- Web preview works.
- `podinfo` remains running as the persistent preview smoke app.
- `nginx` is not expected to remain after cleanup tests.
- CI is green.

## Next Phases

Next: Pre-Setup Wizard Hardening.

After that: Setup Wizard / first-run platform setup.
