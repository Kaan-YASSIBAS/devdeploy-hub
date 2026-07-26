import re

from fastapi import FastAPI, Request, Response
from fastapi.middleware.cors import CORSMiddleware
from prometheus_fastapi_instrumentator import Instrumentator

from app.api.v1.router import api_router
from app.core.config import settings


app = FastAPI(title="DevDeploy Hub API")
PREVIEW_PREFLIGHT_PATH_RE = re.compile(
    r"^/api/v1/deployment-records/\d+/preview(?:/.*)?$"
)
PREVIEW_RUNTIME_AUTH_HEADER = "X-DevDeploy-Preview-Session"
PREVIEW_PREFLIGHT_ALLOWED_HEADERS = (
    f"Accept, Accept-Language, Content-Type, User-Agent, X-APP, {PREVIEW_RUNTIME_AUTH_HEADER}"
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=settings.cors_origins,
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


def _preview_preflight_headers(request: Request) -> dict[str, str]:
    requested_headers = request.headers.get("access-control-request-headers")
    allowed_headers = PREVIEW_PREFLIGHT_ALLOWED_HEADERS
    if requested_headers:
        safe_headers: list[str] = []
        for header_name in requested_headers.split(","):
            normalized = header_name.strip()
            lowered = normalized.lower()
            if not normalized:
                continue
            if lowered in {"authorization", "cookie", "host", "connection", "proxy-authorization"}:
                continue
            if lowered == PREVIEW_RUNTIME_AUTH_HEADER.lower():
                safe_headers.append(PREVIEW_RUNTIME_AUTH_HEADER)
                continue
            if lowered.startswith("x-forwarded-") or lowered.startswith("x-devdeploy-"):
                continue
            if any(marker in lowered for marker in ("auth", "token", "secret", "key")):
                continue
            if all(character.isalnum() or character in "-_" for character in normalized):
                safe_headers.append(normalized)
        if safe_headers:
            allowed_headers = ", ".join(sorted(set(safe_headers), key=str.lower))

    return {
        "Access-Control-Allow-Origin": "null",
        "Access-Control-Allow-Credentials": "true",
        "Access-Control-Allow-Methods": "GET, HEAD, OPTIONS, POST",
        "Access-Control-Allow-Headers": allowed_headers,
        "Access-Control-Max-Age": "600",
        "Vary": "Origin",
    }


@app.middleware("http")
async def preview_preflight_middleware(request: Request, call_next):
    if (
        request.method.upper() == "OPTIONS"
        and request.headers.get("origin") == "null"
        and PREVIEW_PREFLIGHT_PATH_RE.match(request.url.path)
    ):
        return Response(status_code=204, headers=_preview_preflight_headers(request))
    return await call_next(request)


app.include_router(api_router, prefix="/api/v1")

Instrumentator(
    should_group_status_codes=False,
    should_ignore_untemplated=True,
    excluded_handlers=["/metrics"],
).instrument(app).expose(app, endpoint="/metrics", include_in_schema=False)
