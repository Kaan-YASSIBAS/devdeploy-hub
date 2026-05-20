# DevDeploy Hub API

FastAPI backend core API for DevDeploy Hub. This phase stores users, applications, deployment requests, and deployment timeline events. It does not deploy to Kubernetes or integrate Docker, Terraform, Argo CD, Prometheus, Grafana, or CI/CD yet.

## Setup

```powershell
cd backend
python -m venv .venv
.\.venv\Scripts\Activate.ps1
pip install -r requirements.txt
copy .env.example .env
```

Start PostgreSQL from the repository root:

```powershell
docker compose up -d postgres
```

Run migrations:

```powershell
cd backend
alembic upgrade head
```

Run the API:

```powershell
uvicorn app.main:app --reload
```

API docs are available at:

```text
http://localhost:8000/docs
```

## Environment Variables

```text
DATABASE_URL=postgresql://devdeploy:devdeploy@localhost:5432/devdeploy
JWT_SECRET_KEY=change-me-in-production
JWT_ALGORITHM=HS256
ACCESS_TOKEN_EXPIRE_MINUTES=60
FRONTEND_ORIGIN=http://localhost:5173
ENVIRONMENT=development
```

When `ENVIRONMENT=development`, the first registered user is created as `admin` for local setup convenience. Later users are `developer`.

## Alembic

```powershell
alembic upgrade head
alembic downgrade -1
alembic revision --autogenerate -m "describe change"
```

## Endpoints

Base prefix:

```text
/api/v1
```

Core:

```text
GET /api/v1/health
```

Auth:

```text
POST /api/v1/auth/register
POST /api/v1/auth/login
POST /api/v1/auth/token
GET  /api/v1/auth/me
```

`/auth/login` accepts a JSON body and is intended for the frontend and API clients.
`/auth/token` accepts OAuth2 form data for Swagger Authorize. Use the user's email as `username`, the user's password as `password`, and leave `client_id` and `client_secret` empty.

Users:

```text
GET /api/v1/users/me/summary
```

Applications:

```text
POST   /api/v1/applications
GET    /api/v1/applications
GET    /api/v1/applications/{application_id}
PUT    /api/v1/applications/{application_id}
DELETE /api/v1/applications/{application_id}
```

Deployments:

```text
POST  /api/v1/deployments
GET   /api/v1/deployments
GET   /api/v1/deployments/{deployment_id}
PATCH /api/v1/deployments/{deployment_id}/status
```

## Quick Smoke Test

```powershell
curl http://localhost:8000/api/v1/health

curl -X POST http://localhost:8000/api/v1/auth/register `
  -H "Content-Type: application/json" `
  -d "{\"email\":\"user@example.com\",\"username\":\"kaan\",\"password\":\"password123\"}"

curl -X POST http://localhost:8000/api/v1/auth/login `
  -H "Content-Type: application/json" `
  -d "{\"email\":\"user@example.com\",\"password\":\"password123\"}"

curl -X POST http://localhost:8000/api/v1/auth/token `
  -H "Content-Type: application/x-www-form-urlencoded" `
  -d "username=user@example.com&password=password123"
```
