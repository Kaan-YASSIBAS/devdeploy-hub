import unittest

from kubernetes.client.exceptions import ApiException

from app.services.deployment_preview_service import (
    DeploymentPreviewService,
    KubernetesServiceProxyClient,
    NoRedirectPoolManager,
    PreviewForbiddenError,
    PreviewPathError,
    PreviewServiceUnavailableError,
    PreviewUpstreamError,
)


class FakePoolManager:
    def __init__(self):
        self.calls = []

    def request(self, *args, **kwargs):
        self.calls.append((args, kwargs))
        return object()


class FakeRawResponse:
    status = 200
    headers = {"Content-Type": "text/html"}

    def __init__(self):
        self.released = False

    def read(self, size, decode_content=True):
        return b"<html>nginx</html>"

    def release_conn(self):
        self.released = True


class FakeRestClient:
    def __init__(self):
        self.pool_manager = FakePoolManager()


class FakeApiClient:
    def __init__(self):
        self.rest_client = FakeRestClient()
        self.calls = []
        self.response = FakeRawResponse()

    def select_header_accept(self, values):
        return values[0]

    def call_api(self, *args, **kwargs):
        self.calls.append((args, kwargs))
        return self.response


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
            DeploymentPreviewService._safe_content_type(
                {"Content-Type": "text/html; charset=utf-8"}
            ),
            "text/html",
        )

    def test_rejects_unsafe_content_type_header(self) -> None:
        with self.assertRaises(PreviewUpstreamError):
            DeploymentPreviewService._safe_content_type(
                {"Content-Type": "text/html\r\nSet-Cookie: attacker=1"}
            )

    def test_kubernetes_transport_never_follows_redirects(self) -> None:
        delegate = FakePoolManager()
        manager = NoRedirectPoolManager(delegate)

        manager.request("GET", "https://kubernetes.example/proxy")

        self.assertEqual(len(delegate.calls), 1)
        self.assertFalse(delegate.calls[0][1]["redirect"])

    def test_kubernetes_service_proxy_uses_exact_root_proxy_path(self) -> None:
        api_client = FakeApiClient()
        proxy_client = KubernetesServiceProxyClient(api_client)

        response = proxy_client.get(
            namespace="devdeploy-apps",
            service_name="smoke-nginx",
            port=80,
            path="",
        )

        args, kwargs = api_client.calls[0]
        self.assertEqual(
            args[0],
            "/api/v1/namespaces/devdeploy-apps/services/smoke-nginx:80/proxy/",
        )
        self.assertEqual(args[1], "GET")
        self.assertEqual(kwargs["_preload_content"], False)
        self.assertEqual(kwargs["_request_timeout"], (2, 5))
        self.assertEqual(response.body, b"<html>nginx</html>")

    def test_kubernetes_service_proxy_encodes_relative_subpaths(self) -> None:
        self.assertEqual(
            KubernetesServiceProxyClient._service_proxy_resource_path(
                namespace="devdeploy-apps",
                service_name="smoke-nginx",
                port=80,
                path="assets/app css/main.css",
            ),
            "/api/v1/namespaces/devdeploy-apps/services/smoke-nginx:80/proxy/assets/app%20css/main.css",
        )

    def test_kubernetes_rbac_forbidden_is_not_reported_as_upstream_forbidden(self) -> None:
        api_client = FakeApiClient()
        error = ApiException(status=403, reason="Forbidden")
        error.body = (
            '{"kind":"Status","status":"Failure","reason":"Forbidden","code":403}'
        )
        api_client.call_api = lambda *args, **kwargs: (_ for _ in ()).throw(error)

        with self.assertRaises(PreviewForbiddenError):
            KubernetesServiceProxyClient(api_client).get(
                namespace="devdeploy-apps",
                service_name="smoke-nginx",
                port=80,
                path="",
            )

    def test_upstream_403_is_preserved_as_an_upstream_response(self) -> None:
        api_client = FakeApiClient()
        error = ApiException(status=403, reason="Forbidden")
        error.body = "app-specific forbidden"
        api_client.call_api = lambda *args, **kwargs: (_ for _ in ()).throw(error)

        response = KubernetesServiceProxyClient(api_client).get(
            namespace="devdeploy-apps",
            service_name="smoke-nginx",
            port=80,
            path="",
        )

        self.assertEqual(response.status_code, 403)
        self.assertEqual(response.body, b"Preview upstream returned HTTP 403.")

    def test_upstream_500_is_preserved_as_an_upstream_response(self) -> None:
        api_client = FakeApiClient()
        error = ApiException(status=500, reason="Internal Server Error")
        error.body = "app-specific failure"
        api_client.call_api = lambda *args, **kwargs: (_ for _ in ()).throw(error)

        response = KubernetesServiceProxyClient(api_client).get(
            namespace="devdeploy-apps",
            service_name="smoke-nginx",
            port=80,
            path="",
        )

        self.assertEqual(response.status_code, 500)
        self.assertEqual(response.body, b"Preview upstream returned HTTP 500.")

    def test_kubernetes_500_status_is_service_unavailable(self) -> None:
        api_client = FakeApiClient()
        error = ApiException(status=500, reason="Internal Server Error")
        error.body = (
            '{"kind":"Status","status":"Failure",'
            '"reason":"InternalError","code":500}'
        )
        api_client.call_api = lambda *args, **kwargs: (_ for _ in ()).throw(error)

        with self.assertRaises(PreviewServiceUnavailableError):
            KubernetesServiceProxyClient(api_client).get(
                namespace="devdeploy-apps",
                service_name="smoke-nginx",
                port=80,
                path="",
            )

    def test_transport_failure_is_service_unavailable(self) -> None:
        api_client = FakeApiClient()
        api_client.call_api = lambda *args, **kwargs: (_ for _ in ()).throw(
            OSError("raw kubeconfig endpoint detail")
        )

        with self.assertRaises(PreviewServiceUnavailableError):
            KubernetesServiceProxyClient(api_client).get(
                namespace="devdeploy-apps",
                service_name="smoke-nginx",
                port=80,
                path="",
            )


if __name__ == "__main__":
    unittest.main()
