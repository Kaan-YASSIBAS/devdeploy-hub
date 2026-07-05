import tempfile
import unittest
from pathlib import Path

import yaml

from app.models.deployment_record import DeploymentRecord
from app.services.deployment_drift import DeploymentDriftService, GitOpsManifestReader
from app.services.gitops.manifests import generate_workload_manifests
from app.services.gitops.models import WorkloadWriteRequest
from app.services.gitops.status_reader import ServicePortSnapshot, WorkloadSnapshot


class FakeRuntimeStatusService:
    def __init__(self, snapshot: WorkloadSnapshot | None):
        self.snapshot = snapshot

    def workload_snapshot(self, app_name: str, namespace: str) -> WorkloadSnapshot | None:
        _ = (app_name, namespace)
        return self.snapshot


class DeploymentDriftServiceTestCase(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.repo_root = Path(self.temporary_directory.name)
        self.source_root = self.repo_root / "gitops" / "workloads" / "devdeploy-apps"
        self.app_dir = self.source_root / "apps" / "payments-api"
        self.app_dir.mkdir(parents=True)
        generated = generate_workload_manifests(
            WorkloadWriteRequest(
                app_name="payments-api",
                image="ghcr.io/example/payments:v1",
                replicas=2,
                container_port=8080,
                service_port=80,
            )
        )
        for name, content in generated.files.items():
            (self.app_dir / name).write_text(content, encoding="utf-8", newline="\n")
        (self.source_root / "kustomization.yaml").write_text(
            "apiVersion: kustomize.config.k8s.io/v1beta1\n"
            "kind: Kustomization\n"
            "resources:\n"
            "  - apps/payments-api\n",
            encoding="utf-8",
            newline="\n",
        )
        self.record = DeploymentRecord(
            id=1,
            owner_id=7,
            app_name="payments-api",
            image="ghcr.io/example/payments:v1",
            replicas=2,
            container_port=8080,
            service_port=80,
            service_type="ClusterIP",
            namespace="devdeploy-apps",
            gitops_manifest_path="gitops/workloads/devdeploy-apps/apps/payments-api",
            desired_state="pending",
        )

    def tearDown(self) -> None:
        self.temporary_directory.cleanup()

    def runtime_snapshot(self, **overrides) -> WorkloadSnapshot:
        values = {
            "deployment_exists": True,
            "service_exists": True,
            "deployment_image": "ghcr.io/example/payments:v1",
            "container_port": 8080,
            "desired_replicas": 2,
            "service_type": "ClusterIP",
            "service_ports": (ServicePortSnapshot("http", 80, "http", "TCP"),),
        }
        values.update(overrides)
        return WorkloadSnapshot(**values)

    def service(self, snapshot: WorkloadSnapshot | None = None) -> DeploymentDriftService:
        reader = GitOpsManifestReader(
            self.repo_root,
            "gitops/workloads/devdeploy-apps",
        )
        return DeploymentDriftService(
            manifest_reader=reader,
            runtime_service=FakeRuntimeStatusService(
                self.runtime_snapshot() if snapshot is None else snapshot
            ),
        )

    def update_yaml(self, name: str, update) -> None:
        path = self.app_dir / name
        document = yaml.safe_load(path.read_text(encoding="utf-8"))
        update(document)
        path.write_text(yaml.safe_dump(document, sort_keys=False), encoding="utf-8", newline="\n")

    def test_aligned_db_gitops_and_runtime_returns_aligned(self) -> None:
        result = self.service().evaluate(self.record)

        self.assertEqual(result.status, "aligned")
        self.assertEqual(result.db_to_gitops.status, "aligned")
        self.assertEqual(result.db_to_runtime.status, "aligned")
        self.assertEqual(result.db_to_gitops.differences, [])

    def test_gitops_image_mismatch_returns_typed_difference(self) -> None:
        self.update_yaml(
            "deployment.yaml",
            lambda document: document["spec"]["template"]["spec"]["containers"][0].update(
                {"image": "ghcr.io/example/payments:v0"}
            ),
        )

        result = self.service().evaluate(self.record)

        self.assertEqual(result.status, "drifted")
        difference = next(item for item in result.db_to_gitops.differences if item.field == "image")
        self.assertEqual(difference.expected, "ghcr.io/example/payments:v1")
        self.assertEqual(difference.actual, "ghcr.io/example/payments:v0")
        self.assertEqual(difference.source, "gitops")

    def test_gitops_replica_mismatch_returns_drifted(self) -> None:
        self.update_yaml(
            "deployment.yaml",
            lambda document: document["spec"].update({"replicas": 1}),
        )

        result = self.service().evaluate(self.record)

        self.assertEqual(result.status, "drifted")
        self.assertTrue(
            any(
                item.field == "replicas" and item.expected == 2 and item.actual == 1
                for item in result.db_to_gitops.differences
            )
        )

    def test_missing_required_gitops_state_returns_gitops_missing(self) -> None:
        for missing_path in (
            self.app_dir / "deployment.yaml",
            self.app_dir / "service.yaml",
            self.app_dir / "kustomization.yaml",
        ):
            with self.subTest(path=missing_path.name):
                content = missing_path.read_text(encoding="utf-8")
                missing_path.unlink()
                result = self.service().evaluate(self.record)
                self.assertEqual(result.status, "gitops_missing")
                self.assertEqual(result.db_to_gitops.status, "missing")
                missing_path.write_text(content, encoding="utf-8", newline="\n")

        root = self.source_root / "kustomization.yaml"
        root.write_text(
            "apiVersion: kustomize.config.k8s.io/v1beta1\nkind: Kustomization\nresources: []\n",
            encoding="utf-8",
            newline="\n",
        )
        result = self.service().evaluate(self.record)
        self.assertEqual(result.status, "gitops_missing")
        self.assertEqual(result.db_to_gitops.status, "missing")

    def test_runtime_missing_returns_runtime_missing(self) -> None:
        result = self.service(
            WorkloadSnapshot(deployment_exists=False, service_exists=False)
        ).evaluate(self.record)

        self.assertEqual(result.status, "runtime_missing")
        self.assertEqual(result.db_to_runtime.status, "missing")

    def test_runtime_image_and_replica_mismatch_returns_drifted(self) -> None:
        result = self.service(
            self.runtime_snapshot(
                deployment_image="ghcr.io/example/payments:v0",
                desired_replicas=1,
            )
        ).evaluate(self.record)

        self.assertEqual(result.status, "drifted")
        self.assertEqual(result.db_to_runtime.status, "drifted")
        self.assertEqual(
            {difference.field for difference in result.db_to_runtime.differences},
            {"image", "replicas"},
        )

    def test_runtime_lookup_failure_returns_unknown(self) -> None:
        result = DeploymentDriftService(
            manifest_reader=GitOpsManifestReader(
                self.repo_root,
                "gitops/workloads/devdeploy-apps",
            ),
            runtime_service=FakeRuntimeStatusService(None),
        ).evaluate(self.record)

        self.assertEqual(result.status, "unknown")
        self.assertEqual(result.db_to_runtime.status, "unknown")

    def test_malformed_yaml_returns_sanitized_unknown(self) -> None:
        (self.app_dir / "deployment.yaml").write_text(
            "spec: [unterminated",
            encoding="utf-8",
            newline="\n",
        )

        result = self.service().evaluate(self.record)

        self.assertEqual(result.status, "unknown")
        self.assertEqual(result.db_to_gitops.status, "unknown")
        self.assertNotIn("unterminated", result.message)

    def test_manifest_inspection_does_not_modify_files(self) -> None:
        before = {
            path.relative_to(self.repo_root): path.read_bytes()
            for path in self.source_root.rglob("*.yaml")
        }

        result = self.service().evaluate(self.record)

        after = {
            path.relative_to(self.repo_root): path.read_bytes()
            for path in self.source_root.rglob("*.yaml")
        }
        self.assertEqual(result.status, "aligned")
        self.assertEqual(after, before)


if __name__ == "__main__":
    unittest.main()
