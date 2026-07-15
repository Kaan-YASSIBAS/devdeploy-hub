from pathlib import Path
import unittest

import yaml


class PlatformFrontendManifestTestCase(unittest.TestCase):
    def test_platform_health_route_guard_revision_forces_frontend_rollout(self) -> None:
        repository_root = Path(__file__).resolve().parents[2]
        deployment = yaml.safe_load(
            (repository_root / "platform" / "management" / "frontend" / "deployment.yaml").read_text(
                encoding="utf-8"
            )
        )

        template = deployment["spec"]["template"]
        self.assertEqual(
            template["metadata"]["annotations"]["devdeploy.io/setup-route-guard"],
            "platform-health-v1",
        )
        self.assertEqual(
            template["metadata"]["annotations"]["devdeploy.io/cluster-summary"],
            "namespace-scoped-v1",
        )
        container = next(item for item in template["spec"]["containers"] if item["name"] == "frontend")
        self.assertTrue(container["securityContext"]["readOnlyRootFilesystem"])
        self.assertFalse(template["spec"]["automountServiceAccountToken"])


if __name__ == "__main__":
    unittest.main()
