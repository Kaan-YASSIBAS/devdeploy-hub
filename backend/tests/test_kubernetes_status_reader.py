import inspect
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

from kubernetes.client.exceptions import ApiException

from app.api.v1.endpoints.gitops import get_gitops_status_service
from app.core.config import settings
from app.services.gitops.kubernetes_status_reader import KubernetesGitOpsStatusReader
from app.services.gitops.status_reader import (
    GitOpsStatusError,
    GitOpsStatusRequest,
    UnavailableGitOpsStatusReader,
)


COMMIT_SHA = "a" * 40


class FakeCustomObjectsApi:
    def __init__(self, application=None, error: ApiException | None = None):
        self.application = application
        self.error = error
        self.calls = []

    def get_namespaced_custom_object(self, **kwargs):
        self.calls.append(kwargs)
        if self.error is not None:
            raise self.error
        return self.application


class FakeAppsApi:
    def __init__(self, deployments=None, error: ApiException | None = None):
        self.deployments = deployments or []
        self.error = error
        self.calls = []

    def list_namespaced_deployment(self, **kwargs):
        self.calls.append(kwargs)
        if self.error is not None:
            raise self.error
        return SimpleNamespace(items=self.deployments)


class FakeCoreApi:
    def __init__(self, services=None, pods=None, error: ApiException | None = None):
        self.services = services or []
        self.pods = pods or []
        self.error = error
        self.service_calls = []
        self.pod_calls = []

    def list_namespaced_service(self, **kwargs):
        self.service_calls.append(kwargs)
        if self.error is not None:
            raise self.error
        return SimpleNamespace(items=self.services)

    def list_namespaced_pod(self, **kwargs):
        self.pod_calls.append(kwargs)
        if self.error is not None:
            raise self.error
        return SimpleNamespace(items=self.pods)


def root_application(*, conditions=None) -> dict:
    return {
        "metadata": {"name": "devdeploy-workloads-root", "namespace": "argocd"},
        "status": {
            "sync": {"status": "Synced", "revision": COMMIT_SHA},
            "health": {"status": "Healthy"},
            "conditions": conditions or [],
        },
    }


def deployment() -> SimpleNamespace:
    return SimpleNamespace(
        metadata=SimpleNamespace(name="payment-api", generation=3),
        spec=SimpleNamespace(
            replicas=1,
            template=SimpleNamespace(
                spec=SimpleNamespace(
                    containers=[
                        SimpleNamespace(
                            name="payment-api",
                            image="ghcr.io/example/payment-api:v1",
                            ports=[SimpleNamespace(name="http", container_port=8080)],
                        )
                    ]
                )
            ),
        ),
        status=SimpleNamespace(
            ready_replicas=1,
            available_replicas=1,
            updated_replicas=1,
            observed_generation=3,
            conditions=[],
        ),
    )


def service() -> SimpleNamespace:
    return SimpleNamespace(
        metadata=SimpleNamespace(name="payment-api"),
        spec=SimpleNamespace(
            type="ClusterIP",
            cluster_ip="10.96.0.10",
            ports=[SimpleNamespace(name="http", port=80, target_port="http", protocol="TCP")],
        ),
    )


def pod(
    *,
    name: str = "payment-api-abc",
    phase: str = "Running",
    ready: bool = True,
    restart_count: int = 0,
    waiting_reason: str | None = None,
) -> SimpleNamespace:
    waiting = SimpleNamespace(reason=waiting_reason) if waiting_reason else None
    return SimpleNamespace(
        metadata=SimpleNamespace(
            name=name,
            labels={"app.kubernetes.io/name": name.split("-abc", 1)[0]},
        ),
        status=SimpleNamespace(
            phase=phase,
            conditions=[SimpleNamespace(type="Ready", status="True" if ready else "False")],
            container_statuses=[
                SimpleNamespace(
                    restart_count=restart_count,
                    state=SimpleNamespace(waiting=waiting),
                )
            ],
        ),
    )


class KubernetesGitOpsStatusReaderTestCase(unittest.TestCase):
    def setUp(self) -> None:
        self.request = GitOpsStatusRequest(app_name="payment-api", commit_sha=COMMIT_SHA)
        self.custom_api = FakeCustomObjectsApi(root_application())
        self.apps_api = FakeAppsApi([deployment()])
        self.core_api = FakeCoreApi([service()], [pod()])
        self.reader = KubernetesGitOpsStatusReader(
            management_custom_api=self.custom_api,
            workload_apps_api=self.apps_api,
            workload_core_api=self.core_api,
        )

    def test_ready_snapshot_maps_root_deployment_service_and_pods(self) -> None:
        result = self.reader.read(self.request)

        self.assertTrue(result.root_application.exists)
        self.assertEqual(result.root_application.observed_revision, COMMIT_SHA)
        self.assertEqual(result.root_application.sync_status, "Synced")
        self.assertEqual(result.root_application.health_status, "Healthy")
        self.assertTrue(result.workload.deployment_exists)
        self.assertEqual(result.workload.deployment_image, "ghcr.io/example/payment-api:v1")
        self.assertEqual(result.workload.container_port, 8080)
        self.assertEqual(result.workload.desired_replicas, 1)
        self.assertEqual(result.workload.ready_replicas, 1)
        self.assertEqual(result.workload.available_replicas, 1)
        self.assertEqual(result.workload.updated_replicas, 1)
        self.assertEqual(result.workload.generation, 3)
        self.assertEqual(result.workload.observed_generation, 3)
        self.assertTrue(result.workload.service_exists)
        self.assertTrue(result.workload.expected_service_port_exists)
        self.assertEqual(result.workload.service_type, "ClusterIP")
        self.assertEqual(result.workload.service_cluster_ip, "10.96.0.10")
        self.assertEqual(result.workload.service_ports[0].port, 80)
        self.assertEqual(result.workload.service_ports[0].target_port, "http")
        self.assertEqual(result.workload.pod_count, 1)
        self.assertEqual(result.workload.running_pod_count, 1)
        self.assertEqual(result.workload.ready_pod_count, 1)

        expected_selector = (
            "app.kubernetes.io/name=payment-api,"
            "app.kubernetes.io/managed-by=devdeploy,"
            "app.kubernetes.io/part-of=devdeploy-workloads"
        )
        self.assertEqual(self.apps_api.calls[0]["label_selector"], expected_selector)
        self.assertEqual(self.core_api.service_calls[0]["label_selector"], expected_selector)
        self.assertEqual(self.core_api.pod_calls[0]["label_selector"], expected_selector)

    def test_reader_contains_no_mutation_or_secret_read_operations(self) -> None:
        source = inspect.getsource(KubernetesGitOpsStatusReader)
        forbidden_operations = (
            "create_namespaced_",
            "delete_namespaced_",
            "patch_namespaced_",
            "read_namespaced_secret",
            "replace_namespaced_",
            "update_namespaced_",
        )

        for operation in forbidden_operations:
            with self.subTest(operation=operation):
                self.assertNotIn(operation, source)

    def test_pod_restart_and_waiting_reason_are_safely_summarized(self) -> None:
        self.core_api.pods = [
            pod(
                phase="Running",
                ready=False,
                restart_count=4,
                waiting_reason="CrashLoopBackOff",
            )
        ]

        result = self.reader.read(self.request)

        self.assertEqual(result.workload.restart_count, 4)
        self.assertEqual(result.workload.waiting_reasons, ("CrashLoopBackOff",))
        self.assertEqual(result.workload.pod_phases, ("Running",))
        self.assertTrue(result.workload.failure_detected)
        self.assertTrue(result.workload.pod_crashloop_detected)

    def test_unknown_waiting_reason_is_not_returned_raw(self) -> None:
        self.core_api.pods = [pod(ready=False, waiting_reason="credential-shaped-raw-reason")]

        result = self.reader.read(self.request)

        self.assertEqual(result.workload.waiting_reasons, ("Unknown",))

    def test_missing_workload_resources_produce_safe_empty_snapshot(self) -> None:
        self.apps_api.deployments = []
        self.core_api.services = []
        self.core_api.pods = []

        result = self.reader.read(self.request)

        self.assertFalse(result.workload.deployment_exists)
        self.assertFalse(result.workload.service_exists)
        self.assertEqual(result.workload.pod_count, 0)
        self.assertEqual(result.workload.ready_pod_count, 0)

    def test_missing_root_application_does_not_query_workload(self) -> None:
        self.custom_api.error = ApiException(status=404, reason="not found")

        result = self.reader.read(self.request)

        self.assertFalse(result.root_application.exists)
        self.assertEqual(self.apps_api.calls, [])
        self.assertEqual(self.core_api.service_calls, [])
        self.assertEqual(self.core_api.pod_calls, [])

    def test_workload_only_read_does_not_require_root_application(self) -> None:
        self.custom_api.error = ApiException(status=404, reason="not found")

        result = self.reader.read_workload("payment-api", "devdeploy-apps")

        self.assertTrue(result.deployment_exists)
        self.assertTrue(result.service_exists)
        self.assertEqual(self.custom_api.calls, [])
        self.assertEqual(len(self.apps_api.calls), 1)

    def test_namespace_discovery_returns_named_read_only_snapshots(self) -> None:
        result = self.reader.discover_workloads("devdeploy-apps")

        self.assertEqual(len(result), 1)
        self.assertEqual(result[0].name, "payment-api")
        self.assertTrue(result[0].workload.deployment_exists)
        self.assertTrue(result[0].workload.service_exists)
        self.assertEqual(result[0].workload.ready_pod_count, 1)
        self.assertNotIn("label_selector", self.apps_api.calls[0])
        self.assertNotIn("label_selector", self.core_api.service_calls[0])

    def test_forbidden_api_error_maps_to_permission_denied(self) -> None:
        self.custom_api.error = ApiException(status=403, reason="raw forbidden detail")

        with self.assertRaises(GitOpsStatusError) as raised:
            self.reader.read(self.request)

        self.assertEqual(raised.exception.code, "permission_denied")
        self.assertNotIn("raw forbidden detail", raised.exception.message)

    def test_cluster_api_error_maps_to_reader_unavailable(self) -> None:
        self.apps_api.error = ApiException(status=500, reason="raw server body")

        with self.assertRaises(GitOpsStatusError) as raised:
            self.reader.read(self.request)

        self.assertEqual(raised.exception.code, "status_reader_unavailable")
        self.assertNotIn("raw server body", raised.exception.message)

    def test_workload_kubeconfig_is_required_when_not_in_cluster(self) -> None:
        with self.assertRaises(GitOpsStatusError) as raised:
            KubernetesGitOpsStatusReader.from_server_config(
                management_kubeconfig=None,
                management_kubeconfig_context=None,
                workload_kubeconfig=None,
                workload_kubeconfig_context=None,
                use_in_cluster_management=False,
            )

        self.assertEqual(raised.exception.code, "status_reader_unavailable")

    @patch("app.services.gitops.kubernetes_status_reader.client.CoreV1Api")
    @patch("app.services.gitops.kubernetes_status_reader.client.AppsV1Api")
    @patch("app.services.gitops.kubernetes_status_reader.client.CustomObjectsApi")
    @patch("app.services.gitops.kubernetes_status_reader.client.ApiClient")
    @patch("app.services.gitops.kubernetes_status_reader.config.load_kube_config")
    @patch("app.services.gitops.kubernetes_status_reader.config.load_incluster_config")
    def test_management_incluster_and_workload_kubeconfig_configuration(
        self,
        load_incluster_config,
        load_kube_config,
        api_client,
        custom_objects_api,
        apps_api,
        core_api,
    ) -> None:
        def configure_incluster(*, client_configuration, **kwargs):
            _ = kwargs
            client_configuration.api_key["authorization"] = "test-only-value"

        load_incluster_config.side_effect = configure_incluster
        api_client.side_effect = ["management-client", "workload-client"]

        reader = KubernetesGitOpsStatusReader.from_server_config(
            management_kubeconfig=None,
            management_kubeconfig_context="kind-devdeploy-mgmt",
            workload_kubeconfig="workload-kubeconfig.yaml",
            workload_kubeconfig_context="kind-devdeploy-workload",
            use_in_cluster_management=True,
        )

        load_incluster_config.assert_called_once()
        self.assertEqual(
            load_kube_config.call_args.kwargs["config_file"],
            str(Path("workload-kubeconfig.yaml").expanduser()),
        )
        self.assertEqual(
            load_kube_config.call_args.kwargs["context"],
            "kind-devdeploy-workload",
        )
        custom_objects_api.assert_called_once_with("management-client")
        apps_api.assert_called_once_with("workload-client")
        core_api.assert_called_once_with("workload-client")
        self.assertIs(reader.management_custom_api, custom_objects_api.return_value)

    @patch("app.services.gitops.kubernetes_status_reader.client.CoreV1Api")
    @patch("app.services.gitops.kubernetes_status_reader.client.AppsV1Api")
    @patch("app.services.gitops.kubernetes_status_reader.client.CustomObjectsApi")
    @patch("app.services.gitops.kubernetes_status_reader.client.ApiClient")
    @patch("app.services.gitops.kubernetes_status_reader.config.load_kube_config")
    def test_explicit_management_and_workload_contexts_are_selected(
        self,
        load_kube_config,
        api_client,
        custom_objects_api,
        apps_api,
        core_api,
    ) -> None:
        api_client.side_effect = ["management-client", "workload-client"]

        KubernetesGitOpsStatusReader.from_server_config(
            management_kubeconfig="shared-kubeconfig.yaml",
            management_kubeconfig_context="kind-devdeploy-mgmt",
            workload_kubeconfig="shared-kubeconfig.yaml",
            workload_kubeconfig_context="kind-devdeploy-workload",
            use_in_cluster_management=False,
        )

        self.assertEqual(load_kube_config.call_count, 2)
        management_call, workload_call = load_kube_config.call_args_list
        self.assertEqual(management_call.kwargs["context"], "kind-devdeploy-mgmt")
        self.assertEqual(workload_call.kwargs["context"], "kind-devdeploy-workload")
        self.assertEqual(
            management_call.kwargs["config_file"],
            str(Path("shared-kubeconfig.yaml").expanduser()),
        )
        self.assertEqual(
            workload_call.kwargs["config_file"],
            str(Path("shared-kubeconfig.yaml").expanduser()),
        )
        custom_objects_api.assert_called_once_with("management-client")
        apps_api.assert_called_once_with("workload-client")
        core_api.assert_called_once_with("workload-client")

    @patch("app.services.gitops.kubernetes_status_reader.client.ApiClient")
    @patch("app.services.gitops.kubernetes_status_reader.config.load_kube_config")
    def test_token_kubeconfig_is_normalized_for_generated_api_clients(
        self,
        load_kube_config,
        api_client,
    ) -> None:
        def configure_token(*, client_configuration, **kwargs):
            _ = kwargs
            client_configuration.api_key["authorization"] = "Bearer raw-test-token"

        load_kube_config.side_effect = configure_token

        KubernetesGitOpsStatusReader._build_api_client(
            kubeconfig_path="workload-kubeconfig.yaml",
            kubeconfig_context="devdeploy-workload-observability",
            allow_in_cluster=False,
        )

        configuration = api_client.call_args.args[0]
        self.assertEqual(configuration.api_key["authorization"], "raw-test-token")
        self.assertEqual(configuration.api_key_prefix["authorization"], "Bearer")
        self.assertEqual(configuration.api_key["BearerToken"], "raw-test-token")
        self.assertEqual(configuration.api_key_prefix["BearerToken"], "Bearer")

    @patch("app.services.gitops.kubernetes_status_reader.client.ApiClient")
    @patch("app.services.gitops.kubernetes_status_reader.config.load_kube_config")
    def test_empty_context_preserves_default_kubeconfig_behavior(
        self,
        load_kube_config,
        api_client,
    ) -> None:
        KubernetesGitOpsStatusReader._build_api_client(
            kubeconfig_path="shared-kubeconfig.yaml",
            kubeconfig_context="",
            allow_in_cluster=False,
        )

        self.assertNotIn("context", load_kube_config.call_args.kwargs)
        api_client.assert_called_once()

    @patch("app.services.gitops.kubernetes_status_reader.client.CoreV1Api")
    @patch("app.services.gitops.kubernetes_status_reader.client.AppsV1Api")
    @patch("app.services.gitops.kubernetes_status_reader.client.ApiClient")
    @patch("app.services.gitops.kubernetes_status_reader.config.load_kube_config")
    def test_workload_only_reader_uses_server_controlled_context(
        self,
        load_kube_config,
        api_client,
        apps_api,
        core_api,
    ) -> None:
        api_client.return_value = "workload-client"

        reader = KubernetesGitOpsStatusReader.from_workload_server_config(
            workload_kubeconfig="shared-kubeconfig.yaml",
            workload_kubeconfig_context="kind-devdeploy-workload",
        )

        self.assertEqual(
            load_kube_config.call_args.kwargs["context"],
            "kind-devdeploy-workload",
        )
        apps_api.assert_called_once_with("workload-client")
        core_api.assert_called_once_with("workload-client")
        self.assertIsNone(reader.management_custom_api)


class GitOpsStatusServiceFactoryTestCase(unittest.TestCase):
    def tearDown(self) -> None:
        get_gitops_status_service.cache_clear()

    def test_unavailable_mode_keeps_safe_reader(self) -> None:
        with patch.object(settings, "status_reader_mode", "unavailable"):
            get_gitops_status_service.cache_clear()
            service = get_gitops_status_service()

        self.assertIsInstance(service.reader, UnavailableGitOpsStatusReader)

    @patch("app.api.v1.endpoints.gitops.KubernetesGitOpsStatusReader.from_server_config")
    def test_kubernetes_mode_uses_server_controlled_live_reader(self, from_server_config) -> None:
        live_reader = object()
        from_server_config.return_value = live_reader
        with (
            patch.object(settings, "status_reader_mode", "kubernetes"),
            patch.object(settings, "management_kubeconfig", "mgmt.yaml"),
            patch.object(settings, "management_kubeconfig_context", "kind-devdeploy-mgmt"),
            patch.object(settings, "observability_workload_kubeconfig", "workload.yaml"),
            patch.object(
                settings,
                "observability_workload_kubeconfig_context",
                "kind-devdeploy-workload",
            ),
            patch.object(settings, "kubernetes_in_cluster", False),
        ):
            get_gitops_status_service.cache_clear()
            service = get_gitops_status_service()

        from_server_config.assert_called_once_with(
            management_kubeconfig="mgmt.yaml",
            management_kubeconfig_context="kind-devdeploy-mgmt",
            workload_kubeconfig="workload.yaml",
            workload_kubeconfig_context="kind-devdeploy-workload",
            use_in_cluster_management=False,
        )
        self.assertIs(service.reader, live_reader)


if __name__ == "__main__":
    unittest.main()
