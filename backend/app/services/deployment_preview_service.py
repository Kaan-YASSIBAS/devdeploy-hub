from dataclasses import dataclass
import logging
from typing import Any, Protocol
from urllib.parse import quote, unquote, urlsplit

import urllib3
from kubernetes import client
from kubernetes.client.exceptions import ApiException

from app.models.deployment_record import DeploymentRecord
from app.services.deployment_access_service import DeploymentAccessService
from app.services.gitops.kubernetes_status_reader import KubernetesGitOpsStatusReader


logger = logging.getLogger(__name__)
MAX_PREVIEW_RESPONSE_BYTES = 2 * 1024 * 1024
PROXY_REQUEST_TIMEOUT = (2, 5)
PATH_SEGMENT_SAFE_CHARS = "-._~"
SAFE_CONTENT_TYPES = {
    "application/font-woff",
    "application/javascript",
    "application/json",
    "application/vnd.ms-fontobject",
    "font/otf",
    "font/ttf",
    "font/woff",
    "font/woff2",
    "image/gif",
    "image/jpeg",
    "image/png",
    "image/svg+xml",
    "image/webp",
    "image/x-icon",
    "text/css",
    "text/html",
    "text/javascript",
    "text/plain",
}


class PreviewPathError(ValueError):
    pass


class PreviewUnavailableError(RuntimeError):
    def __init__(self, access_status: str):
        super().__init__("App preview is unavailable.")
        self.access_status = access_status


class PreviewTimeoutError(RuntimeError):
    pass


class PreviewUpstreamError(RuntimeError):
    pass


@dataclass(frozen=True, slots=True)
class ServiceProxyResponse:
    status_code: int
    body: bytes
    headers: dict[str, str]


@dataclass(frozen=True, slots=True)
class DeploymentPreviewResponse:
    status_code: int
    body: bytes
    content_type: str


class WorkloadServiceProxy(Protocol):
    def get(
        self,
        *,
        service_name: str,
        namespace: str,
        port: int,
        path: str,
    ) -> ServiceProxyResponse: ...


class NoRedirectPoolManager:
    """Force the Kubernetes API HTTP client to return redirects unchanged."""

    def __init__(self, delegate: Any):
        self.delegate = delegate

    def request(self, *args: Any, **kwargs: Any) -> Any:
        kwargs["redirect"] = False
        return self.delegate.request(*args, **kwargs)

    def __getattr__(self, name: str) -> Any:
        return getattr(self.delegate, name)


class KubernetesServiceProxyClient:
    def __init__(self, api_client: client.ApiClient):
        pool_manager = api_client.rest_client.pool_manager
        api_client.rest_client.pool_manager = NoRedirectPoolManager(pool_manager)
        self.api_client = api_client

    @classmethod
    def from_server_config(
        cls,
        *,
        workload_kubeconfig: str | None,
        workload_kubeconfig_context: str | None,
    ) -> "KubernetesServiceProxyClient":
        api_client = KubernetesGitOpsStatusReader._build_api_client(
            kubeconfig_path=workload_kubeconfig,
            kubeconfig_context=workload_kubeconfig_context,
            allow_in_cluster=False,
        )
        return cls(api_client)

    def get(
        self,
        *,
        service_name: str,
        namespace: str,
        port: int,
        path: str,
    ) -> ServiceProxyResponse:
        resource_path = self._service_proxy_resource_path(
            namespace=namespace,
            service_name=service_name,
            port=port,
            path=path,
        )
        header_params = {
            "Accept": self.api_client.select_header_accept(["*/*"]),
        }
        try:
            raw_response = self.api_client.call_api(
                resource_path,
                "GET",
                path_params={},
                query_params=[],
                header_params=header_params,
                body=None,
                post_params=[],
                files={},
                response_types_map={200: "str", 401: None},
                auth_settings=["BearerToken"],
                async_req=None,
                _return_http_data_only=True,
                _preload_content=False,
                _request_timeout=PROXY_REQUEST_TIMEOUT,
                collection_formats={},
                _request_auth=None,
            )
            return self._bounded_response(raw_response)
        except ApiException as error:
            status_code = int(error.status or 0)
            if 300 <= status_code <= 399:
                logger.info("Deployment preview Service proxy returned redirect status %s.", status_code)
                raise PreviewUpstreamError("Upstream redirects are not supported.") from None
            if status_code in {408, 504}:
                logger.info("Deployment preview Service proxy timed out with status %s.", status_code)
                raise PreviewTimeoutError("App preview timed out.") from None
            if 400 <= status_code <= 499:
                logger.info("Deployment preview Service proxy returned client status %s.", status_code)
                return ServiceProxyResponse(
                    status_code=status_code,
                    body=f"Preview upstream returned HTTP {status_code}.".encode("ascii"),
                    headers={"Content-Type": "text/plain; charset=utf-8"},
                )
            logger.warning("Deployment preview Service proxy failed with Kubernetes status %s.", status_code)
            raise PreviewUpstreamError("The app preview upstream is unavailable.") from None
        except urllib3.exceptions.TimeoutError:
            logger.info("Deployment preview Service proxy request timed out.")
            raise PreviewTimeoutError("App preview timed out.") from None
        except PreviewUpstreamError:
            raise
        except Exception as error:
            logger.warning(
                "Deployment preview Service proxy request failed: %s.",
                error.__class__.__name__,
            )
            raise PreviewUpstreamError("The app preview upstream is unavailable.") from None

    @staticmethod
    def _service_proxy_resource_path(
        *,
        namespace: str,
        service_name: str,
        port: int,
        path: str,
    ) -> str:
        namespace_path = quote(namespace, safe=PATH_SEGMENT_SAFE_CHARS)
        service_target = quote(
            f"{service_name}:{port}",
            safe=f"{PATH_SEGMENT_SAFE_CHARS}:",
        )
        encoded_path = "/".join(
            quote(segment, safe=PATH_SEGMENT_SAFE_CHARS)
            for segment in path.split("/")
            if segment
        )
        base = f"/api/v1/namespaces/{namespace_path}/services/{service_target}/proxy/"
        return f"{base}{encoded_path}" if encoded_path else base

    @staticmethod
    def _bounded_response(raw_response: Any) -> ServiceProxyResponse:
        try:
            body = raw_response.read(MAX_PREVIEW_RESPONSE_BYTES + 1, decode_content=True)
            if len(body) > MAX_PREVIEW_RESPONSE_BYTES:
                logger.info("Deployment preview Service proxy response exceeded size limit.")
                raise PreviewUpstreamError("The app preview response is too large.")
            headers = {str(key): str(value) for key, value in raw_response.headers.items()}
            return ServiceProxyResponse(
                status_code=int(raw_response.status),
                body=body,
                headers=headers,
            )
        finally:
            raw_response.release_conn()


class DeploymentPreviewService:
    def __init__(
        self,
        *,
        access_service: DeploymentAccessService,
        proxy: WorkloadServiceProxy | None,
    ):
        self.access_service = access_service
        self.proxy = proxy

    def preview(self, deployment: DeploymentRecord, path: str) -> DeploymentPreviewResponse:
        safe_path = self.validate_path(path)
        access = self.access_service.evaluate(deployment)
        if not access.available or access.service is None or access.service.port is None:
            raise PreviewUnavailableError(access.status)
        if self.proxy is None:
            raise PreviewUnavailableError("runtime_unavailable")

        upstream = self.proxy.get(
            service_name=access.service.name,
            namespace=access.service.namespace,
            port=access.service.port,
            path=safe_path,
        )
        if 300 <= upstream.status_code <= 399:
            raise PreviewUpstreamError("Upstream redirects are not supported.")
        if upstream.status_code >= 500:
            raise PreviewUpstreamError("The app preview upstream is unavailable.")
        if len(upstream.body) > MAX_PREVIEW_RESPONSE_BYTES:
            raise PreviewUpstreamError("The app preview response is too large.")

        return DeploymentPreviewResponse(
            status_code=upstream.status_code,
            body=upstream.body,
            content_type=self._safe_content_type(upstream.headers),
        )

    @staticmethod
    def validate_path(path: str) -> str:
        DeploymentPreviewService._reject_unsafe_path(path)
        decoded = path
        for _ in range(3):
            next_value = unquote(decoded)
            if next_value == decoded:
                break
            decoded = next_value
        DeploymentPreviewService._reject_unsafe_path(decoded)

        normalized = decoded.lstrip("/")
        parsed = urlsplit(normalized)
        if parsed.scheme or parsed.netloc:
            raise PreviewPathError("Preview path cannot specify a target URL.")
        if any(segment in {".", ".."} for segment in normalized.split("/")):
            raise PreviewPathError("Preview path traversal is not allowed.")
        return normalized

    @staticmethod
    def _reject_unsafe_path(path: str) -> None:
        lowered = path.lower().lstrip("/")
        if (
            len(path) > 2048
            or any(ord(character) < 32 or ord(character) == 127 for character in path)
            or "\\" in path
            or path.startswith("//")
            or lowered.startswith("http://")
            or lowered.startswith("https://")
        ):
            raise PreviewPathError("Preview path is invalid.")

    @staticmethod
    def _safe_content_type(headers: dict[str, str]) -> str:
        content_type = next(
            (value for key, value in headers.items() if key.lower() == "content-type"),
            "application/octet-stream",
        )
        if any(ord(character) < 32 or ord(character) == 127 for character in content_type):
            logger.info("Deployment preview upstream returned an unsafe Content-Type header.")
            raise PreviewUpstreamError("The app preview content type is not supported.")
        media_type = content_type.split(";", 1)[0].strip().lower()
        if media_type not in SAFE_CONTENT_TYPES:
            logger.info("Deployment preview upstream returned unsupported content type %s.", media_type)
            raise PreviewUpstreamError("The app preview content type is not supported.")
        return media_type
