import unittest

from kubernetes.client.exceptions import ApiException

from app.services.deployment_preview_service import (
    BROWSER_PREVIEW_ACCEPT,
    DeploymentPreviewService,
    KubernetesServiceProxyClient,
    PreviewForbiddenError,
    PreviewPathError,
    PreviewServiceUnavailableError,
    PreviewUpstreamError,
)



class FakeApiClient:
    pass


class FakeMetadata:
    name = "podinfo-abc123"


class FakeCondition:
    type = "Ready"
    status = "True"


class FakeStatus:
    phase = "Running"
    conditions = [FakeCondition()]


class FakePod:
    metadata = FakeMetadata()
    status = FakeStatus()


class FakePodList:
    items = [FakePod()]


class FakeCoreV1:
    def __init__(self):
        self.list_calls = []
        self.portforward_method = object()
        self.raise_on_list = None
        self.pod_list = FakePodList()

    def list_namespaced_pod(self, namespace, **kwargs):
        self.list_calls.append((namespace, kwargs))
        if self.raise_on_list is not None:
            raise self.raise_on_list
        return self.pod_list

    @property
    def connect_post_namespaced_pod_portforward(self):
        return self.portforward_method


class FakePortForward:
    def __init__(self):
        self.closed = False
        self.socket_requests = []

    def socket(self, port):
        self.socket_requests.append(port)
        return object()

    def close(self):
        self.closed = True


class FakeHttpResponse:
    def __init__(self, status=200, body=b"<html>podinfo</html>", headers=None):
        self.status = status
        self.body = body
        self.headers = headers or [("Content-Type", "text/html; charset=utf-8")]

    def read(self, size):
        return self.body

    def getheaders(self):
        return self.headers


class FakeHttpConnection:
    response = FakeHttpResponse()
    instances = []

    def __init__(self, host, port, timeout):
        self.host = host
        self.port = port
        self.timeout = timeout
        self.sock = None
        self.requests = []
        self.closed = False
        FakeHttpConnection.instances.append(self)

    def request(self, method, path, body=None, headers=None):
        self.requests.append((method, path, body, headers or {}))

    def getresponse(self):
        return self.response

    def close(self):
        self.closed = True


def make_preview_client():
    api_client = FakeApiClient()
    port_forward = FakePortForward()
    portforward_calls = []

    def portforward_factory(*args, **kwargs):
        portforward_calls.append((args, kwargs))
        return port_forward

    FakeHttpConnection.instances = []
    FakeHttpConnection.response = FakeHttpResponse()
    preview_client = KubernetesServiceProxyClient(
        api_client,
        portforward_factory=portforward_factory,
        http_connection_factory=FakeHttpConnection,
    )
    preview_client.core_v1 = FakeCoreV1()
    return preview_client, port_forward, portforward_calls


class DeploymentPreviewServiceTestCase(unittest.TestCase):
    def test_rejects_external_traversal_encoded_and_control_paths(self) -> None:
        invalid_paths = (
            "http://attacker.example/path",
            "https://attacker.example/path",
            "//attacker.example/path",
            "..%2Fsecret",
            "%252e%252e%252fsecret",
            "%68%74%74%70%3A%2F%2Fattacker.example",
            "%2F%2Fattacker.example/path",
            "folder\\..\\secret",
            "folder%0d%0aInjected:true",
        )

        for path in invalid_paths:
            with self.subTest(path=path):
                with self.assertRaises(PreviewPathError):
                    DeploymentPreviewService.validate_path(path)

    def test_accepts_only_relative_preview_paths(self) -> None:
        self.assertEqual(
            DeploymentPreviewService.validate_path("assets/css/app.css"),
            "assets/css/app.css",
        )
        self.assertEqual(DeploymentPreviewService.validate_path(""), "")

    def test_sanitizes_supported_content_type(self) -> None:
        self.assertEqual(
            DeploymentPreviewService._safe_response_headers(
                {"Content-Type": "text/html; charset=utf-8"}
            ),
            {"Content-Type": "text/html; charset=utf-8"},
        )

    def test_rejects_unsafe_content_type_header(self) -> None:
        with self.assertRaises(PreviewUpstreamError):
            DeploymentPreviewService._safe_response_headers(
                {"Content-Type": "text/html\r\nSet-Cookie: attacker=1"}
            )

    def test_preserves_octet_stream_runtime_api_response(self) -> None:
        self.assertEqual(
            DeploymentPreviewService._safe_response_headers(
                {"Content-Type": "application/octet-stream"}
            ),
            {"Content-Type": "application/octet-stream"},
        )
    def test_preserves_safe_content_encoding_header(self) -> None:
        self.assertEqual(
            DeploymentPreviewService._safe_response_headers(
                {
                    "Content-Type": "text/css; charset=utf-8",
                    "Content-Encoding": "gzip",
                }
            ),
            {
                "Content-Type": "text/css; charset=utf-8",
                "Content-Encoding": "gzip",
            },
        )

    def test_rewrites_root_relative_html_urls_and_injects_preview_shim(self) -> None:
        body = (
            '<html><head><title>App</title></head><body>'
            '<img src="/static/logo.png">'
            '<a href="/dashboard">Dashboard</a>'
            '<form action="/api/save"></form>'
            '<script src="/app.js"></script>'
            '</body></html>'
        ).encode()

        rewritten = DeploymentPreviewService.rewrite_html_for_preview(
            body,
            {"Content-Type": "text/html; charset=utf-8"},
            preview_base_path="/api/v1/deployment-records/23/preview/",
            runtime_auth_token="preview-runtime-token",
        ).decode()

        self.assertIn('<base href="/api/v1/deployment-records/23/preview/">', rewritten)
        self.assertIn("devdeploy-preview-routing", rewritten)
        self.assertIn('src="/api/v1/deployment-records/23/preview/static/logo.png"', rewritten)
        self.assertIn('href="/api/v1/deployment-records/23/preview/dashboard"', rewritten)
        self.assertIn('action="/api/v1/deployment-records/23/preview/api/save"', rewritten)
        self.assertIn('src="/api/v1/deployment-records/23/preview/app.js"', rewritten)
        self.assertLess(
            rewritten.index('<base href="/api/v1/deployment-records/23/preview/">'),
            rewritten.index('/preview/app.js'),
        )
        self.assertIn("const previewRouteFor = (value) =>", rewritten)
        self.assertIn("const routed = previewRouteFor(input);", rewritten)
        self.assertIn("new URL(value, window.location.href)", rewritten)
        self.assertIn("parsed.pathname.startsWith(previewBase)", rewritten)
        self.assertIn("routed.usesPreview ? withPreviewAuth(init) : init", rewritten)
        self.assertIn("if (routed.usesPreview) { input = new Request(routed.url, input); init = withPreviewAuth(init); }", rewritten)
        self.assertIn("const routed = previewRouteFor(args[1]);", rewritten)
        self.assertIn("isExternalUrl", rewritten)
        self.assertIn("XMLHttpRequest", rewritten)
        self.assertIn("window.fetch", rewritten)
        self.assertIn("credentials: 'include'", rewritten)
        self.assertIn("X-DevDeploy-Preview-Session", rewritten)
        self.assertIn("preview-runtime-token", rewritten)
        self.assertIn("headers.set(previewSessionHeader, previewSessionToken)", rewritten)
        self.assertIn("window.XMLHttpRequest.prototype.send", rewritten)
        self.assertIn("this.setRequestHeader(previewSessionHeader, previewSessionToken)", rewritten)
        self.assertIn("__devdeployPreviewAuth", rewritten)
        self.assertIn("this.withCredentials = true", rewritten)

    def test_preview_html_rewrite_leaves_external_and_unsafe_scheme_urls_unchanged(self) -> None:
        body = (
            '<html><head></head><body>'
            '<script src="https://cdn.example.test/app.js"></script>'
            '<a href="//cdn.example.test/app.css">cdn</a>'
            '<a href="javascript:alert(1)">bad</a>'
            '<img src="data:image/png;base64,abcd">'
            '</body></html>'
        ).encode()

        rewritten = DeploymentPreviewService.rewrite_html_for_preview(
            body,
            {"Content-Type": "text/html; charset=utf-8"},
            preview_base_path="/api/v1/deployment-records/23/preview/",
        ).decode()

        self.assertIn('src="https://cdn.example.test/app.js"', rewritten)
        self.assertIn('href="//cdn.example.test/app.css"', rewritten)
        self.assertIn('href="javascript:alert(1)"', rewritten)
        self.assertIn('src="data:image/png;base64,abcd"', rewritten)

    def test_preview_html_rewrite_skips_encoded_html_body(self) -> None:
        body = b"<html><head></head><body></body></html>"

        self.assertEqual(
            DeploymentPreviewService.rewrite_html_for_preview(
                body,
                {"Content-Type": "text/html", "Content-Encoding": "gzip"},
                preview_base_path="/api/v1/deployment-records/23/preview/",
            ),
            body,
        )
    def test_rejects_unsafe_content_encoding_header(self) -> None:
        with self.assertRaises(PreviewUpstreamError):
            DeploymentPreviewService._safe_response_headers(
                {
                    "Content-Type": "text/html; charset=utf-8",
                    "Content-Encoding": "gzip\r\nSet-Cookie: attacker=1",
                }
            )

    def test_kubernetes_preview_transport_uses_pod_portforward_root_path(self) -> None:
        proxy_client, port_forward, portforward_calls = make_preview_client()

        response = proxy_client.get(
            namespace="devdeploy-apps",
            service_name="podinfo",
            port=9898,
            path="",
        )

        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.body, b"<html>podinfo</html>")
        self.assertEqual(
            proxy_client.core_v1.list_calls,
            [
                (
                    "devdeploy-apps",
                    {
                        "label_selector": "app.kubernetes.io/name=podinfo,app.kubernetes.io/managed-by=devdeploy",
                        "_request_timeout": (2, 5),
                    },
                )
            ],
        )
        self.assertEqual(portforward_calls[0][0][1:3], ("podinfo-abc123", "devdeploy-apps"))
        self.assertEqual(portforward_calls[0][1]["ports"], "9898")
        self.assertEqual(port_forward.socket_requests, [9898])
        connection = FakeHttpConnection.instances[0]
        self.assertEqual(connection.requests[0][0], "GET")
        self.assertEqual(connection.requests[0][1], "/")
        self.assertEqual(connection.requests[0][3], {"Accept": BROWSER_PREVIEW_ACCEPT})
        self.assertTrue(connection.closed)
        self.assertTrue(port_forward.closed)

    def test_kubernetes_preview_transport_forwards_safe_browser_negotiation_headers(self) -> None:
        proxy_client, _, _ = make_preview_client()

        proxy_client.get(
            namespace="devdeploy-apps",
            service_name="podinfo",
            port=9898,
            path="",
            request_headers={
                "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
                "Accept-Language": "tr-TR,tr;q=0.9,en-US;q=0.8",
                "User-Agent": "Mozilla/5.0 DevDeployPreview",
                "Authorization": "Bearer secret",
                "Cookie": "session=secret",
                "Host": "attacker.example",
                "Connection": "keep-alive",
                "X-Forwarded-Host": "attacker.example",
                "Proxy-Authorization": "Basic secret",
            },
        )

        headers = FakeHttpConnection.instances[0].requests[0][3]
        self.assertEqual(
            headers,
            {
                "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
                "Accept-Language": "tr-TR,tr;q=0.9,en-US;q=0.8",
                "User-Agent": "Mozilla/5.0 DevDeployPreview",
            },
        )
        for blocked_header in (
            "Authorization",
            "Cookie",
            "Host",
            "Connection",
            "X-Forwarded-Host",
            "Proxy-Authorization",
        ):
            self.assertNotIn(blocked_header, headers)

    def test_generic_accept_uses_browser_default(self) -> None:
        headers = KubernetesServiceProxyClient.browser_content_negotiation_headers(
            {"Accept": "*/*"}
        )

        self.assertEqual(headers, {"Accept": BROWSER_PREVIEW_ACCEPT})

    def test_json_accept_uses_browser_default_for_preview_route(self) -> None:
        headers = KubernetesServiceProxyClient.browser_content_negotiation_headers(
            {"Accept": "application/json"}
        )

        self.assertEqual(headers, {"Accept": BROWSER_PREVIEW_ACCEPT})

    def test_unsafe_browser_header_values_are_not_forwarded(self) -> None:
        headers = KubernetesServiceProxyClient.browser_content_negotiation_headers(
            {
                "Accept": "text/html\r\nAuthorization: Bearer secret",
                "Accept-Language": "en-US\nCookie: secret",
                "User-Agent": "",
            }
        )

        self.assertEqual(headers, {"Accept": BROWSER_PREVIEW_ACCEPT})

    def test_kubernetes_preview_transport_forwards_post_body_and_safe_headers(self) -> None:
        proxy_client, _, _ = make_preview_client()

        proxy_client.request(
            namespace="devdeploy-apps",
            service_name="podinfo",
            port=9898,
            path="api/echo",
            method="POST",
            body=b'{"message":"hello"}',
            request_headers={
                "Accept": "application/json",
                "Content-Type": "application/json; charset=UTF-8",
                "X-APP": "preview-test",
                "Cookie": "secret=session",
                "Authorization": "Bearer secret",
                "X-Forwarded-Host": "attacker.example",
            },
        )

        request = FakeHttpConnection.instances[0].requests[0]
        self.assertEqual(request[0], "POST")
        self.assertEqual(request[1], "/api/echo")
        self.assertEqual(request[2], b'{"message":"hello"}')
        self.assertEqual(
            request[3],
            {
                "Accept": BROWSER_PREVIEW_ACCEPT,
                "Content-Type": "application/json; charset=UTF-8",
                "X-APP": "preview-test",
            },
        )
    def test_kubernetes_preview_transport_encodes_relative_subpaths(self) -> None:
        proxy_client, _, _ = make_preview_client()

        proxy_client.get(
            namespace="devdeploy-apps",
            service_name="podinfo",
            port=9898,
            path="assets/app css/main.css",
        )

        self.assertEqual(
            FakeHttpConnection.instances[0].requests[0][1],
            "/assets/app%20css/main.css",
        )

    def test_kubernetes_rbac_forbidden_is_reported_as_preview_forbidden(self) -> None:
        proxy_client, _, _ = make_preview_client()
        proxy_client.core_v1.raise_on_list = ApiException(status=403, reason="Forbidden")

        with self.assertRaises(PreviewForbiddenError):
            proxy_client.get(
                namespace="devdeploy-apps",
                service_name="podinfo",
                port=9898,
                path="",
            )

    def test_upstream_status_and_content_type_are_preserved(self) -> None:
        proxy_client, _, _ = make_preview_client()
        FakeHttpConnection.response = FakeHttpResponse(
            status=404,
            body=b"not found",
            headers=[("Content-Type", "text/plain")],
        )

        response = proxy_client.get(
            namespace="devdeploy-apps",
            service_name="podinfo",
            port=9898,
            path="ui",
        )

        self.assertEqual(response.status_code, 404)
        self.assertEqual(response.body, b"not found")
        self.assertEqual(response.headers["Content-Type"], "text/plain")
        self.assertEqual(FakeHttpConnection.instances[0].requests[0][1], "/ui")

    def test_no_ready_pod_is_service_unavailable(self) -> None:
        proxy_client, _, _ = make_preview_client()
        proxy_client.core_v1.pod_list = type("EmptyPodList", (), {"items": []})()

        with self.assertRaises(PreviewServiceUnavailableError):
            proxy_client.get(
                namespace="devdeploy-apps",
                service_name="podinfo",
                port=9898,
                path="",
            )

    def test_transport_failure_is_service_unavailable(self) -> None:
        proxy_client, _, _ = make_preview_client()

        def failing_portforward_factory(*args, **kwargs):
            raise OSError("raw kubeconfig endpoint detail")

        proxy_client.portforward_factory = failing_portforward_factory

        with self.assertRaises(PreviewServiceUnavailableError):
            proxy_client.get(
                namespace="devdeploy-apps",
                service_name="podinfo",
                port=9898,
                path="",
            )


if __name__ == "__main__":
    unittest.main()
