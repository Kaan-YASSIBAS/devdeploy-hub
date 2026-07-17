from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
import unittest
from unittest.mock import patch

from kubernetes import client

from app.services.gitops.kubernetes_status_reader import KubernetesGitOpsStatusReader
from app.services.kubernetes_service import KubernetesService
from app.services.platform_cluster_health import PlatformClusterHealthService


class KubernetesClientIsolationTestCase(unittest.TestCase):
    @staticmethod
    def _load_incluster(*, client_configuration, **kwargs) -> None:
        _ = kwargs
        client_configuration.host = "https://management.example:443"
        client_configuration.api_key["authorization"] = "bearer management-initial"
        refresh_count = {"value": 0}

        def refresh(configuration) -> None:
            refresh_count["value"] += 1
            configuration.api_key["authorization"] = (
                f"bearer management-rotated-{refresh_count['value']}"
            )

        client_configuration.refresh_api_key_hook = refresh

    @staticmethod
    def _load_workload(*, client_configuration, **kwargs) -> None:
        _ = kwargs
        client_configuration.host = "https://workload.example:6443"
        client_configuration.api_key["authorization"] = "Bearer workload-token"

    def _build_management(self) -> client.ApiClient:
        return KubernetesGitOpsStatusReader._build_api_client(
            kubeconfig_path=None,
            kubeconfig_context=None,
            allow_in_cluster=True,
        )

    def _build_workload(self) -> client.ApiClient:
        return KubernetesGitOpsStatusReader._build_api_client(
            kubeconfig_path="workload-kubeconfig.yaml",
            kubeconfig_context="devdeploy-workload-observability",
            allow_in_cluster=False,
        )

    def test_workload_load_cannot_change_existing_management_client(self) -> None:
        with (
            patch(
                "app.services.gitops.kubernetes_status_reader.config.load_incluster_config",
                side_effect=self._load_incluster,
            ),
            patch(
                "app.services.gitops.kubernetes_status_reader.config.load_kube_config",
                side_effect=self._load_workload,
            ),
        ):
            management = self._build_management()
            workload = self._build_workload()

        management_auth = management.configuration.auth_settings()["BearerToken"]["value"]
        self.assertEqual(management.configuration.host, "https://management.example:443")
        self.assertTrue(management_auth.startswith("Bearer management-rotated-"))
        self.assertEqual(workload.configuration.host, "https://workload.example:6443")
        self.assertEqual(
            workload.configuration.auth_settings()["BearerToken"]["value"],
            "Bearer workload-token",
        )

    def test_management_load_cannot_change_existing_workload_client(self) -> None:
        with (
            patch(
                "app.services.gitops.kubernetes_status_reader.config.load_incluster_config",
                side_effect=self._load_incluster,
            ),
            patch(
                "app.services.gitops.kubernetes_status_reader.config.load_kube_config",
                side_effect=self._load_workload,
            ),
        ):
            workload = self._build_workload()
            management = self._build_management()

        self.assertEqual(workload.configuration.host, "https://workload.example:6443")
        self.assertEqual(
            workload.configuration.api_key["BearerToken"],
            "workload-token",
        )
        self.assertEqual(management.configuration.host, "https://management.example:443")

    def test_rotating_management_token_updates_generated_bearer_token(self) -> None:
        with patch(
            "app.services.gitops.kubernetes_status_reader.config.load_incluster_config",
            side_effect=self._load_incluster,
        ):
            management = self._build_management()

        first = management.configuration.api_key["BearerToken"]
        auth_value = management.configuration.auth_settings()["BearerToken"]["value"]
        second = management.configuration.api_key["BearerToken"]

        self.assertNotEqual(first, second)
        self.assertEqual(auth_value, f"Bearer {second}")
        self.assertEqual(
            management.configuration.api_key["authorization"],
            management.configuration.api_key["BearerToken"],
        )

    def test_alternating_and_concurrent_auth_reads_are_order_independent(self) -> None:
        with (
            patch(
                "app.services.gitops.kubernetes_status_reader.config.load_incluster_config",
                side_effect=self._load_incluster,
            ),
            patch(
                "app.services.gitops.kubernetes_status_reader.config.load_kube_config",
                side_effect=self._load_workload,
            ),
        ):
            management = self._build_management()
            workload = self._build_workload()

        def read_identity(api_client: client.ApiClient) -> tuple[str, str]:
            auth = api_client.configuration.auth_settings()["BearerToken"]["value"]
            return api_client.configuration.host, auth

        clients = [management, workload] * 10
        with ThreadPoolExecutor(max_workers=4) as executor:
            identities = list(executor.map(read_identity, clients))

        for index, identity in enumerate(identities):
            if index % 2 == 0:
                self.assertEqual(identity[0], "https://management.example:443")
                self.assertTrue(identity[1].startswith("Bearer management-rotated-"))
            else:
                self.assertEqual(
                    identity,
                    ("https://workload.example:6443", "Bearer workload-token"),
                )

    def test_management_version_probe_stays_healthy_after_workload_probe(self) -> None:
        class IsolatedVersionApi:
            def __init__(self, api_client) -> None:
                self.api_client = api_client

            def get_code(self, **kwargs) -> object:
                _ = kwargs
                configuration = self.api_client.configuration
                auth = configuration.auth_settings()["BearerToken"]["value"]
                if configuration.host == "https://management.example:443":
                    if not auth.startswith("Bearer management-rotated-"):
                        raise AssertionError("management credentials were contaminated")
                elif configuration.host == "https://workload.example:6443":
                    if auth != "Bearer workload-token":
                        raise AssertionError("workload credentials were contaminated")
                else:
                    raise AssertionError("unexpected Kubernetes API host")
                return object()

        with (
            patch(
                "app.services.gitops.kubernetes_status_reader.config.load_incluster_config",
                side_effect=self._load_incluster,
            ),
            patch(
                "app.services.gitops.kubernetes_status_reader.config.load_kube_config",
                side_effect=self._load_workload,
            ),
            patch(
                "app.services.platform_cluster_health.client.VersionApi",
                IsolatedVersionApi,
            ),
        ):
            service = PlatformClusterHealthService.from_server_config(
                management_kubeconfig=None,
                management_kubeconfig_context=None,
                workload_kubeconfig="workload-kubeconfig.yaml",
                workload_kubeconfig_context="devdeploy-workload-observability",
                use_in_cluster_management=True,
            )

        service.workload_probe.check_api()
        health = service.read_health()

        self.assertEqual(health.management.status, "healthy")
        self.assertEqual(health.workload.status, "healthy")
        self.assertTrue(health.platform_ready)

    def test_builders_do_not_mutate_the_global_default_configuration(self) -> None:
        default_before = client.Configuration.get_default_copy()
        with (
            patch(
                "app.services.gitops.kubernetes_status_reader.config.load_incluster_config",
                side_effect=self._load_incluster,
            ),
            patch(
                "app.services.gitops.kubernetes_status_reader.config.load_kube_config",
                side_effect=self._load_workload,
            ),
        ):
            self._build_management()
            self._build_workload()
        default_after = client.Configuration.get_default_copy()

        self.assertEqual(default_after.host, default_before.host)
        self.assertEqual(default_after.api_key, default_before.api_key)

    def test_kubernetes_service_incluster_loader_uses_an_explicit_configuration(self) -> None:
        with (
            patch("app.services.kubernetes_service.settings.observability_access_mode", "direct"),
            patch("app.services.kubernetes_service.settings.kubernetes_in_cluster", True),
            patch(
                "app.services.kubernetes_service.config.load_incluster_config",
                side_effect=self._load_incluster,
            ) as load_incluster,
        ):
            api_client = KubernetesService()._get_api_client()

        self.assertIn("client_configuration", load_incluster.call_args.kwargs)
        self.assertEqual(api_client.configuration.host, "https://management.example:443")
        self.assertTrue(
            api_client.configuration.auth_settings()["BearerToken"]["value"].startswith(
                "Bearer management-rotated-"
            )
        )

    def test_backend_has_no_implicit_kubernetes_configuration_loaders(self) -> None:
        services_root = Path(__file__).parents[1] / "app" / "services"
        source = "\n".join(
            path.read_text(encoding="utf-8")
            for path in services_root.rglob("*.py")
        )

        self.assertNotIn("config.load_incluster_config()", source)
        self.assertNotIn("client.ApiClient()", source)


if __name__ == "__main__":
    unittest.main()
