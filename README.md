# DevDeploy Hub

A full-stack DevOps platform for self-service Kubernetes deployments, GitOps workflows, observability, and infrastructure automation.

## Vision

DevDeploy Hub aims to provide a modern internal developer platform experience where teams can deploy, monitor, and manage applications across Kubernetes environments.

## Current Phase

Phase 1: Full-stack local development foundation with Docker Compose, FastAPI, PostgreSQL, and the premium React frontend.

## Docker Compose

Run the full stack from the repository root:

```powershell
docker compose up --build
```

Services:

```text
Frontend:     http://localhost:5173
Backend API:  http://localhost:8000
Swagger Docs: http://localhost:8000/docs
Health:       http://localhost:8000/api/v1/health
```

Stop the stack:

```powershell
docker compose down
```

Reset the database volume:

```powershell
docker compose down -v
```

In development mode, the first registered user becomes `admin`; later users are created as `developer`.

## Local Development

The Docker setup does not replace local workflows. You can still run the backend with `uvicorn app.main:app --reload` from `backend/`, and the frontend with `npm run dev` from `frontend/`.

## Continuous Integration

GitHub Actions workflows live in `.github/workflows`:

- `frontend-ci.yml` validates the React/Vite frontend with `npm ci`, `npm run lint`, and `npm run build`.
- `backend-ci.yml` validates the FastAPI backend by installing Python dependencies, compiling modules, running Alembic migrations against PostgreSQL, importing the app, and smoke testing `/api/v1/health`.
- `docker-ci.yml` validates `docker-compose.yml` and builds the backend and frontend Docker images.

These workflows are CI only. They do not deploy, publish images, or require secrets.

## Kubernetes Local Manifests

Local Kubernetes manifests live in `infra/kubernetes`.

Quick commands:

```powershell
kubectl apply -k infra/kubernetes/overlays/dev
kubectl get all -n devdeploy
```

The detailed guide in `infra/kubernetes/README.md` covers local image builds for kind/minikube, the first-test port-forward path, and the optional `devdeploy.local` ingress path.
