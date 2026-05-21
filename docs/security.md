# DevDeploy Hub Security Scanning

## Purpose

DevDeploy Hub includes a CI-based DevSecOps scanning layer for dependency, filesystem, IaC, and container image checks.

The security workflow lives at:

```text
.github/workflows/security-ci.yml
```

## CI Checks

### Python Dependency Scanning

The backend dependency scan uses `pip-audit` against:

```text
backend/requirements.txt
```

If vulnerable Python packages are found, the backend dependency scan fails.

The only targeted exception is `PYSEC-2025-183` for PyJWT. The advisory is disputed by the supplier and has no fixed version in `pip-audit`; it describes weak JWT signing secrets chosen by applications. DevDeploy Hub mitigates this by requiring `JWT_SECRET_KEY` to be at least 32 characters and by allowing only explicit HMAC JWT algorithms.

### npm Dependency Scanning

The frontend dependency scan runs:

```powershell
npm audit --audit-level=moderate
```

Moderate, high, and critical npm advisories fail the frontend dependency scan. The workflow does not run `npm audit fix`.

### Trivy Filesystem Scan

The repository filesystem scan uses Trivy with:

```text
vuln,secret,misconfig
```

This checks dependency metadata, possible secrets, Dockerfiles, Terraform, and Kubernetes manifests.

High and critical findings fail CI. Low and informational findings do not fail the workflow.

### Trivy Docker Image Scans

The workflow builds local scan-only images:

```text
devdeploy-backend:security-scan
devdeploy-frontend:security-scan
```

The images are scanned with Trivy and are not pushed to any registry.

High and critical image findings fail CI.

## Remediations Applied

- `python-jose` was replaced with `PyJWT` after dependency scanning flagged `PYSEC-2025-185`.
- JWT validation now uses an explicit configured algorithm allowlist and rejects `alg=none`.
- JWT secrets must be at least 32 characters to mitigate the disputed PyJWT weak-secret advisory `PYSEC-2025-183`.
- Frontend build tooling was updated deliberately to remediate the Vite/esbuild audit finding without using `npm audit fix --force`.
- Backend and frontend containers now run as non-root users.
- The backend runtime image moved to the current Python Alpine base to avoid Debian base-image CVEs in the scan.
- The frontend runtime image uses unprivileged nginx on container port `8080`; Docker Compose and Kubernetes still expose the app on the same external ports as before.
- Kubernetes manifests now set explicit pod/container security contexts, drop Linux capabilities, disable privilege escalation, and use read-only root filesystems with small writable scratch volumes where needed.

## Not Included Yet

This phase intentionally does not include:

- Runtime threat detection
- Secret manager integration
- SAST beyond Trivy filesystem checks
- Container signing
- SBOM generation
- Policy-as-code
- Automatic dependency fixes

## Local Commands

### Backend

```powershell
cd backend
pip install pip-audit
pip-audit -r requirements.txt --ignore-vuln PYSEC-2025-183
```

### Frontend

```powershell
cd frontend
npm ci
npm audit --audit-level=moderate
```

### Docker Image Builds

From the repository root:

```powershell
docker build -t devdeploy-backend:security-scan ./backend
docker build --build-arg VITE_API_BASE_URL=http://localhost:8000/api/v1 -t devdeploy-frontend:security-scan ./frontend
```

### Trivy

Install Trivy locally only if you want to run local scans. CI runs Trivy through GitHub Actions.

```powershell
trivy fs --scanners vuln,secret,misconfig --severity HIGH,CRITICAL .
trivy image --severity HIGH,CRITICAL devdeploy-backend:security-scan
trivy image --severity HIGH,CRITICAL devdeploy-frontend:security-scan
```

## Notes

- Security scans do not deploy anything.
- Security scans do not push images.
- No custom GitHub secrets are required.
- Dependency versions are not modified automatically.
- A raw `pip-audit -r requirements.txt` currently reports the disputed PyJWT advisory `PYSEC-2025-183`; CI uses the documented targeted exception above because there is no fixed PyJWT release and DevDeploy Hub enforces strong JWT secret configuration.
- Remaining upstream base image vulnerabilities should be fixed by moving to patched base images when available, not by weakening scan gates.
