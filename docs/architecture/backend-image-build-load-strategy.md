# Backend Image Build and Load Strategy

## 1. Purpose

Phase 2D.7 defines how the DevDeploy backend image will be built on the host and loaded into the `devdeploy-mgmt` kind cluster before backend deployment is implemented.

This phase is documentation-only. It does not build or load an image, deploy the backend, apply Kubernetes manifests, or change Launcher behavior.

## 2. Relationship to Previous Phases

The backend bootstrap work is intentionally split into small milestones:

- Phase 2D.4 defines the backend runtime, configuration, Secret, database, Service, ingress, and health contracts.
- Phase 2D.5 defines the backend manifest repository layout and ownership strategy.
- Phase 2D.6 adds the initial backend platform manifests under `platform/management/backend` using image `devdeploy-backend:local`.
- Phase 2D.7 defines how that image will be built and made available inside the `devdeploy-mgmt` kind cluster.

Backend deployment remains a later explicit Launcher step.

## 3. Why Local Image Build and Load

DevDeploy Hub is local-first. V1 should not require users to configure an external image registry before they can start the platform.

Host Docker and kind have separate image availability boundaries:

- `docker build` creates an image in the host Docker daemon.
- A kind node cannot automatically use an arbitrary host image.
- `kind load docker-image` copies the host image into the selected kind cluster nodes.

The V1 flow therefore builds `devdeploy-backend:local` on the host and loads it into `devdeploy-mgmt` before backend manifests are deployed.

This keeps the initial setup independent of GHCR, registry credentials, and network availability after dependencies and base images are available.

## 4. Target Image Contract

| Field | Value |
| --- | --- |
| Image name | `devdeploy-backend` |
| Local tag | `local` |
| Full image reference | `devdeploy-backend:local` |
| Docker context | `./backend` |
| Dockerfile | `./backend/Dockerfile` |
| Target kind cluster | `devdeploy-mgmt` |
| Manifest reference | `platform/management/backend/deployment.yaml` |
| Pull policy | `IfNotPresent` |

The image name in the Deployment manifest and the Launcher build/load commands must remain identical. A mismatch must fail validation before backend deployment.

## 5. Manual Commands

Build the backend image from the repository root:

```powershell
docker build -t devdeploy-backend:local ./backend
```

Load the image into the management cluster:

```powershell
kind load docker-image devdeploy-backend:local --name devdeploy-mgmt
```

Render the backend manifests without applying them:

```powershell
kubectl kustomize platform/management/backend
```

Phase 2D.7 does not include `kubectl apply`. Applying the backend manifests belongs to a future explicit backend bootstrap phase.

## 6. Preflight Requirements

A future image build/load implementation should verify:

- Docker CLI exists.
- Docker daemon is running and responsive.
- kind CLI exists.
- `devdeploy-mgmt` exists.
- The `devdeploy-mgmt` API is reachable.
- At least one `devdeploy-mgmt` node is Ready.
- `backend/Dockerfile` exists.
- `backend/requirements.txt` exists.
- `backend/constraints.txt` exists.
- `platform/management/backend/deployment.yaml` exists.
- The Deployment references exactly `devdeploy-backend:local`.
- The Deployment uses `imagePullPolicy: IfNotPresent`.

Build-only mode does not need a Kubernetes cluster. Load mode requires kind and a Ready `devdeploy-mgmt` cluster.

Preflight failures must stop the requested action and return clear guidance without attempting unrelated recovery or cluster mutation.

## 7. Future Launcher Mode Design

### Build Mode

Future explicit mode:

```powershell
.\scripts\launcher\devdeploy-launcher.ps1 -BuildManagementBackendImage
```

This mode should:

1. Run Docker-specific preflight checks.
2. Verify the backend Dockerfile and dependency files exist.
3. Build `devdeploy-backend:local` from `./backend`.
4. Verify the image exists in the host Docker daemon.
5. Record sanitized build status.

It must not:

- Create or delete clusters.
- Load the image into kind unless explicitly combined by a later mode.
- Deploy backend manifests.
- Apply Kubernetes resources.
- Print build secrets or sensitive environment values.

### Load Mode

Future explicit mode:

```powershell
.\scripts\launcher\devdeploy-launcher.ps1 -LoadManagementBackendImage
```

This mode should:

1. Verify `devdeploy-backend:local` exists in the host Docker daemon.
2. Verify `devdeploy-mgmt` exists and is reachable.
3. Verify management node readiness.
4. Load the image into `devdeploy-mgmt`.
5. Verify the image is present on the target kind node where practical.
6. Record sanitized load status.

It must not:

- Build the image implicitly unless a later combined mode explicitly defines that behavior.
- Create or delete clusters.
- Deploy backend manifests.
- Apply Kubernetes resources.
- Touch `devdeploy-workload`.

A later `-BootstrapManagementBackend` mode may call these steps in order or verify they have already completed before applying backend platform resources.

## 8. Idempotency Strategy

V1 idempotency rules:

- Re-running `docker build` with tag `devdeploy-backend:local` is acceptable and replaces the local tag with the latest successful build.
- Re-running `kind load docker-image` is acceptable.
- A failed build must not remove a previously working image automatically.
- A failed load must not recreate or delete the cluster.
- Status should record the latest attempt time, result, and safe message.
- Status and logs must not contain sensitive environment values or build secrets.

V1 does not require content-addressed tags. Future versions may use immutable tags based on a Git commit SHA and keep `local` as a convenience alias.

## 9. Status Contract Proposal

Future `launcher-status.json` may add `platform_bootstrap.components.backend_image`:

```json
{
  "image": "devdeploy-backend:local",
  "dockerfile": "backend/Dockerfile",
  "context": "backend",
  "local_image_present": true,
  "loaded_to_management_cluster": true,
  "target_cluster": "devdeploy-mgmt",
  "status": "ready",
  "message": "Backend image is available locally and loaded into devdeploy-mgmt.",
  "checked_at": "2026-01-01T00:00:00Z"
}
```

Suggested status values:

- `not_started`
- `building`
- `built`
- `loading`
- `ready`
- `failed`
- `unknown`

The contract must not include:

- Build secrets.
- Environment variable values.
- Database credentials.
- JWT secrets.
- GitHub tokens.
- Registry credentials.
- Full raw command output.

## 10. Failure Modes and Messages

| Failure | Expected actionable message |
| --- | --- |
| Docker CLI missing | Install Docker Desktop or make `docker` available on `PATH`, then rerun the build mode. |
| Docker daemon unavailable | Start Docker Desktop and wait until the daemon is ready. |
| Docker build fails | Review the sanitized build error and run the documented manual build command. |
| kind CLI missing | Install kind or make `kind` available on `PATH`, then rerun load mode. |
| `devdeploy-mgmt` missing | Run `-CreateManagementCluster` before loading the backend image. |
| Management API unavailable | Verify Docker and `devdeploy-mgmt`, then rerun management cluster verification. |
| Local image missing | Run `-BuildManagementBackendImage` before load mode. |
| kind image load fails | Verify the cluster and local image, then rerun load mode; do not recreate the cluster automatically. |
| Manifest image mismatch | Update the manifest or build contract so both reference `devdeploy-backend:local`. |

Errors must be sanitized and concise. The Launcher should preserve the last safe status and should not perform automatic destructive cleanup.

## 11. CI and Security Considerations

- Do not commit built container images.
- Do not commit generated image tar files.
- Do not pass secrets through Docker build arguments.
- Build only from `backend/Dockerfile` and context `backend`.
- Preserve the non-root runtime and existing Dockerfile hardening.
- Keep backend dependency auditing separate from local image loading.
- Keep backend image vulnerability scanning as a CI responsibility.
- Do not weaken Trivy, pip-audit, or other security gates to support local loading.
- Do not expose the Docker socket to the in-cluster backend.
- Do not give GitHub Actions credentials to the local kind clusters.

The local image flow is a bootstrap convenience, not an exception to dependency or image security checks.

## 12. V1 Limitations

- Phase 2D.7 does not build the image.
- Phase 2D.7 does not load the image into kind.
- Phase 2D.7 does not deploy the backend.
- External registry support is not implemented yet.
- Git SHA image tags are not implemented yet.
- Image signing and provenance are not implemented yet.
- Automatic database migration handling is not implemented yet.
- Multi-node kind image distribution is not required for the current single-node management cluster.

## 13. Definition of Done

Phase 2D.7 is complete when:

- The backend local image name and tag contract are documented.
- Manual build and kind load commands are documented.
- Build and load preflight requirements are documented.
- Future Launcher build and load modes are documented.
- Idempotency behavior is documented.
- Failure modes and actionable messages are documented.
- The proposed image status contract is documented.
- CI and security boundaries are documented.
- No build, load, deploy, apply, Helm, or cluster mutation behavior is added.

## 14. Related Documents

- [Backend Bootstrap Preparation](./backend-bootstrap-preparation.md)
- [Backend Bootstrap Manifest Strategy](./backend-bootstrap-manifest-strategy.md)
- [Management Platform Bootstrap Plan](./management-platform-bootstrap-plan.md)
- [Bootstrapper / Launcher Design](./bootstrapper-launcher-design.md)
- [Security Boundaries and Credentials Model](./security-credentials-boundaries.md)
- [Phase 2 Implementation Roadmap](./phase-2-implementation-roadmap.md)
