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
        pod_metadata = deployment["spec"]["template"]["metadata"]
        migration = next(
            item for item in pod_spec["initContainers"] if item["name"] == "database-migrations"
        )

        self.assertEqual(pod_metadata["annotations"]["devdeploy.io/backend-tempdir"], "/var/run/devdeploy/tmp")
        self.assertEqual(
            pod_metadata["annotations"]["devdeploy.io/observability-client"],
            "namespace-summary-rbac-v4",
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
        self.assertTrue(backend["securityContext"]["readOnlyRootFilesystem"])
        self.assertFalse(backend["securityContext"]["allowPrivilegeEscalation"])

        env = {item["name"]: item["value"] for item in backend["env"] if "value" in item}
        self.assertEqual(env["TMPDIR"], "/var/run/devdeploy/tmp")

        volume_names = [item["name"] for item in backend["volumeMounts"]]
        self.assertIn("backend-tmp", volume_names)
        self.assertIn("observability-workload-kubeconfig", volume_names)
        temp_mount = next(item for item in backend["volumeMounts"] if item["name"] == "backend-tmp")
        self.assertEqual(temp_mount["mountPath"], "/var/run/devdeploy/tmp")
        self.assertNotIn("readOnly", temp_mount)
        observability_mount = next(
            item for item in backend["volumeMounts"] if item["name"] == "observability-workload-kubeconfig"
        )
        self.assertEqual(observability_mount["mountPath"], "/var/run/devdeploy/workload-observability")
        self.assertTrue(observability_mount["readOnly"])
        self.assertFalse(any("hostPath" in volume for volume in pod_spec["volumes"]))
        temp_volume = next(item for item in pod_spec["volumes"] if item["name"] == "backend-tmp")
        self.assertEqual(temp_volume["emptyDir"], {"sizeLimit": "64Mi"})
        observability_secret = next(
            item for item in pod_spec["volumes"] if item["name"] == "observability-workload-kubeconfig"
        )
        self.assertEqual(observability_secret["secret"]["secretName"], "devdeploy-backend-workload-kubeconfig")
        self.assertTrue(observability_secret["secret"]["optional"])

    def test_backend_config_uses_observability_service_proxy_not_cluster_ip_urls(self) -> None:
        repository_root = Path(__file__).resolve().parents[2]
        configmap = yaml.safe_load(
            (repository_root / "platform" / "management" / "backend" / "configmap.yaml").read_text(
                encoding="utf-8"
            )
        )
        data = configmap["data"]

        self.assertEqual(data["DEVDEPLOY_OBSERVABILITY_ACCESS_MODE"], "kubernetes_service_proxy")
        self.assertEqual(data["PROMETHEUS_BASE_URL"], "")
        self.assertEqual(data["LOKI_BASE_URL"], "")
        self.assertEqual(data["DEVDEPLOY_OBSERVABILITY_MONITORING_NAMESPACE"], "monitoring")
        self.assertEqual(data["DEVDEPLOY_OBSERVABILITY_PROMETHEUS_SERVICE_NAME"], "kube-prometheus-stack-prometheus")
        self.assertEqual(data["DEVDEPLOY_OBSERVABILITY_LOKI_SERVICE_NAME"], "loki-gateway")
        self.assertEqual(
            data["DEVDEPLOY_OBSERVABILITY_WORKLOAD_KUBECONFIG"],
            "/var/run/devdeploy/workload-observability/kubeconfig",
        )
        self.assertEqual(
            data["DEVDEPLOY_OBSERVABILITY_WORKLOAD_KUBECONFIG_CONTEXT"],
            "devdeploy-workload-observability",
        )
        self.assertEqual(data["DEVDEPLOY_WORKLOAD_KUBECONFIG"], "")
        self.assertEqual(data["DEVDEPLOY_WORKLOAD_KUBECONFIG_CONTEXT"], "")
        self.assertNotIn("ClusterIP", str(data))
        self.assertNotIn(".svc.cluster.local", str(data))


if __name__ == "__main__":
    unittest.main()
