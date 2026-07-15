import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
LAUNCHER = REPO_ROOT / "scripts" / "launcher" / "devdeploy-launcher.ps1"


class LauncherGitOpsRootRecoveryTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.script = LAUNCHER.read_text(encoding="utf-8")

    def function_body(self, name: str) -> str:
        marker = f"function {name} {{"
        start = self.script.index(marker)
        next_function = self.script.find("\nfunction ", start + len(marker))
        if next_function == -1:
            return self.script[start:]
        return self.script[start:next_function]

    def temporary_directory(self) -> tempfile.TemporaryDirectory[str]:
        test_root = REPO_ROOT / ".devdeploy" / "local" / "test-temp"
        test_root.mkdir(parents=True, exist_ok=True)
        return tempfile.TemporaryDirectory(dir=test_root)

    def write_root(self, root: Path, resources: list[str]) -> Path:
        source = root / "gitops" / "workloads" / "devdeploy-apps"
        (source / "apps").mkdir(parents=True)
        if resources:
            resource_lines = "\n".join(f"  - {resource}" for resource in resources)
            resources_yaml = f"resources:\n{resource_lines}"
        else:
            resources_yaml = "resources: []"
        (source / "kustomization.yaml").write_text(
            "apiVersion: kustomize.config.k8s.io/v1beta1\n"
            "kind: Kustomization\n"
            f"{resources_yaml}\n",
            encoding="utf-8",
        )
        return source

    def write_app(self, source: Path, name: str = "recover-nginx", *, malformed: bool = False) -> None:
        app = source / "apps" / name
        app.mkdir(parents=True)
        (app / "kustomization.yaml").write_text(
            "apiVersion: kustomize.config.k8s.io/v1beta1\n"
            "kind: Kustomization\n"
            "resources:\n"
            "  - deployment.yaml\n"
            "  - service.yaml\n",
            encoding="utf-8",
        )
        deployment = (
            "apiVersion: apps/v1\n"
            "kind Deployment\n"
            "metadata:\n  name: recover-nginx\n"
            if malformed
            else
            "apiVersion: apps/v1\n"
            "kind: Deployment\n"
            "metadata:\n  name: recover-nginx\n"
            "spec:\n"
            "  selector:\n    matchLabels:\n      app: recover-nginx\n"
            "  template:\n"
            "    metadata:\n      labels:\n        app: recover-nginx\n"
            "    spec:\n      containers:\n        - name: nginx\n          image: nginx:latest\n"
        )
        (app / "deployment.yaml").write_text(deployment, encoding="utf-8")
        (app / "service.yaml").write_text(
            "apiVersion: v1\n"
            "kind: Service\n"
            "metadata:\n  name: recover-nginx\n"
            "spec:\n"
            "  selector:\n    app: recover-nginx\n"
            "  ports:\n    - port: 80\n",
            encoding="utf-8",
        )

    def validate_source(self, source: Path) -> dict:
        escaped_source = str(source).replace("'", "''")
        functions = "\n".join(
            self.function_body(name)
            for name in (
                "Test-GitOpsKustomizationContent",
                "Get-GitOpsKustomizationResourceEntries",
                "Test-GitOpsManagedPath",
                "Test-GitOpsManagedKustomizationTree",
                "Test-GitOpsManagedSourceTree",
            )
        )
        command = "\n".join(
            (
                functions,
                "function Invoke-ReadOnlyCommand {",
                "  param([string]$FileName, [string[]]$Arguments, [int]$TimeoutSeconds)",
                "  if ($FileName -eq 'kubectl' -and $Arguments.Count -ge 2 -and $Arguments[0] -eq 'kustomize') {",
                "    $renderRoot = [string]$Arguments[1]",
                "    $yamlFiles = @(Get-ChildItem -LiteralPath $renderRoot -Recurse -File -Include *.yaml,*.yml)",
                "    foreach ($yamlFile in $yamlFiles) {",
                "      $content = [string](Get-Content -LiteralPath $yamlFile.FullName -Raw)",
                "      if ($content -match '(?m)^kind\\s+Deployment\\s*$') {",
                "        return [ordered]@{ exit_code = 1; timed_out = $false; stdout = ''; stderr = 'simulated kustomize render failure' }",
                "      }",
                "    }",
                "    return [ordered]@{ exit_code = 0; timed_out = $false; stdout = ''; stderr = '' }",
                "  }",
                "  return [ordered]@{ exit_code = 127; timed_out = $false; stdout = ''; stderr = 'unexpected command' }",
                "}",
                f"Test-GitOpsManagedSourceTree -SourceRoot '{escaped_source}' -KubectlAvailable $true | ConvertTo-Json -Compress -Depth 12",
            )
        )
        result = subprocess.run(
            ["powershell", "-NoProfile", "-NonInteractive", "-Command", command],
            capture_output=True,
            text=True,
            check=True,
        )
        return json.loads(result.stdout.strip().splitlines()[-1])

    def test_empty_initial_repository_remains_valid(self) -> None:
        with self.temporary_directory() as temporary_directory:
            source = self.write_root(Path(temporary_directory), [])
            result = self.validate_source(source)

        self.assertTrue(result["ready"])
        self.assertEqual(result["repository_mode"], "initial_empty_bootstrap")
        self.assertEqual(result["app_directory_count"], 0)
        self.assertTrue(result["empty_resources"])

    def test_populated_repository_is_valid_recovery_and_files_are_unchanged(self) -> None:
        with self.temporary_directory() as temporary_directory:
            source = self.write_root(Path(temporary_directory), ["apps/recover-nginx"])
            self.write_app(source)
            before = {path.relative_to(source): path.read_bytes() for path in source.rglob("*") if path.is_file()}
            result = self.validate_source(source)
            after = {path.relative_to(source): path.read_bytes() for path in source.rglob("*") if path.is_file()}

        self.assertTrue(result["ready"])
        self.assertEqual(result["repository_mode"], "existing_repository_recovery")
        self.assertEqual(result["app_directory_count"], 1)
        self.assertFalse(result["empty_resources"])
        self.assertTrue(result["kustomization_valid"])
        self.assertTrue(result["kustomize_render_succeeded"])
        self.assertEqual(before, after)

    def test_path_traversal_is_rejected(self) -> None:
        with self.temporary_directory() as temporary_directory:
            root = Path(temporary_directory)
            source = self.write_root(root, ["../outside"])
            (source.parent / "outside").mkdir()
            result = self.validate_source(source)

        self.assertFalse(result["ready"])
        self.assertEqual(result["error_category"], "resource_path_traversal")

    def test_absolute_resource_path_is_rejected(self) -> None:
        with self.temporary_directory() as temporary_directory:
            root = Path(temporary_directory)
            absolute = (root / "outside").resolve()
            absolute.mkdir()
            source = self.write_root(root, [str(absolute)])
            result = self.validate_source(source)

        self.assertFalse(result["ready"])
        self.assertEqual(result["error_category"], "absolute_or_encoded_resource_path")

    def test_symlink_escape_is_rejected(self) -> None:
        with self.temporary_directory() as temporary_directory:
            root = Path(temporary_directory)
            source = self.write_root(root, ["apps/external-app"])
            external_app = root / "external-app"
            external_app.mkdir()
            (external_app / "kustomization.yaml").write_text(
                "apiVersion: kustomize.config.k8s.io/v1beta1\n"
                "kind: Kustomization\n"
                "resources: []\n",
                encoding="utf-8",
            )
            try:
                os.symlink(external_app, source / "apps" / "external-app", target_is_directory=True)
            except OSError as error:
                self.skipTest(f"Directory symlinks are unavailable: {error}")
            result = self.validate_source(source)

        self.assertFalse(result["ready"])
        self.assertEqual(result["error_category"], "resource_symlink_not_allowed")

    def test_missing_referenced_directory_is_rejected(self) -> None:
        with self.temporary_directory() as temporary_directory:
            source = self.write_root(Path(temporary_directory), ["apps/missing-app"])
            result = self.validate_source(source)

        self.assertFalse(result["ready"])
        self.assertEqual(result["error_category"], "referenced_resource_missing")

    def test_duplicate_resources_are_rejected(self) -> None:
        with self.temporary_directory() as temporary_directory:
            source = self.write_root(Path(temporary_directory), ["apps/recover-nginx", "apps/recover-nginx"])
            self.write_app(source)
            result = self.validate_source(source)

        self.assertFalse(result["ready"])
        self.assertEqual(result["error_category"], "duplicate_resource_entry")

    def test_malformed_yaml_is_rejected_by_kustomize_render(self) -> None:
        with self.temporary_directory() as temporary_directory:
            source = self.write_root(Path(temporary_directory), ["apps/recover-nginx"])
            self.write_app(source, malformed=True)
            result = self.validate_source(source)

        self.assertFalse(result["ready"])
        self.assertEqual(result["error_category"], "kustomize_render_failed")

    def test_bootstrap_reconciles_only_management_root_application(self) -> None:
        body = self.function_body("Invoke-BootstrapGitOpsRootApplication")

        self.assertEqual(body.count("Invoke-SanitizedInputCommand"), 1)
        self.assertIn('"--context", "kind-devdeploy-mgmt"', body)
        self.assertIn('$GitOpsRootApplicationName', body)
        self.assertIn('resource_kind = "Application"', body)
        self.assertIn('launcher_applied_workload = $false', body)
        self.assertNotIn('"--context", "kind-devdeploy-workload", "apply"', body)
        self.assertNotIn('"delete"', body)

    def test_repository_validation_and_verify_mode_are_non_mutating(self) -> None:
        repository = self.function_body("Get-PersistedGitOpsRepositoryStatus")
        validator = self.function_body("Test-GitOpsManagedSourceTree")
        verification = self.function_body("Invoke-VerifyGitOpsRootApplication")

        for body in (repository, validator, verification):
            self.assertNotIn("Invoke-SanitizedInputCommand", body)
            self.assertNotIn("Set-Content", body)
            self.assertNotIn("Remove-Item", body)


if __name__ == "__main__":
    unittest.main()
