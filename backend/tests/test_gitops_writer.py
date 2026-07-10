from pathlib import Path
import tempfile
import unittest

import yaml

from app.services.gitops.errors import GitOpsWriterError
from app.services.gitops.kustomization import RootKustomizationEditor
from app.services.gitops.manifests import generate_workload_manifests
from app.services.gitops.models import WorkloadWriteRequest
from app.services.gitops.paths import GitOpsRepositoryPaths
from app.services.gitops.render import StructuralRenderValidator
from app.services.gitops.writer import GitOpsWorkloadWriter


ROOT_KUSTOMIZATION = """apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources: []
"""


class GitOpsWriterTestCase(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.source_root = Path(self.temporary_directory.name) / "gitops" / "workloads" / "devdeploy-apps"
        self.apps_root = self.source_root / "apps"
        self.apps_root.mkdir(parents=True)
        (self.source_root / "kustomization.yaml").write_text(ROOT_KUSTOMIZATION, encoding="utf-8")

    def tearDown(self) -> None:
        self.temporary_directory.cleanup()

    def assert_error_code(self, code: str, callback) -> None:
        with self.assertRaises(GitOpsWriterError) as raised:
            callback()
        self.assertEqual(raised.exception.code, code)

    def test_valid_request_uses_v1_defaults(self) -> None:
        request = WorkloadWriteRequest(app_name="payment-api", image="ghcr.io/example/payment-api:v1")

        self.assertEqual(request.replicas, 1)
        self.assertEqual(request.container_port, 80)
        self.assertEqual(request.service_port, 80)
        self.assertEqual(request.service_type, "ClusterIP")

    def test_invalid_app_names_are_rejected(self) -> None:
        invalid_names = ["Payment-api", "bad/name", "bad\\name", "..", ".hidden", "a" * 41]

        for name in invalid_names:
            with self.subTest(name=name):
                self.assert_error_code(
                    "invalid_app_name",
                    lambda name=name: WorkloadWriteRequest(app_name=name, image="nginx:1.27"),
                )

    def test_invalid_images_are_rejected(self) -> None:
        for image in ["", "nginx latest", "nginx:\nlatest"]:
            with self.subTest(image=image):
                self.assert_error_code(
                    "invalid_image",
                    lambda image=image: WorkloadWriteRequest(app_name="demo", image=image),
                )

    def test_invalid_replicas_are_rejected(self) -> None:
        for replicas in [0, 21, True]:
            with self.subTest(replicas=replicas):
                self.assert_error_code(
                    "invalid_replicas",
                    lambda replicas=replicas: WorkloadWriteRequest(
                        app_name="demo",
                        image="nginx:1.27",
                        replicas=replicas,
                    ),
                )

    def test_invalid_ports_are_rejected(self) -> None:
        for field_name, value in [("container_port", 0), ("container_port", 65536), ("service_port", 0)]:
            with self.subTest(field_name=field_name, value=value):
                arguments = {field_name: value}
                self.assert_error_code(
                    "invalid_port",
                    lambda arguments=arguments: WorkloadWriteRequest(
                        app_name="demo",
                        image="nginx:1.27",
                        **arguments,
                    ),
                )

    def test_invalid_service_type_is_rejected(self) -> None:
        self.assert_error_code(
            "invalid_service_type",
            lambda: WorkloadWriteRequest(
                app_name="demo",
                image="nginx:1.27",
                service_type="NodePort",
            ),
        )

    def test_safe_app_path_stays_inside_apps_root(self) -> None:
        paths = GitOpsRepositoryPaths.from_source_root(self.source_root)

        app_dir = paths.app_dir("nginx-demo")

        self.assertEqual(app_dir.parent, paths.apps_root)
        self.assertEqual(app_dir.name, "nginx-demo")

    def test_path_traversal_is_rejected(self) -> None:
        paths = GitOpsRepositoryPaths.from_source_root(self.source_root)

        self.assert_error_code("invalid_app_name", lambda: paths.app_dir("../outside"))

    def test_symlink_escape_is_rejected_when_supported(self) -> None:
        paths = GitOpsRepositoryPaths.from_source_root(self.source_root)
        outside = Path(self.temporary_directory.name) / "outside"
        outside.mkdir()
        link = self.apps_root / "escape"
        try:
            link.symlink_to(outside, target_is_directory=True)
        except OSError:
            self.skipTest("Directory symlinks are not available in this environment")

        self.assert_error_code("unsafe_path", lambda: paths.app_dir("escape"))

    def test_manifest_generation_matches_v1_contract(self) -> None:
        request = WorkloadWriteRequest(
            app_name="orders-api",
            image="registry.example.com/orders:v2",
            replicas=3,
            container_port=8080,
            service_port=80,
        )

        generated = generate_workload_manifests(request)
        deployment = yaml.safe_load(generated.files["deployment.yaml"])
        service = yaml.safe_load(generated.files["service.yaml"])
        kustomization = yaml.safe_load(generated.files["kustomization.yaml"])

        self.assertEqual(deployment["apiVersion"], "apps/v1")
        self.assertEqual(deployment["metadata"]["name"], "orders-api")
        self.assertEqual(deployment["metadata"]["namespace"], "devdeploy-apps")
        self.assertEqual(deployment["spec"]["replicas"], 3)
        self.assertEqual(
            deployment["spec"]["selector"]["matchLabels"],
            {"app.kubernetes.io/name": "orders-api"},
        )
        pod_security_context = deployment["spec"]["template"]["spec"]["securityContext"]
        self.assertTrue(pod_security_context["runAsNonRoot"])
        self.assertEqual(pod_security_context["runAsUser"], 101)
        self.assertEqual(pod_security_context["runAsGroup"], 101)
        self.assertEqual(pod_security_context["fsGroup"], 101)
        self.assertEqual(pod_security_context["seccompProfile"]["type"], "RuntimeDefault")
        container = deployment["spec"]["template"]["spec"]["containers"][0]
        self.assertEqual(container["image"], "registry.example.com/orders:v2")
        self.assertEqual(container["ports"][0]["containerPort"], 8080)
        self.assertFalse(container["securityContext"]["allowPrivilegeEscalation"])
        self.assertTrue(container["securityContext"]["readOnlyRootFilesystem"])
        self.assertIn("ALL", container["securityContext"]["capabilities"]["drop"])
        self.assertEqual(
            {mount["name"]: mount["mountPath"] for mount in container["volumeMounts"]},
            {
                "nginx-cache": "/var/cache/nginx",
                "nginx-run": "/var/run",
                "tmp": "/tmp",
            },
        )
        volumes = deployment["spec"]["template"]["spec"]["volumes"]
        self.assertEqual([volume["name"] for volume in volumes], ["nginx-cache", "nginx-run", "tmp"])
        self.assertTrue(all(volume["emptyDir"] == {} for volume in volumes))
        self.assertTrue(all("hostPath" not in volume for volume in volumes))
        self.assertEqual(service["spec"]["type"], "ClusterIP")
        self.assertEqual(service["spec"]["ports"][0]["port"], 80)
        self.assertEqual(service["spec"]["ports"][0]["targetPort"], "http")
        self.assertEqual(kustomization["resources"], ["deployment.yaml", "service.yaml"])
        self.assertNotIn("ingress.yaml", generated.files)
        self.assertTrue(all(content.endswith("\n") for content in generated.files.values()))
        self.assertEqual(generated, generate_workload_manifests(request))

    def test_root_kustomization_adds_app_once_and_sorts_resources(self) -> None:
        root_path = self.source_root / "kustomization.yaml"
        root_path.write_text(
            ROOT_KUSTOMIZATION.replace("resources: []", "resources:\n  - apps/zeta"),
            encoding="utf-8",
        )
        editor = RootKustomizationEditor(GitOpsRepositoryPaths.from_source_root(self.source_root))

        first = editor.add_app("alpha")
        root_path.write_text(first, encoding="utf-8")
        second = editor.add_app("alpha")
        document = yaml.safe_load(second)

        self.assertEqual(document["resources"], ["apps/alpha", "apps/zeta"])

    def test_root_kustomization_remove_last_app_uses_valid_empty_list(self) -> None:
        root_path = self.source_root / "kustomization.yaml"
        root_path.write_text(
            ROOT_KUSTOMIZATION.replace("resources: []", "resources:\n  - apps/only-app"),
            encoding="utf-8",
        )
        editor = RootKustomizationEditor(GitOpsRepositoryPaths.from_source_root(self.source_root))

        empty_content = editor.remove_app("only-app")
        empty_document = yaml.safe_load(empty_content)

        self.assertEqual(empty_document["resources"], [])
        self.assertIn("resources: []", empty_content)

        root_path.write_text(empty_content, encoding="utf-8")
        added_content = editor.add_app("new-app")
        self.assertEqual(yaml.safe_load(added_content)["resources"], ["apps/new-app"])

    def test_root_kustomization_rejects_unsafe_resource_entry(self) -> None:
        (self.source_root / "kustomization.yaml").write_text(
            ROOT_KUSTOMIZATION.replace("resources: []", "resources:\n  - ../outside"),
            encoding="utf-8",
        )
        editor = RootKustomizationEditor(GitOpsRepositoryPaths.from_source_root(self.source_root))

        self.assert_error_code("unsafe_kustomization_resource", lambda: editor.add_app("demo"))

    def test_writer_creates_only_operation_owned_files(self) -> None:
        unrelated_dir = self.apps_root / "unrelated"
        unrelated_dir.mkdir()
        unrelated_file = unrelated_dir / "keep.txt"
        unrelated_file.write_text("preserve me\n", encoding="utf-8")
        writer = GitOpsWorkloadWriter(self.source_root)
        request = WorkloadWriteRequest(app_name="nginx-demo", image="nginx:latest")

        result = writer.create(request)

        self.assertEqual([path.name for path in result.written_files], [
            "deployment.yaml",
            "service.yaml",
            "kustomization.yaml",
        ])
        self.assertTrue(all(path.is_file() for path in result.written_files))
        self.assertEqual(unrelated_file.read_text(encoding="utf-8"), "preserve me\n")
        root = yaml.safe_load((self.source_root / "kustomization.yaml").read_text(encoding="utf-8"))
        self.assertEqual(root["resources"], ["apps/nginx-demo"])

    def test_writer_recover_restores_missing_app_from_empty_root(self) -> None:
        writer = GitOpsWorkloadWriter(self.source_root)
        request = WorkloadWriteRequest(app_name="nginx-demo", image="nginx:latest")

        result = writer.recover(request)

        self.assertTrue(result.changed)
        self.assertTrue(all(path.is_file() for path in result.written_files))
        root = yaml.safe_load((self.source_root / "kustomization.yaml").read_text(encoding="utf-8"))
        self.assertEqual(root["resources"], ["apps/nginx-demo"])

    def test_writer_recover_returns_no_change_when_manifests_already_match(self) -> None:
        writer = GitOpsWorkloadWriter(self.source_root)
        request = WorkloadWriteRequest(app_name="nginx-demo", image="nginx:latest")
        self.assertTrue(writer.recover(request).changed)

        result = writer.recover(request)

        self.assertFalse(result.changed)

    def test_writer_destroy_removes_app_folder_and_root_entry_only(self) -> None:
        writer = GitOpsWorkloadWriter(self.source_root)
        request = WorkloadWriteRequest(app_name="nginx-demo", image="nginx:latest")
        self.assertTrue(writer.recover(request).changed)
        unrelated_dir = self.apps_root / "unrelated"
        unrelated_dir.mkdir()
        unrelated_file = unrelated_dir / "keep.txt"
        unrelated_file.write_text("preserve me\n", encoding="utf-8")

        result = writer.destroy("nginx-demo")

        self.assertTrue(result.changed)
        self.assertFalse((self.apps_root / "nginx-demo").exists())
        self.assertEqual(unrelated_file.read_text(encoding="utf-8"), "preserve me\n")
        root = yaml.safe_load((self.source_root / "kustomization.yaml").read_text(encoding="utf-8"))
        self.assertEqual(root["resources"], [])
        self.assertIn("resources: []", (self.source_root / "kustomization.yaml").read_text(encoding="utf-8"))

    def test_writer_destroy_is_noop_when_app_already_absent(self) -> None:
        writer = GitOpsWorkloadWriter(self.source_root)

        result = writer.destroy("nginx-demo")

        self.assertFalse(result.changed)
        self.assertEqual(result.removed_files, ())
        self.assertEqual((self.source_root / "kustomization.yaml").read_text(encoding="utf-8"), ROOT_KUSTOMIZATION)

    def test_writer_destroy_rejects_unexpected_app_folder_content(self) -> None:
        app_dir = self.apps_root / "nginx-demo"
        app_dir.mkdir()
        (app_dir / "secret.yaml").write_text("apiVersion: v1\nkind: Secret\n", encoding="utf-8")
        writer = GitOpsWorkloadWriter(self.source_root)

        self.assert_error_code("unexpected_app_files", lambda: writer.destroy("nginx-demo"))
        self.assertTrue((app_dir / "secret.yaml").exists())

    def test_writer_fails_when_app_folder_exists(self) -> None:
        (self.apps_root / "nginx-demo").mkdir()
        writer = GitOpsWorkloadWriter(self.source_root)
        request = WorkloadWriteRequest(app_name="nginx-demo", image="nginx:latest")

        self.assert_error_code("app_exists", lambda: writer.create(request))

    def test_structural_render_failure_does_not_write_app(self) -> None:
        class RejectingValidator(StructuralRenderValidator):
            def validate(self, **kwargs) -> None:
                raise GitOpsWriterError("render_failed", "Candidate render rejected.")

        writer = GitOpsWorkloadWriter(self.source_root, render_validator=RejectingValidator())
        request = WorkloadWriteRequest(app_name="nginx-demo", image="nginx:latest")

        self.assert_error_code("render_failed", lambda: writer.create(request))
        self.assertFalse((self.apps_root / "nginx-demo").exists())
        self.assertEqual((self.source_root / "kustomization.yaml").read_text(encoding="utf-8"), ROOT_KUSTOMIZATION)


if __name__ == "__main__":
    unittest.main()
