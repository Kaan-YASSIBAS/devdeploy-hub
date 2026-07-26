# Pre-Setup Wizard Hardening Checklist

Date: 2026-07-26

This checklist records the stable DevDeploy Hub baseline before Local Bootstrap, Launcher, and Setup Wizard work begins. It is intended as a regression guardrail, not as a new product feature plan.

## Stable Baseline

- GitOps create works.
- GitOps update/edit works.
- GitOps destroy/delete works.
- Argo CD Root Application remains `Synced` / `Healthy`.
- Web preview works through DevDeploy-owned preview routes and pod port-forward transport.
- `podinfo` remains running as the persistent preview smoke app.
- `nginx` is used for temporary create/delete/image-update smoke tests and is not expected to remain after cleanup.
- CI is green.

## Guardrails

- GitOps create must not dirty the local `gitops/workloads/devdeploy-apps` tree during normal application code changes.
- GitOps update must update only the intended app manifest directory.
- GitOps destroy must remove the app from Git and allow Argo CD pruning to remove runtime `Deployment`, `Service`, and `Pod` resources.
- Runtime-only resources must not be counted as managed product records.
- `ServiceDefinition` records remain active while at least one active deployment uses them.
- `ServiceDefinition` records are archived when the final active deployment is destroyed.
- Recreate/recover reactivates an archived `ServiceDefinition` safely.
- Deployment update preserves `service_definition_id`.
- Deployment name / `app_name` remains immutable in update v1.
- No-change updates must not create unnecessary GitOps commits.
- Preview path validation must remain consistent between create and update.
- Preview routes must not expose the main user JWT.
- Preview routes must not forward DevDeploy `Authorization`, `Cookie`, or `X-DevDeploy-*` headers upstream.
- Preview CORS must remain scoped to preview routes.
- Preview port-forward RBAC must remain minimal and limited to required read/port-forward access.
- Frontend edit actions remain separate from destructive actions.
- Frontend create/update/delete progress must not show false failure while Argo CD is still reconciling.

## Out Of Scope For This Hardening Phase

- Setup Wizard implementation.
- Launcher or installer implementation.
- Authentication redesign.
- Broader Kubernetes RBAC.
- Manual runtime patching of workload resources.
- GitOps repository structure changes.
- Environment variables, secrets/configmaps, volumes, ingress, rollback, or multi-container features.
- Frontend architecture rewrites.

## Smoke Expectations

`podinfo` is the persistent preview/runtime smoke app:

- `deployment.apps/podinfo`
- `service/podinfo`
- one running `podinfo-*` pod

`nginx` is the disposable cleanup smoke app:

- create and wait for readiness
- optionally update image
- destroy/delete through DevDeploy
- verify GitOps cleanup, Argo CD `Synced` / `Healthy`, and no remaining nginx runtime resources
