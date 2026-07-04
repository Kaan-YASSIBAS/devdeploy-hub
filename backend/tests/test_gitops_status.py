import unittest

from fastapi import FastAPI
from fastapi.testclient import TestClient

from app.api.v1.endpoints.gitops import (
    GitOpsStatusReaderConfig,
    get_gitops_status_reader_config,
    get_gitops_status_service,
    router,
)
from app.core.deps import get_current_user
from app.services.gitops.status_reader import (
    GitOpsStatusError,
    GitOpsStatusEvaluator,
    GitOpsStatusRequest,
    GitOpsStatusService,
    GitOpsStatusSnapshot,
    RootApplicationSnapshot,
    WorkloadSnapshot,
)


COMMIT_SHA = "a" * 40


class StaticStatusReader:
    def __init__(
        self,
        snapshot: GitOpsStatusSnapshot | None = None,
        error: GitOpsStatusError | None = None,
    ):
        self.snapshot = snapshot
        self.error = error
        self.requests = []

    def read(self, request):
        self.requests.append(request)
        if self.error is not None:
            raise self.error
        if self.snapshot is None:
            raise AssertionError("Static status snapshot is not configured")
        return self.snapshot


def ready_workload() -> WorkloadSnapshot:
    return WorkloadSnapshot(
        deployment_exists=True,
        service_exists=True,
        desired_replicas=1,
        ready_replicas=1,
        available_replicas=1,
        updated_replicas=1,
        generation=2,
        observed_generation=2,
        expected_service_port_exists=True,
        pod_count=1,
        running_pod_count=1,
        ready_pod_count=1,
    )


def snapshot(
    *,
    exists: bool = True,
    observed_revision: str | None = COMMIT_SHA,
    sync_status: str | None = "Synced",
    health_status: str | None = "Healthy",
    workload: WorkloadSnapshot | None = None,
) -> GitOpsStatusSnapshot:
    return GitOpsStatusSnapshot(
        root_application=RootApplicationSnapshot(
            exists=exists,
            observed_revision=observed_revision,
            sync_status=sync_status,
            health_status=health_status,
        ),
        workload=workload or ready_workload(),
    )


class GitOpsStatusEvaluatorTestCase(unittest.TestCase):
    def setUp(self) -> None:
        self.request = GitOpsStatusRequest(app_name="payment-api", commit_sha=COMMIT_SHA)
        self.evaluator = GitOpsStatusEvaluator()

    def test_missing_observed_revision_is_pending(self) -> None:
        result = self.evaluator.evaluate(self.request, snapshot(observed_revision=None))

        self.assertEqual(result.status, "pushed_waiting_for_argocd")
        self.assertEqual(result.error_code, "argocd_revision_pending")
        self.assertFalse(result.root_application.observed_commit_match)

    def test_different_revision_is_pending_without_lexical_comparison(self) -> None:
        result = self.evaluator.evaluate(self.request, snapshot(observed_revision="f" * 40))

        self.assertEqual(result.status, "pushed_waiting_for_argocd")
        self.assertEqual(result.observed_revision, "f" * 40)

    def test_matching_revision_not_synced_is_observing(self) -> None:
        result = self.evaluator.evaluate(self.request, snapshot(sync_status="OutOfSync"))

        self.assertEqual(result.status, "argocd_observing")
        self.assertEqual(result.error_code, "argocd_out_of_sync")

    def test_synced_healthy_ready_workload_is_deployed(self) -> None:
        result = self.evaluator.evaluate(self.request, snapshot())

        self.assertEqual(result.status, "deployed")
        self.assertTrue(result.root_application.observed_commit_match)
        self.assertTrue(result.workload.deployment_ready)
        self.assertTrue(result.workload.service_ready)
        self.assertTrue(result.workload.pods_ready)

    def test_synced_healthy_unready_workload_is_progressing(self) -> None:
        progressing = WorkloadSnapshot(
            deployment_exists=True,
            service_exists=True,
            desired_replicas=1,
            ready_replicas=0,
            available_replicas=0,
            updated_replicas=1,
            generation=2,
            observed_generation=2,
            expected_service_port_exists=True,
            pod_count=1,
            running_pod_count=1,
            ready_pod_count=0,
        )

        result = self.evaluator.evaluate(self.request, snapshot(workload=progressing))

        self.assertEqual(result.status, "workload_progressing")
        self.assertEqual(result.error_code, "workload_pods_not_ready")

    def test_degraded_root_application_is_degraded(self) -> None:
        result = self.evaluator.evaluate(self.request, snapshot(health_status="Degraded"))

        self.assertEqual(result.status, "degraded")
        self.assertEqual(result.error_code, "argocd_degraded")

    def test_workload_crashloop_is_degraded(self) -> None:
        crashing = WorkloadSnapshot(
            deployment_exists=True,
            service_exists=True,
            desired_replicas=1,
            ready_replicas=0,
            available_replicas=0,
            updated_replicas=1,
            generation=1,
            observed_generation=1,
            expected_service_port_exists=True,
            pod_count=1,
            running_pod_count=1,
            ready_pod_count=0,
            pod_crashloop_detected=True,
        )

        result = self.evaluator.evaluate(self.request, snapshot(workload=crashing))

        self.assertEqual(result.status, "degraded")
        self.assertEqual(result.error_code, "workload_pod_crashloop")

    def test_missing_root_application_is_unknown(self) -> None:
        result = self.evaluator.evaluate(
            self.request,
            snapshot(exists=False, observed_revision=None, sync_status=None, health_status=None),
        )

        self.assertEqual(result.status, "unknown")
        self.assertEqual(result.error_code, "argocd_application_missing")


class GitOpsStatusApiTestCase(unittest.TestCase):
    def setUp(self) -> None:
        self.app = FastAPI()
        self.app.include_router(router, prefix="/api/v1")
        self.reader = StaticStatusReader(snapshot())
        self.status_service = GitOpsStatusService(reader=self.reader)
        self.config = GitOpsStatusReaderConfig(
            root_application_name="devdeploy-workloads-root",
            root_application_namespace="argocd",
            workload_namespace="devdeploy-apps",
        )
        self.app.dependency_overrides[get_gitops_status_reader_config] = lambda: self.config
        self.app.dependency_overrides[get_gitops_status_service] = lambda: self.status_service
        self.client = TestClient(self.app, raise_server_exceptions=False)

    def tearDown(self) -> None:
        self.client.close()

    def authenticate(self) -> None:
        self.app.dependency_overrides[get_current_user] = lambda: object()

    def get_status(self, app_name: str = "payment-api", commit_sha: str = COMMIT_SHA):
        return self.client.get(
            f"/api/v1/gitops/apps/{app_name}/status",
            params={"commit_sha": commit_sha},
        )

    def test_unauthenticated_request_is_rejected(self) -> None:
        response = self.get_status()

        self.assertEqual(response.status_code, 401)
        self.assertEqual(self.reader.requests, [])

    def test_invalid_app_name_is_rejected(self) -> None:
        self.authenticate()

        response = self.get_status(app_name="Invalid-App")

        self.assertEqual(response.status_code, 400)
        self.assertEqual(self.reader.requests, [])

    def test_invalid_commit_sha_is_rejected(self) -> None:
        self.authenticate()

        response = self.get_status(commit_sha="not-a-commit")

        self.assertEqual(response.status_code, 400)
        self.assertEqual(self.reader.requests, [])

    def test_api_request_cannot_override_server_cluster_contexts(self) -> None:
        self.authenticate()

        response = self.client.get(
            "/api/v1/gitops/apps/payment-api/status",
            params={
                "commit_sha": COMMIT_SHA,
                "management_kubeconfig_context": "untrusted-management-context",
                "workload_kubeconfig_context": "untrusted-workload-context",
            },
        )

        self.assertEqual(response.status_code, 200)
        self.assertEqual(len(self.reader.requests), 1)
        request = self.reader.requests[0]
        self.assertEqual(request.root_application_namespace, "argocd")
        self.assertEqual(request.namespace, "devdeploy-apps")
        self.assertFalse(hasattr(request, "management_kubeconfig_context"))
        self.assertFalse(hasattr(request, "workload_kubeconfig_context"))
        self.assertNotIn("kubeconfig_context", str(response.json()))

    def test_pending_status_is_returned_safely(self) -> None:
        self.authenticate()
        self.reader.snapshot = snapshot(observed_revision=None)

        response = self.get_status()

        self.assertEqual(response.status_code, 200)
        body = response.json()
        self.assertEqual(body["status"], "pushed_waiting_for_argocd")
        self.assertEqual(body["error_code"], "argocd_revision_pending")

    def test_matching_synced_healthy_ready_status_is_deployed(self) -> None:
        self.authenticate()

        response = self.get_status()

        self.assertEqual(response.status_code, 200)
        body = response.json()
        self.assertEqual(body["status"], "deployed")
        self.assertTrue(body["root_application"]["observed_commit_match"])
        self.assertTrue(body["workload"]["deployment_ready"])
        self.assertTrue(body["workload"]["service_ready"])
        self.assertTrue(body["workload"]["pods_ready"])

    def test_synced_healthy_unready_status_is_progressing(self) -> None:
        self.authenticate()
        self.reader.snapshot = snapshot(
            workload=WorkloadSnapshot(
                deployment_exists=True,
                service_exists=True,
                desired_replicas=1,
                ready_replicas=0,
                available_replicas=0,
                updated_replicas=1,
                generation=1,
                observed_generation=1,
                expected_service_port_exists=True,
                pod_count=1,
                running_pod_count=1,
                ready_pod_count=0,
            )
        )

        response = self.get_status()

        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json()["status"], "workload_progressing")

    def test_degraded_root_status_is_returned(self) -> None:
        self.authenticate()
        self.reader.snapshot = snapshot(health_status="Degraded")

        response = self.get_status()

        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json()["status"], "degraded")
        self.assertEqual(response.json()["error_code"], "argocd_degraded")

    def test_missing_application_returns_safe_error_code(self) -> None:
        self.authenticate()
        self.reader.snapshot = snapshot(
            exists=False,
            observed_revision=None,
            sync_status=None,
            health_status=None,
        )

        response = self.get_status()

        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json()["status"], "unknown")
        self.assertEqual(response.json()["error_code"], "argocd_application_missing")

    def test_reader_failure_is_sanitized_and_contains_no_sensitive_fields(self) -> None:
        self.authenticate()
        self.reader.error = GitOpsStatusError(
            "status_reader_unavailable",
            "token=raw-token kubeconfig=C:/sensitive full pod logs",
        )

        response = self.get_status()

        self.assertEqual(response.status_code, 503)
        body = response.json()
        self.assertEqual(body["status"], "unknown")
        self.assertEqual(body["error_code"], "status_reader_unavailable")
        response_text = str(body).lower()
        for forbidden in ("raw-token", "kubeconfig", "secret", "pod logs", "certificate", "private key"):
            self.assertNotIn(forbidden, response_text)

    def test_permission_denied_reader_failure_returns_forbidden(self) -> None:
        self.authenticate()
        self.reader.error = GitOpsStatusError("permission_denied", "raw cluster permission detail")

        response = self.get_status()

        self.assertEqual(response.status_code, 403)
        body = response.json()
        self.assertEqual(body["status"], "unknown")
        self.assertEqual(body["error_code"], "permission_denied")
        self.assertNotIn("raw cluster permission detail", str(body))


if __name__ == "__main__":
    unittest.main()
