from dataclasses import dataclass
import http.client
import json
import logging
import re
from typing import Any, Callable, Mapping, Protocol
from urllib.parse import quote, unquote, urlsplit

import urllib3
from kubernetes import client, stream
from kubernetes.client.exceptions import ApiException

from app.models.deployment_record import DeploymentRecord
from app.services.deployment_access_service import DeploymentAccessService
from app.services.gitops.kubernetes_status_reader import KubernetesGitOpsStatusReader


logger = logging.getLogger(__name__)
MAX_PREVIEW_RESPONSE_BYTES = 2 * 1024 * 1024
PROXY_REQUEST_TIMEOUT = (2, 5)
PATH_SEGMENT_SAFE_CHARS = "-._~"
BROWSER_PREVIEW_ACCEPT = "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"
SAFE_REQUEST_HEADER_NAMES = {
    "accept": "Accept",
    "accept-language": "Accept-Language",
    "content-type": "Content-Type",
    "user-agent": "User-Agent",
}
PREVIEW_ROUTING_SHIM_MARKER = "devdeploy-preview-routing"
ROOT_RELATIVE_HTML_ATTR_RE = re.compile(
    r'(?P<prefix>\b(?:src|href|action)\s*=\s*)(?P<quote>["\'])(?P<url>/[^/"\'][^"\']*)(?P=quote)',
    re.IGNORECASE,
)
SAFE_CONTENT_ENCODINGS = {"br", "deflate", "gzip", "identity"}
SAFE_CONTENT_TYPES = {
    "application/font-woff",
    "application/javascript",
    "application/json",
    "application/octet-stream",
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


class PreviewForbiddenError(RuntimeError):
    pass


class PreviewServiceUnavailableError(RuntimeError):
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
    headers: dict[str, str]


class WorkloadServiceProxy(Protocol):
    def request(
        self,
        *,
        service_name: str,
        namespace: str,
        port: int,
        path: str,
        method: str = "GET",
        body: bytes | None = None,
        request_headers: Mapping[str, str] | None = None,
    ) -> ServiceProxyResponse: ...



class KubernetesServiceProxyClient:
    def __init__(
        self,
        api_client: client.ApiClient,
        *,
        portforward_factory: Callable[..., Any] | None = None,
        http_connection_factory: Callable[[str, int, float], http.client.HTTPConnection] | None = None,
    ):
        self.api_client = api_client
        self.core_v1 = client.CoreV1Api(api_client)
        self.portforward_factory = portforward_factory or stream.portforward
        self.http_connection_factory = http_connection_factory or http.client.HTTPConnection

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
        request_headers: Mapping[str, str] | None = None,
    ) -> ServiceProxyResponse:
        return self.request(
            service_name=service_name,
            namespace=namespace,
            port=port,
            path=path,
            method="GET",
            request_headers=request_headers,
        )

    def request(
        self,
        *,
        service_name: str,
        namespace: str,
        port: int,
        path: str,
        method: str = "GET",
        body: bytes | None = None,
        request_headers: Mapping[str, str] | None = None,
    ) -> ServiceProxyResponse:
        headers = self.safe_upstream_request_headers(request_headers)
        logger.info(
            "Deployment preview upstream request: transport=pod_portforward method=%s accept_category=%s accept_language_present=%s user_agent_present=%s content_type_present=%s",
            method.upper(),
            self._accept_category(headers.get("Accept", "")),
            "Accept-Language" in headers,
            "User-Agent" in headers,
            "Content-Type" in headers,
        )
        try:
            pod_name = self._ready_devdeploy_pod_name(
                namespace=namespace,
                app_name=service_name,
            )
            return self._request_via_pod_portforward(
                namespace=namespace,
                pod_name=pod_name,
                port=port,
                path=path,
                method=method,
                body=body,
                headers=headers,
            )
        except ApiException as error:
            status_code = int(error.status or 0)
            if status_code in {408, 504}:
                logger.info("Deployment preview Kubernetes port-forward request timed out with status %s.", status_code)
                raise PreviewTimeoutError("App preview timed out.") from None
            if status_code == 403:
                logger.info("Deployment preview pod port-forward access was denied by Kubernetes RBAC.")
                raise PreviewForbiddenError("Workload pod port-forward access is denied.") from None
            logger.warning(
                "Deployment preview Kubernetes port-forward request failed with status %s.",
                status_code,
            )
            raise PreviewServiceUnavailableError("The app preview service is unavailable.") from None
        except urllib3.exceptions.TimeoutError:
            logger.info("Deployment preview pod port-forward request timed out.")
            raise PreviewTimeoutError("App preview timed out.") from None
        except PreviewUpstreamError:
            raise
        except (PreviewForbiddenError, PreviewServiceUnavailableError):
            raise
        except Exception as error:
            logger.warning(
                "Deployment preview pod port-forward request failed: %s.",
                error.__class__.__name__,
            )
            raise PreviewServiceUnavailableError("The app preview service is unavailable.") from None

    def _ready_devdeploy_pod_name(self, *, namespace: str, app_name: str) -> str:
        pods = self.core_v1.list_namespaced_pod(
            namespace,
            label_selector=f"app.kubernetes.io/name={app_name},app.kubernetes.io/managed-by=devdeploy",
            _request_timeout=PROXY_REQUEST_TIMEOUT,
        )
        for pod in getattr(pods, "items", []) or []:
            if getattr(getattr(pod, "status", None), "phase", None) != "Running":
                continue
            conditions = getattr(getattr(pod, "status", None), "conditions", []) or []
            ready = any(
                getattr(condition, "type", None) == "Ready"
                and getattr(condition, "status", None) == "True"
                for condition in conditions
            )
            if ready:
                return str(pod.metadata.name)
        raise PreviewServiceUnavailableError("The app preview service is unavailable.")

    def _request_via_pod_portforward(
        self,
        *,
        namespace: str,
        pod_name: str,
        port: int,
        path: str,
        method: str,
        body: bytes | None,
        headers: dict[str, str],
    ) -> ServiceProxyResponse:
        port_forward = self.portforward_factory(
            self.core_v1.connect_post_namespaced_pod_portforward,
            pod_name,
            namespace,
            ports=str(port),
            _request_timeout=PROXY_REQUEST_TIMEOUT,
        )
        connection: http.client.HTTPConnection | None = None
        try:
            connection = self.http_connection_factory("127.0.0.1", port, PROXY_REQUEST_TIMEOUT[1])
            connection.sock = port_forward.socket(port)
            connection.request(method.upper(), self._http_request_path(path), body=body, headers=headers)
            response = connection.getresponse()
            body = response.read(MAX_PREVIEW_RESPONSE_BYTES + 1)
            if len(body) > MAX_PREVIEW_RESPONSE_BYTES:
                logger.info("Deployment preview pod port-forward response exceeded size limit.")
                raise PreviewUpstreamError("The app preview response is too large.")
            return ServiceProxyResponse(
                status_code=int(response.status),
                body=body,
                headers={str(key): str(value) for key, value in response.getheaders()},
            )
        finally:
            if connection is not None:
                connection.close()
            close = getattr(port_forward, "close", None)
            if callable(close):
                close()

    @staticmethod
    def _http_request_path(path: str) -> str:
        encoded_path = "/".join(
            quote(segment, safe=PATH_SEGMENT_SAFE_CHARS)
            for segment in path.split("/")
            if segment
        )
        return f"/{encoded_path}" if encoded_path else "/"

    @staticmethod
    def browser_content_negotiation_headers(
        request_headers: Mapping[str, str] | None,
    ) -> dict[str, str]:
        return KubernetesServiceProxyClient.safe_upstream_request_headers(request_headers)

    @staticmethod
    def safe_upstream_request_headers(
        request_headers: Mapping[str, str] | None,
    ) -> dict[str, str]:
        forwarded: dict[str, str] = {"Accept": BROWSER_PREVIEW_ACCEPT}
        if request_headers is None:
            return forwarded

        for source_name, target_name in SAFE_REQUEST_HEADER_NAMES.items():
            value = KubernetesServiceProxyClient._header_value(request_headers, source_name)
            if value is None:
                continue
            if not KubernetesServiceProxyClient._is_safe_header_value(value):
                logger.info("Deployment preview skipped unsafe upstream request header %s.", target_name)
                continue
            sanitized_value = value.strip()
            if target_name == "Accept" and KubernetesServiceProxyClient._should_use_browser_accept(sanitized_value):
                forwarded[target_name] = BROWSER_PREVIEW_ACCEPT
                continue
            forwarded[target_name] = sanitized_value

        if request_headers is not None:
            for key, value in request_headers.items():
                header_name = str(key).strip()
                lower_name = header_name.lower()
                if not lower_name.startswith("x-"):
                    continue
                if (
                    lower_name.startswith("x-forwarded-")
                    or lower_name.startswith("x-devdeploy-")
                    or lower_name.startswith("x-internal-")
                    or "auth" in lower_name
                    or "token" in lower_name
                    or "secret" in lower_name
                    or "key" in lower_name
                ):
                    continue
                header_value = str(value)
                if KubernetesServiceProxyClient._is_safe_header_value(header_value):
                    forwarded_name = "X-APP" if lower_name == "x-app" else header_name
                    forwarded[forwarded_name] = header_value.strip()

        if not forwarded.get("Accept"):
            forwarded["Accept"] = BROWSER_PREVIEW_ACCEPT
        return forwarded

    @staticmethod
    def _accept_category(value: str) -> str:
        if "text/html" in value.lower():
            return "browser_html"
        if KubernetesServiceProxyClient._should_use_browser_accept(value):
            return "browser_default"
        return "custom"

    @staticmethod
    def _should_use_browser_accept(value: str) -> bool:
        media_ranges = [part.split(";", 1)[0].strip().lower() for part in value.split(",")]
        meaningful_ranges = {media_range for media_range in media_ranges if media_range}
        return not meaningful_ranges or meaningful_ranges.issubset({"*/*", "application/json"})

    @staticmethod
    def _header_value(headers: Mapping[str, str], name: str) -> str | None:
        try:
            value = headers.get(name)  # type: ignore[attr-defined]
        except AttributeError:
            value = None
        if value is None:
            for key, candidate in headers.items():
                if str(key).lower() == name:
                    value = candidate
                    break
        if value is None:
            return None
        return str(value)

    @staticmethod
    def _is_safe_header_value(value: str) -> bool:
        stripped = value.strip()
        return bool(stripped) and len(stripped) <= 1024 and not any(
            ord(character) < 32 or ord(character) == 127 for character in stripped
        )


class DeploymentPreviewService:
    def __init__(
        self,
        *,
        access_service: DeploymentAccessService,
        proxy: WorkloadServiceProxy | None,
    ):
        self.access_service = access_service
        self.proxy = proxy

    def preview(
        self,
        deployment: DeploymentRecord,
        path: str,
        *,
        method: str = "GET",
        body: bytes | None = None,
        request_headers: Mapping[str, str] | None = None,
    ) -> DeploymentPreviewResponse:
        safe_path = self.validate_path(path)
        access = self.access_service.evaluate(deployment)
        if not access.available or access.service is None or access.service.port is None:
            raise PreviewUnavailableError(access.status)
        if self.proxy is None:
            raise PreviewUnavailableError("runtime_unavailable")

        upstream = self.proxy.request(
            service_name=access.service.name,
            namespace=access.service.namespace,
            port=access.service.port,
            path=safe_path,
            method=method,
            body=body,
            request_headers=KubernetesServiceProxyClient.safe_upstream_request_headers(request_headers),
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
            headers=self._safe_response_headers(upstream.headers),
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
    def rewrite_html_for_preview(
        body: bytes,
        headers: dict[str, str],
        *,
        preview_base_path: str,
        runtime_auth_token: str | None = None,
    ) -> bytes:
        content_type = next(
            (value for key, value in headers.items() if key.lower() == "content-type"),
            "",
        )
        media_type = content_type.split(";", 1)[0].strip().lower()
        if media_type != "text/html":
            return body
        if any(key.lower() == "content-encoding" for key in headers):
            return body
        try:
            html = body.decode("utf-8")
        except UnicodeDecodeError:
            logger.info("Deployment preview skipped HTML routing rewrite for non-UTF-8 document.")
            return body

        base_path = DeploymentPreviewService._normalized_preview_base_path(preview_base_path)
        rewritten = DeploymentPreviewService._rewrite_root_relative_html_attributes(html, base_path)
        if PREVIEW_ROUTING_SHIM_MARKER not in rewritten:
            injection = (
                f'<base href="{base_path}">'
                f'<script>{DeploymentPreviewService._preview_routing_shim(base_path, runtime_auth_token)}</script>'
            )
            rewritten = DeploymentPreviewService._inject_preview_head_content(rewritten, injection)
        return rewritten.encode("utf-8")

    @staticmethod
    def _normalized_preview_base_path(preview_base_path: str) -> str:
        base_path = preview_base_path.strip() or "/"
        if not base_path.startswith("/"):
            base_path = f"/{base_path}"
        if not base_path.endswith("/"):
            base_path = f"{base_path}/"
        return base_path

    @staticmethod
    def _rewrite_root_relative_html_attributes(html: str, base_path: str) -> str:
        def replace(match: re.Match[str]) -> str:
            url = match.group("url")
            if url.startswith(base_path):
                rewritten_url = url
            else:
                rewritten_url = f"{base_path}{url.lstrip('/')}"
            return f"{match.group('prefix')}{match.group('quote')}{rewritten_url}{match.group('quote')}"

        return ROOT_RELATIVE_HTML_ATTR_RE.sub(replace, html)

    @staticmethod
    def _inject_preview_head_content(html: str, injection: str) -> str:
        head_match = re.search(r"<head(?:\s[^>]*)?>", html, flags=re.IGNORECASE)
        if head_match is None:
            return f"{injection}{html}"
        return f"{html[:head_match.end()]}{injection}{html[head_match.end():]}"

    @staticmethod
    def _preview_routing_shim(base_path: str, runtime_auth_token: str | None = None) -> str:
        base_json = json.dumps(base_path)
        token_json = json.dumps(runtime_auth_token or "")
        return (
            f"/* {PREVIEW_ROUTING_SHIM_MARKER} */"
            "(() => {"
            f"const previewBase = {base_json};"
            "const previewSessionHeader = 'X-DevDeploy-Preview-Session';"
            f"const previewSessionToken = {token_json};"
            "const isExternalUrl = (value) => /^(?:[a-z][a-z0-9+.-]*:|\\/\\/)/i.test(value);"
            "const previewRouteFor = (value) => {"
            "if (typeof value !== 'string') return {url: value, usesPreview: false};"
            "if (isExternalUrl(value)) return {url: value, usesPreview: false};"
            "if (value.startsWith('/')) {"
            "const url = value.startsWith(previewBase) ? value : previewBase + value.replace(/^\\/+/, '');"
            "return {url, usesPreview: url.startsWith(previewBase)};"
            "}"
            "try {"
            "const parsed = new URL(value, window.location.href);"
            "if (parsed.origin === window.location.origin && parsed.pathname.startsWith(previewBase)) {"
            "return {url: parsed.pathname + parsed.search + parsed.hash, usesPreview: true};"
            "}"
            "} catch (_) {}"
            "return {url: value, usesPreview: false};"
            "};"
            "const toPreviewUrl = (value) => previewRouteFor(value).url;"
            "const withPreviewAuth = (init) => {"
            "const next = Object.assign({}, init || {}, {credentials: 'include'});"
            "if (previewSessionToken) {"
            "const headers = new Headers((init && init.headers) || undefined);"
            "headers.set(previewSessionHeader, previewSessionToken);"
            "next.headers = headers;"
            "}"
            "return next;"
            "};"
            "const originalFetch = window.fetch;"
            "if (typeof originalFetch === 'function') {"
            "window.fetch = function(input, init) {"
            "if (typeof input === 'string') {"
            "const routed = previewRouteFor(input);"
            "return originalFetch.call(this, routed.url, routed.usesPreview ? withPreviewAuth(init) : init);"
            "}"
            "if (input && typeof input.url === 'string') {"
            "try {"
            "const parsed = new URL(input.url, window.location.href);"
            "if (parsed.origin === window.location.origin && parsed.pathname.startsWith(previewBase)) {"
            "init = withPreviewAuth(init);"
            "} else if (parsed.origin === window.location.origin && parsed.pathname.startsWith('/')) {"
            "const routed = previewRouteFor(parsed.pathname + parsed.search + parsed.hash);"
            "if (routed.usesPreview) { input = new Request(routed.url, input); init = withPreviewAuth(init); }"
            "}"
            "} catch (_) {}"
            "}"
            "return originalFetch.call(this, input, init);"
            "};"
            "}"
            "if (window.XMLHttpRequest && window.XMLHttpRequest.prototype.open) {"
            "const originalOpen = window.XMLHttpRequest.prototype.open;"
            "const originalSend = window.XMLHttpRequest.prototype.send;"
            "window.XMLHttpRequest.prototype.open = function() {"
            "const args = Array.prototype.slice.call(arguments);"
            "const routed = previewRouteFor(args[1]);"
            "args[1] = routed.url;"
            "this.__devdeployPreviewAuth = routed.usesPreview;"
            "const result = originalOpen.apply(this, args);"
            "if (routed.usesPreview) { try { this.withCredentials = true; } catch (_) {} }"
            "return result;"
            "};"
            "window.XMLHttpRequest.prototype.send = function() {"
            "if (this.__devdeployPreviewAuth && previewSessionToken) {"
            "try { this.setRequestHeader(previewSessionHeader, previewSessionToken); } catch (_) {}"
            "}"
            "return originalSend.apply(this, arguments);"
            "};"
            "}"
            "})();"
        )

    @staticmethod
    def _safe_response_headers(headers: dict[str, str]) -> dict[str, str]:
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

        safe_headers = {"Content-Type": content_type.strip()}
        content_encoding = next(
            (value for key, value in headers.items() if key.lower() == "content-encoding"),
            None,
        )
        if content_encoding is not None:
            if any(ord(character) < 32 or ord(character) == 127 for character in content_encoding):
                logger.info("Deployment preview upstream returned an unsafe Content-Encoding header.")
                raise PreviewUpstreamError("The app preview content encoding is not supported.")
            encodings = {
                value.strip().lower()
                for value in content_encoding.split(",")
                if value.strip()
            }
            if not encodings.issubset(SAFE_CONTENT_ENCODINGS):
                logger.info("Deployment preview upstream returned unsupported content encoding.")
                raise PreviewUpstreamError("The app preview content encoding is not supported.")
            safe_headers["Content-Encoding"] = content_encoding.strip()
        return safe_headers
