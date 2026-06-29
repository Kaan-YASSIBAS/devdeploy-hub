# Backend Runtime Secret Strategy

## 1. Purpose

Phase 2D.8 defines how the real backend runtime Secret will be created or verified safely in a future explicit Launcher mode.

This phase is documentation-only. It does not create `devdeploy-backend-secret`, rotate credentials, deploy the backend, or mutate either Kubernetes cluster.

## 2. Relationship to Previous Phases

The backend bootstrap design is split into focused milestones:

- Phase 2D.4 defines backend runtime and configuration requirements.
- Phase 2D.5 defines the backend manifest layout and ownership strategy.
- Phase 2D.6 adds backend platform manifests and a non-deployable `secret.example.yaml`.
- Phase 2D.7 defines how `devdeploy-backend:local` will be built and loaded into `devdeploy-mgmt`.
- Phase 2D.8 defines how the real `devdeploy-backend-secret` will be created, preserved, and verified without exposing values.

Backend deployment remains a later explicit phase.

## 3. Secret Name and Scope

| Field | Value |
| --- | --- |
| Secret name | `devdeploy-backend-secret` |
| Namespace | `devdeploy` |
| Cluster | `devdeploy-mgmt` |
| Owner | Future explicit Launcher backend Secret/bootstrap mode |

The Secret:

- Is a management platform resource.
- Is not intended for `devdeploy-workload`.
- Must not be committed to Git.
- Must not be created or managed by GitHub Actions.
- Must not be printed in logs.
- Must not be written to `launcher-status.json`.
- Must not be included in Kustomize resources as real plaintext data.

## 4. Required Secret Keys

The backend Deployment expects:

- `DATABASE_URL`
- `JWT_SECRET_KEY`
- `GITHUB_WORKFLOW_TOKEN`

Key behavior:

### `DATABASE_URL`

Required for backend startup. It must point to the PostgreSQL service in `devdeploy-mgmt` and include the runtime PostgreSQL password.

### `JWT_SECRET_KEY`

Required for token creation and validation. It must contain at least 32 characters and should be generated using a cryptographically secure random source.

### `GITHUB_WORKFLOW_TOKEN`

Optional while `GITOPS_ENABLED=false`. It may be empty or omitted until GitHub workflow dispatch is enabled. When configured, it must be handled as a credential.

## 5. PostgreSQL Password Source Strategy

The preferred V1 strategy is to read the PostgreSQL password from the existing Kubernetes Secret created by the Bitnami PostgreSQL Helm release during Phase 2D.3.

The future Launcher should not ask the user to re-enter the password when it can safely read the existing release Secret.

The Launcher should build `DATABASE_URL` from:

- Username: `devdeploy`
- Password: value read from the PostgreSQL release Secret
- Host: `devdeploy-postgres-postgresql.devdeploy.svc.cluster.local`
- Port: `5432`
- Database: `devdeploy`

Resulting shape:

```text
postgresql://devdeploy:<POSTGRES_PASSWORD>@devdeploy-postgres-postgresql.devdeploy.svc.cluster.local:5432/devdeploy
```

The release-related Secret is likely named `devdeploy-postgres-postgresql` or a chart-generated equivalent. The implementation must discover or verify the actual Secret name and password key from Helm/Kubernetes metadata instead of assuming a fixed key.

The password value must remain in memory only as long as needed to construct and create the backend Secret. It must not be logged, returned, or persisted in status artifacts.

## 6. JWT Secret Strategy

The future Launcher should generate `JWT_SECRET_KEY` when the backend Secret does not exist or the key is missing.

Generation rules:

- Use a cryptographically secure random generator.
- Generate at least 32 characters; a longer value is preferred.
- Do not derive the value from usernames, timestamps, repository names, or predictable identifiers.
- Do not print the value.
- Do not write the value to `launcher-status.json`.
- Do not persist the value in a committed or long-lived plaintext file.

If `devdeploy-backend-secret` already contains a valid `JWT_SECRET_KEY`, ensure mode should preserve it. Rotation must require a separate explicit future mode because unplanned rotation invalidates existing JWTs.

## 7. GitHub Workflow Token Strategy

`GITHUB_WORKFLOW_TOKEN` may remain empty or absent in V1 while GitOps workflow dispatch is disabled.

When configured later:

- Store it only in the Kubernetes Secret or user-controlled secure local storage.
- Do not commit it.
- Do not print it.
- Do not write it to `launcher-status.json`.
- Do not return it through setup/status APIs.
- Preserve an existing value unless the user explicitly supplies a replacement.

The backend must start without this token when GitOps automation is disabled and should return a clear configuration error only when token-dependent automation is requested.

## 8. Future Launcher Modes

### Ensure Mode

Future explicit mode:

```powershell
.\scripts\launcher\devdeploy-launcher.ps1 -EnsureManagementBackendSecret
```

This mode should:

1. Verify `devdeploy-mgmt` exists and is reachable.
2. Verify namespace `devdeploy` exists.
3. Verify the PostgreSQL release exists and is Ready.
4. Discover and verify the PostgreSQL Secret name and password key.
5. Read the PostgreSQL password without printing it.
6. Build the expected `DATABASE_URL` in memory.
7. Read the existing backend Secret if present.
8. Preserve a valid existing `JWT_SECRET_KEY` or generate one when missing.
9. Preserve an existing `GITHUB_WORKFLOW_TOKEN` unless explicitly changed.
10. Create or update `devdeploy-backend-secret` predictably.
11. Write sanitized status only.

It must not:

- Deploy backend manifests.
- Build or load images.
- Create workload resources.
- Touch `devdeploy-workload`.
- Print or persist raw Secret values.

### Verify Mode

Future read-only mode:

```powershell
.\scripts\launcher\devdeploy-launcher.ps1 -VerifyManagementBackendSecret
```

This mode should verify:

- `devdeploy-backend-secret` exists.
- Required keys are present.
- `DATABASE_URL` targets the expected host and database without printing its password.
- `JWT_SECRET_KEY` exists and meets the minimum length without printing it.
- `GITHUB_WORKFLOW_TOKEN` state is present, empty, or missing without printing it.

Verify mode must not create, patch, replace, or rotate any Secret.

## 9. Idempotency Rules

- Re-running ensure mode must be safe.
- Preserve an existing valid `JWT_SECRET_KEY` unless explicit rotation is requested.
- Preserve an existing `GITHUB_WORKFLOW_TOKEN` unless the user explicitly changes it.
- Regenerate `DATABASE_URL` only when the PostgreSQL connection contract changes or its stored value is invalid.
- Do not replace valid values merely because ensure mode was rerun.
- Secret updates must be explicit, deterministic, and limited to expected keys.
- A partial failure must not delete the existing Secret automatically.

## 10. Status Contract Proposal

Future `launcher-status.json` may add `platform_bootstrap.components.backend_secret`:

```json
{
  "exists": true,
  "ready": true,
  "namespace": "devdeploy",
  "secret_name": "devdeploy-backend-secret",
  "required_keys_present": true,
  "database_url_configured": true,
  "jwt_secret_configured": true,
  "github_workflow_token_configured": false,
  "status": "ready",
  "message": "Backend runtime Secret exists and required configuration is valid.",
  "checked_at": "2026-01-01T00:00:00Z"
}
```

Suggested status values:

- `not_started`
- `ready`
- `degraded`
- `failed`
- `unknown`

The status must not include actual values, base64 data, passwords, JWT secrets, tokens, or an unmasked `DATABASE_URL`.

## 11. Sanitization Rules

- Never log raw Kubernetes Secret values.
- Never write raw Secret values to `launcher-status.json`.
- Never print a complete `DATABASE_URL` containing a password.
- Never include base64-encoded Secret values in status or logs.
- Do not include secret-bearing kubectl output in error messages.
- Redact command errors before writing Launcher logs.

When a message must identify the database target, use a masked form:

```text
postgresql://devdeploy:***@devdeploy-postgres-postgresql.devdeploy.svc.cluster.local:5432/devdeploy
```

Avoid temporary files containing credentials. If a future implementation cannot avoid one, it must:

- Use an ignored local state directory.
- Restrict access as far as the host allows.
- Remove the file immediately after use.
- Never include the file in diagnostics or Git.

In-memory or standard-input based creation is preferred.

## 12. Failure Modes and Messages

| Failure | Sanitized actionable message |
| --- | --- |
| `devdeploy-mgmt` missing | Run `-CreateManagementCluster` before ensuring the backend Secret. |
| Namespace `devdeploy` missing | Run the management PostgreSQL/bootstrap namespace step first. |
| PostgreSQL release missing | Run `-BootstrapManagementPostgres` before ensuring the backend Secret. |
| PostgreSQL Secret missing | PostgreSQL is installed, but its credential Secret could not be found; verify the Helm release. |
| PostgreSQL password key missing | The PostgreSQL Secret does not contain a usable application password key; inspect release metadata. |
| Insufficient Secret read permissions | The Launcher cannot read the PostgreSQL credential Secret; verify the selected context and permissions. |
| Backend Secret malformed | The backend Secret exists but required keys or formats are invalid; run ensure mode after review. |
| JWT secret too short | The existing JWT key does not meet the minimum length; use a future explicit rotation/repair action. |
| Database host/database mismatch | The configured database target does not match the expected management PostgreSQL service. |
| Create/update failure | Backend Secret reconciliation failed; review sanitized logs and retry without deleting the existing Secret. |

Messages must identify the failed stage without including Secret names beyond expected metadata or exposing values.

## 13. Security Considerations

Kubernetes Secrets are base64-encoded and are not encrypted at rest by default unless cluster encryption is configured. For the local-first V1 management cluster, this is acceptable only when the Secret is treated as sensitive.

Security boundaries:

- Do not commit real Secret YAML.
- Do not place real values in documentation or examples.
- Do not expose values through logs, status files, or API responses.
- Do not pass credentials to GitHub Actions.
- Do not store credentials in frontend localStorage.
- Keep Secret creation scoped to `devdeploy-mgmt/devdeploy`.
- Keep rotation explicit to avoid accidental outages and JWT invalidation.

Future production-oriented versions may support external secret managers, encrypted Secrets, Sealed Secrets, or similar controlled integrations.

## 14. V1 Limitations

- Phase 2D.8 does not create the backend Secret.
- Launcher ensure and verify modes are not implemented yet.
- Secret rotation is not implemented.
- External secret managers are not integrated.
- The backend is not deployed in this phase.
- `GITHUB_WORKFLOW_TOKEN` remains optional and inactive while GitOps dispatch is disabled.
- Management cluster Secret encryption at rest is not configured by this phase.

## 15. Definition of Done

Phase 2D.8 is complete when:

- The backend runtime Secret strategy is documented.
- The PostgreSQL password source and discovery strategy is documented.
- JWT generation and preservation behavior is documented.
- GitHub workflow token handling is documented.
- Future ensure and verify Launcher modes are documented.
- Idempotency and rotation boundaries are documented.
- The sanitized status contract is documented.
- Failure messages and security boundaries are documented.
- No real Secret values are added.
- No Launcher, manifest, deployment, Helm, or cluster mutation behavior is added.

## 16. Related Documents

- [Backend Bootstrap Preparation](./backend-bootstrap-preparation.md)
- [Backend Bootstrap Manifest Strategy](./backend-bootstrap-manifest-strategy.md)
- [Backend Image Build and Load Strategy](./backend-image-build-load-strategy.md)
- [Management Platform Bootstrap Plan](./management-platform-bootstrap-plan.md)
- [Security Boundaries and Credentials Model](./security-credentials-boundaries.md)
- [Phase 2 Implementation Roadmap](./phase-2-implementation-roadmap.md)
