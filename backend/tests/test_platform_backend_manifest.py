from pathlib import Path
import unittest

import yaml


class PlatformBackendManifestTestCase(unittest.TestCase):
    def test_backend_runs_hardened_database_migration_init_container(self) -> None:
        repository_root = Path(__file__).resolve().parents[2]
        deployment = yaml.safe_load(
            (repository_root / "platform" / "management" / "backend" / "deployment.yaml").read_text(
                encoding="utf-8"
            )
        )
        pod_spec = deployment["spec"]["template"]["spec"]
        migration = next(
            item for item in pod_spec["initContainers"] if item["name"] == "database-migrations"
        )

        self.assertEqual(migration["image"], "devdeploy-backend:local")
        self.assertEqual(migration["command"], ["python", "-m", "app.db.migrate"])
        self.assertEqual([item["name"] for item in migration["env"]], ["DATABASE_URL"])
        self.assertEqual(
            migration["env"][0]["valueFrom"]["secretKeyRef"],
            {"name": "devdeploy-backend-secret", "key": "DATABASE_URL"},
        )
        self.assertNotIn("envFrom", migration)
        self.assertTrue(migration["securityContext"]["runAsNonRoot"])
        self.assertTrue(migration["securityContext"]["readOnlyRootFilesystem"])
        self.assertFalse(migration["securityContext"]["allowPrivilegeEscalation"])
        self.assertEqual(migration["securityContext"]["capabilities"]["drop"], ["ALL"])
        backend = next(item for item in pod_spec["containers"] if item["name"] == "backend")
        self.assertEqual(
            backend["readinessProbe"]["httpGet"]["path"],
            "/api/v1/health/ready",
        )
        self.assertEqual(backend["livenessProbe"]["httpGet"]["path"], "/api/v1/health")


if __name__ == "__main__":
    unittest.main()
