from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from app.services.gitops.discovery import GitOpsAppDiscoveryService
from app.services.gitops.errors import GitOpsWriterError
from app.services.gitops.manifests import generate_workload_manifests
from app.services.gitops.models import WorkloadWriteRequest


SOURCE_ROOT_RELATIVE = "gitops/workloads/devdeploy-apps"


class GitOpsAppDiscoveryServiceTestCase(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.repo_root = Path(self.temporary_directory.name)
        self.source_root = self.repo_root / SOURCE_ROOT_RELATIVE
        self.apps_root = self.source_root / "apps"
        self.apps_root.mkdir(parents=True)
        self.service = GitOpsAppDiscoveryService()

    def tearDown(self) -> None:
        self.temporary_directory.cleanup()

    def _write_app(self, app_name: str, *, image: str = "nginx:latest") -> Path:
        app_dir = self.apps_root / app_name
        app_dir.mkdir()
        manifests = generate_workload_manifests(
            WorkloadWriteRequest(
                app_name=app_name,
                image=image,
                replicas=2,
                container_port=8080,
                service_port=80,
            )
        )
        for file_name, content in manifests.files.items():
            (app_dir / file_name).write_text(content, encoding="utf-8")
        return app_dir

    def _discover(self):
        return self.service.discover(
            repo_root=self.repo_root,
            source_root_relative=SOURCE_ROOT_RELATIVE,
        )

    def test_empty_apps_directory_returns_empty_list(self) -> None:
        self.assertEqual(self._discover(), [])

    def test_valid_generated_app_is_discovered(self) -> None:
        self._write_app("payment-api", image="ghcr.io/example/payment-api:v1")

        items = self._discover()

        self.assertEqual(len(items), 1)
        item = items[0]
        self.assertEqual(item.app_name, "payment-api")
        self.assertEqual(item.image, "ghcr.io/example/payment-api:v1")
        self.assertEqual(item.replicas, 2)
        self.assertEqual(item.container_port, 8080)
        self.assertEqual(item.service_port, 80)
        self.assertEqual(item.service_type, "ClusterIP")
        self.assertEqual(item.namespace, "devdeploy-apps")
        self.assertEqual(item.manifest_path, "apps/payment-api")
        self.assertEqual(item.status, "unknown")

    def test_invalid_hidden_and_incomplete_directories_are_ignored(self) -> None:
        (self.apps_root / ".hidden").mkdir()
        (self.apps_root / "Invalid-Name").mkdir()
        incomplete = self.apps_root / "incomplete-app"
        incomplete.mkdir()
        (incomplete / "deployment.yaml").write_text("kind: Deployment\n", encoding="utf-8")

        self.assertEqual(self._discover(), [])

    def test_malformed_yaml_does_not_break_other_apps(self) -> None:
        self._write_app("valid-app")
        malformed = self._write_app("malformed-app")
        (malformed / "deployment.yaml").write_text("spec: [\n", encoding="utf-8")

        items = self._discover()

        self.assertEqual([item.app_name for item in items], ["valid-app"])

    def test_directory_symlink_is_ignored_when_supported(self) -> None:
        outside = self.repo_root / "outside-app"
        outside.mkdir()
        link = self.apps_root / "linked-app"
        try:
            link.symlink_to(outside, target_is_directory=True)
        except OSError:
            self.skipTest("Directory symlinks are not available in this environment")

        self.assertEqual(self._discover(), [])

    def test_configured_source_path_traversal_is_rejected(self) -> None:
        with self.assertRaises(GitOpsWriterError) as raised:
            self.service.discover(
                repo_root=self.repo_root,
                source_root_relative="../outside",
            )

        self.assertEqual(raised.exception.code, "unsafe_path")

    def test_discovery_does_not_write_or_invoke_git(self) -> None:
        self._write_app("readonly-app")

        with (
            patch("pathlib.Path.write_text") as write_text,
            patch("app.services.gitops.git_adapter.GitAdapter.create_commit") as create_commit,
            patch("app.services.gitops.git_adapter.GitAdapter.push") as push,
        ):
            items = self._discover()

        self.assertEqual([item.app_name for item in items], ["readonly-app"])
        write_text.assert_not_called()
        create_commit.assert_not_called()
        push.assert_not_called()


if __name__ == "__main__":
    unittest.main()
