import unittest
from types import SimpleNamespace
from unittest.mock import patch

from app.api.v1 import runtime_status
from app.api.v1.endpoints import platform


class WorkloadRuntimeKubeconfigContractTestCase(unittest.TestCase):
    def tearDown(self) -> None:
        runtime_status.get_workload_runtime_reader.cache_clear()
        runtime_status.get_workload_runtime_cleanup_client.cache_clear()
        platform.get_platform_cluster_health_service.cache_clear()

    def test_runtime_reader_uses_canonical_managed_workload_kubeconfig(self) -> None:
        configured = SimpleNamespace(
            status_reader_mode="kubernetes",
            resolved_observability_workload_kubeconfig=(
                "/var/run/devdeploy/workload-observability/kubeconfig"
            ),
            observability_workload_kubeconfig_context="devdeploy-workload-observability",
        )
        with (
            patch.object(runtime_status, "settings", configured),
            patch.object(
                runtime_status.KubernetesGitOpsStatusReader,
                "from_workload_server_config",
                return_value="reader",
            ) as factory,
        ):
            reader = runtime_status.get_workload_runtime_reader()

        self.assertEqual(reader, "reader")
        factory.assert_called_once_with(
            workload_kubeconfig="/var/run/devdeploy/workload-observability/kubeconfig",
            workload_kubeconfig_context="devdeploy-workload-observability",
        )

    def test_runtime_cleanup_uses_only_explicit_normal_workload_kubeconfig(self) -> None:
        configured = SimpleNamespace(
            status_reader_mode="kubernetes",
            resolved_workload_kubeconfig="/secure/runtime-cleanup-kubeconfig",
            resolved_workload_kubeconfig_context="devdeploy-runtime-cleanup",
            resolved_observability_workload_kubeconfig=(
                "/var/run/devdeploy/workload-observability/kubeconfig"
            ),
            observability_workload_kubeconfig_context="devdeploy-workload-observability",
        )
        with (
            patch.object(runtime_status, "settings", configured),
            patch.object(
                runtime_status.KubernetesWorkloadRuntimeCleanupClient,
                "from_server_config",
                return_value="cleanup-client",
            ) as factory,
        ):
            client = runtime_status.get_workload_runtime_cleanup_client()

        self.assertEqual(client, "cleanup-client")
        factory.assert_called_once_with(
            workload_kubeconfig="/secure/runtime-cleanup-kubeconfig",
            workload_kubeconfig_context="devdeploy-runtime-cleanup",
        )

    def test_cluster_health_uses_canonical_managed_workload_kubeconfig(self) -> None:
        configured = SimpleNamespace(
            management_kubeconfig=None,
            management_kubeconfig_context=None,
            resolved_observability_workload_kubeconfig=(
                "/var/run/devdeploy/workload-observability/kubeconfig"
            ),
            observability_workload_kubeconfig_context="devdeploy-workload-observability",
            kubernetes_in_cluster=True,
        )
        with (
            patch.object(platform, "settings", configured),
            patch.object(
                platform.PlatformClusterHealthService,
                "from_server_config",
                return_value="health-service",
            ) as factory,
        ):
            service = platform.get_platform_cluster_health_service()

        self.assertEqual(service, "health-service")
        factory.assert_called_once_with(
            management_kubeconfig=None,
            management_kubeconfig_context=None,
            workload_kubeconfig="/var/run/devdeploy/workload-observability/kubeconfig",
            workload_kubeconfig_context="devdeploy-workload-observability",
            use_in_cluster_management=True,
        )


if __name__ == "__main__":
    unittest.main()
