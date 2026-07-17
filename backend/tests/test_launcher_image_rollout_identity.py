import json
import shutil
import subprocess
import unittest
from pathlib import Path


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
LAUNCHER_PATH = REPOSITORY_ROOT / "scripts" / "launcher" / "devdeploy-launcher.ps1"
IMAGE_A = "sha256:" + "a" * 64
IMAGE_B = "sha256:" + "b" * 64


class LauncherImageRolloutIdentityTestCase(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.launcher_text = LAUNCHER_PATH.read_text(encoding="utf-8-sig")
        cls.powershell = shutil.which("powershell")

    def function_body(self, name: str) -> str:
        marker = f"function {name}"
        start = self.launcher_text.index(marker)
        end = self.launcher_text.find("\nfunction ", start + len(marker))
        return self.launcher_text[start:] if end == -1 else self.launcher_text[start:end]

    def run_identity_update(self, current_image_id: str, desired_image_id: str) -> dict:
        if self.powershell is None:
            self.skipTest("Windows PowerShell is not available")
        deployment = {
            "metadata": {"generation": 12},
            "spec": {
                "template": {
                    "metadata": {
                        "annotations": {"devdeploy.io/local-image-identity": current_image_id}
                    }
                }
            },
        }
        deployment_json = json.dumps(deployment).replace("'", "''")
        script = "\n\n".join(
            [
                '$ManagementImageIdentityAnnotation = "devdeploy.io/local-image-identity"',
                '$PostgresNamespace = "devdeploy"',
                "$script:Calls = New-Object System.Collections.ArrayList",
                "function Invoke-ReadOnlyCommand { param([string]$FileName, [string[]]$Arguments, [int]$TimeoutSeconds = 8, [bool]$PreserveStandardOutput = $false) $null = $script:Calls.Add(@($Arguments)); if ($Arguments -contains 'get') { return @{ exit_code = 0; timed_out = $false; stdout = '"
                + deployment_json
                + "'; stderr = '' } }; return @{ exit_code = 0; timed_out = $false; stdout = ''; stderr = '' } }",
                self.function_body("Set-ManagementDeploymentImageIdentity"),
                f"$result = Set-ManagementDeploymentImageIdentity -Deployment 'devdeploy-backend' -ImageId '{desired_image_id}'",
                "$patchCalls = @($script:Calls | Where-Object { $_ -contains 'patch' }).Count",
                "[ordered]@{ result = $result; patch_calls = $patchCalls } | ConvertTo-Json -Depth 8",
            ]
        )
        completed = subprocess.run(
            [self.powershell, "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", script],
            check=True,
            capture_output=True,
            text=True,
        )
        return json.loads(completed.stdout)

    def test_new_loaded_identity_changes_pod_template_once(self) -> None:
        result = self.run_identity_update(IMAGE_A, IMAGE_B)

        self.assertTrue(result["result"]["success"])
        self.assertTrue(result["result"]["changed"])
        self.assertEqual(result["result"]["previous_generation"], 12)
        self.assertEqual(result["patch_calls"], 1)

    def test_unchanged_loaded_identity_does_not_rollout(self) -> None:
        result = self.run_identity_update(IMAGE_A, IMAGE_A)

        self.assertTrue(result["result"]["success"])
        self.assertFalse(result["result"]["changed"])
        self.assertEqual(result["patch_calls"], 0)

    def test_backend_and_frontend_bootstrap_share_identity_contract(self) -> None:
        backend = self.function_body("Invoke-BootstrapManagementBackend")
        frontend = self.function_body("Invoke-BootstrapManagementFrontend")

        self.assertIn('Resolve-ManagementImageIdentity -Image $script:BackendImage', backend)
        self.assertIn('Set-ManagementDeploymentImageIdentity -Deployment "devdeploy-backend"', backend)
        self.assertIn('Test-ManagementDeploymentImageIdentity -Deployment "devdeploy-backend"', backend)
        self.assertIn('Resolve-ManagementImageIdentity -Image $FrontendImage', frontend)
        self.assertIn('Set-ManagementDeploymentImageIdentity -Deployment "devdeploy-frontend"', frontend)
        self.assertIn('Test-ManagementDeploymentImageIdentity -Deployment "devdeploy-frontend"', frontend)

    def test_backend_status_object_cannot_shadow_backend_image_tag(self) -> None:
        backend = self.function_body("Invoke-BootstrapManagementBackend")

        self.assertIn("$backendImage = New-ManagementBackendImageStatus", backend)
        self.assertNotIn("-Image $BackendImage", backend)
        self.assertNotIn("image    = $BackendImage", backend)
        self.assertIn("-Image $script:BackendImage", backend)

    def test_load_records_kind_runtime_identity(self) -> None:
        for function_name, image_name in (
            ("Invoke-ManagementBackendImageLoad", "$script:BackendImage"),
            ("Invoke-ManagementFrontendImageLoad", "$FrontendImage"),
        ):
            body = self.function_body(function_name)
            self.assertIn(f"Resolve-ManagementImageIdentity -Image {image_name}", body)
            self.assertIn('["loaded_image_id"]', body)

    def test_verify_modes_do_not_mutate_rollout_identity(self) -> None:
        for function_name in (
            "Invoke-VerifyManagementBackend",
            "Invoke-VerifyManagementFrontend",
        ):
            body = self.function_body(function_name)
            self.assertNotIn("Set-ManagementDeploymentImageIdentity", body)
            self.assertNotIn('"patch", "deployment"', body)

    def test_rollout_verification_requires_matching_replicaset_and_pod_image_id(self) -> None:
        body = self.function_body("Test-ManagementDeploymentImageIdentity")

        self.assertIn('"get", "replicasets"', body)
        self.assertIn("$matchingReplicaSets.Count -ge 1", body)
        self.assertIn('$_.name -eq $Deployment', body)
        self.assertIn("containerStatuses[0].imageID -eq $ImageId", body)
        self.assertIn("$generationAdvanced", body)

    def test_rollout_verifier_rejects_old_ready_pod_and_accepts_new_replicaset(self) -> None:
        if self.powershell is None:
            self.skipTest("Windows PowerShell is not available")

        def run(pod_image_id: str) -> dict:
            deployment = {
                "metadata": {"generation": 13},
                "spec": {
                    "template": {
                        "metadata": {
                            "annotations": {"devdeploy.io/local-image-identity": IMAGE_B}
                        }
                    }
                },
            }
            pods = {
                "items": [
                    {
                        "metadata": {
                            "annotations": {"devdeploy.io/local-image-identity": IMAGE_B},
                        },
                        "status": {
                            "containerStatuses": [
                                {"imageID": pod_image_id, "ready": True}
                            ]
                        },
                    }
                ]
            }
            replica_sets = {
                "items": [
                    {
                        "metadata": {
                            "ownerReferences": [
                                {"kind": "Deployment", "name": "devdeploy-backend"}
                            ]
                        },
                        "spec": {"template": {"metadata": {}}},
                        "status": {},
                    },
                    {
                        "metadata": {
                            "ownerReferences": [
                                {"kind": "Deployment", "name": "devdeploy-backend"}
                            ]
                        },
                        "spec": {
                            "template": {
                                "metadata": {
                                    "annotations": {
                                        "devdeploy.io/local-image-identity": IMAGE_B
                                    }
                                }
                            }
                        },
                        "status": {"availableReplicas": 1},
                    }
                ]
            }
            values = {
                "deployment": json.dumps(deployment).replace("'", "''"),
                "pods": json.dumps(pods).replace("'", "''"),
                "replicasets": json.dumps(replica_sets).replace("'", "''"),
            }
            script = "\n\n".join(
                [
                    '$ManagementImageIdentityAnnotation = "devdeploy.io/local-image-identity"',
                    '$PostgresNamespace = "devdeploy"',
                    "function Invoke-ReadOnlyCommand { param([string]$FileName, [string[]]$Arguments, [int]$TimeoutSeconds = 8, [bool]$PreserveStandardOutput = $false) if ($Arguments -contains 'pods') { $value = '"
                    + values["pods"]
                    + "' } elseif ($Arguments -contains 'replicasets') { $value = '"
                    + values["replicasets"]
                    + "' } else { $value = '"
                    + values["deployment"]
                    + "' }; return @{ exit_code = 0; timed_out = $false; stdout = $value; stderr = '' } }",
                    self.function_body("Test-ManagementDeploymentImageIdentity"),
                    f"Test-ManagementDeploymentImageIdentity -Deployment 'devdeploy-backend' -Selector 'app.kubernetes.io/name=devdeploy-backend' -ImageId '{IMAGE_B}' -PreviousGeneration 12 -IdentityChanged $true | ConvertTo-Json -Depth 8",
                ]
            )
            completed = subprocess.run(
                [self.powershell, "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", script],
                check=True,
                capture_output=True,
                text=True,
            )
            return json.loads(completed.stdout)

        self.assertFalse(run(IMAGE_A)["success"])
        self.assertTrue(run(IMAGE_B)["success"])


if __name__ == "__main__":
    unittest.main()
