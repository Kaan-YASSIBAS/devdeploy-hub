from pathlib import Path
import unittest

import yaml


class ObservabilityBootstrapAssetsTestCase(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.repository_root = Path(__file__).resolve().parents[2]
        cls.assets_root = cls.repository_root / "platform" / "workload" / "observability"

    def read_yaml(self, name: str):
        return yaml.safe_load((self.assets_root / name).read_text(encoding="utf-8"))

    def read_yaml_documents(self, name: str):
        return list(yaml.safe_load_all((self.assets_root / name).read_text(encoding="utf-8")))

    def test_prometheus_stack_uses_grafana_secret_and_local_resource_limits(self) -> None:
        values = self.read_yaml("kube-prometheus-stack-values.yaml")

        self.assertEqual(values["grafana"]["admin"]["existingSecret"], "devdeploy-grafana-admin")
        self.assertNotIn("adminPassword", values["grafana"])
        self.assertEqual(values["prometheus"]["prometheusSpec"]["retention"], "6h")
        self.assertEqual(values["prometheus"]["prometheusSpec"]["replicas"], 1)
        self.assertIn("requests", values["prometheus"]["prometheusSpec"]["resources"])
        self.assertIn("limits", values["prometheus"]["prometheusSpec"]["resources"])

    def test_prometheus_operator_admission_tls_is_disabled_for_local_profile(self) -> None:
        values = self.read_yaml("kube-prometheus-stack-values.yaml")
        operator_values = values["prometheusOperator"]

        self.assertFalse(operator_values["admissionWebhooks"]["enabled"])
        self.assertFalse(operator_values["tls"]["enabled"])
        self.assertNotIn("kube-prometheus-stack-admission", str(operator_values).lower())

    def test_loki_uses_single_binary_local_safe_mode(self) -> None:
        values = self.read_yaml("loki-values.yaml")

        self.assertEqual(values["deploymentMode"], "SingleBinary")
        self.assertEqual(values["singleBinary"]["replicas"], 1)
        self.assertFalse(values["singleBinary"]["persistence"]["enabled"])
        self.assertEqual(values["loki"]["limits_config"]["retention_period"], "24h")
        self.assertFalse(values["minio"]["enabled"])

    def test_alloy_collects_only_workload_namespace_logs(self) -> None:
        values = self.read_yaml("alloy-values.yaml")
        content = values["alloy"]["configMap"]["content"]

        self.assertIn('names = ["devdeploy-apps"]', content)
        self.assertIn("http://loki-gateway.monitoring.svc.cluster.local/loki/api/v1/push", content)
        self.assertNotIn("token", content.lower())

    def test_grafana_datasources_are_provisioned_without_credentials(self) -> None:
        manifest = self.read_yaml("grafana-datasources.yaml")
        text = str(manifest).lower()
        datasource_config = yaml.safe_load(manifest["data"]["datasources.yaml"])
        datasources = datasource_config["datasources"]
        datasource_names = [datasource["name"] for datasource in datasources]
        custom_default_count = sum(1 for datasource in datasources if datasource.get("isDefault") is True)

        self.assertEqual(manifest["kind"], "ConfigMap")
        self.assertEqual(custom_default_count, 0)
        self.assertEqual(1 + custom_default_count, 1)
        self.assertNotIn("Prometheus", datasource_names)
        self.assertEqual(datasource_names.count("Prometheus"), 0)
        self.assertIn("Loki", datasource_names)
        self.assertIn("loki", text)
        self.assertNotIn("password", text)
        self.assertNotIn("token", text)

    def test_backend_service_proxy_reader_rbac_is_narrow(self) -> None:
        documents = self.read_yaml_documents("backend-service-proxy-reader.yaml")
        kinds = {document["kind"]: document for document in documents}
        role = kinds["Role"]
        role_binding = kinds["RoleBinding"]

        self.assertEqual(kinds["ServiceAccount"]["metadata"]["name"], "devdeploy-observability-reader")
        self.assertEqual(role["metadata"]["namespace"], "monitoring")
        self.assertEqual(role_binding["subjects"][0]["name"], "devdeploy-observability-reader")
        self.assertEqual(role_binding["roleRef"]["name"], "devdeploy-observability-service-proxy-reader")

        rules = {(tuple(rule["resources"]), tuple(rule["verbs"])) for rule in role["rules"]}
        self.assertIn((("services",), ("get", "list", "watch")), rules)
        self.assertIn((("services/proxy",), ("get",)), rules)

        text = str(role).lower()
        self.assertNotIn("secrets", text)
        self.assertNotIn("pods", text)
        self.assertNotIn("deployments", text)
        self.assertNotIn("create", text)
        self.assertNotIn("update", text)
        self.assertNotIn("patch", text)
        self.assertNotIn("delete", text)

    def test_legacy_terraform_no_longer_hard_codes_grafana_admin_password(self) -> None:
        main_tf = (self.repository_root / "infra" / "terraform" / "local" / "main.tf").read_text(
            encoding="utf-8"
        )
        variables_tf = (self.repository_root / "infra" / "terraform" / "local" / "variables.tf").read_text(
            encoding="utf-8"
        )

        self.assertNotIn('adminPassword = "admin"', main_tf)
        self.assertIn('existingSecret = "devdeploy-grafana-admin"', main_tf)
        self.assertRegex(variables_tf, r'variable "install_monitoring" \{[\s\S]*?default\s+= false')
        self.assertRegex(variables_tf, r'variable "install_logging" \{[\s\S]*?default\s+= false')


if __name__ == "__main__":
    unittest.main()
