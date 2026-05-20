# DevDeploy Hub Frontend

React + Vite + TypeScript frontend for the DevDeploy Hub platform.

## Local Development

```powershell
cd frontend
copy .env.example .env
npm install
npm run dev
```

Default local URL:

```text
http://localhost:5173
```

The frontend reads the backend API base URL from:

```text
VITE_API_BASE_URL=http://localhost:8000/api/v1
```

## Docker Compose

From the repository root, run:

```powershell
docker compose up --build
```

The frontend Docker image builds the Vite app with:

```text
VITE_API_BASE_URL=http://localhost:8000/api/v1
```

It is served by nginx with React Router SPA fallback enabled.

Docker URL:

```text
http://localhost:5173
```

## Build Checks

```powershell
cd frontend
npm run lint
npm run build
```
