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

    def test_alloy_collects_logs_with_namespace_labels_across_authorized_namespaces(self) -> None:
        values = self.read_yaml("alloy-values.yaml")
        content = values["alloy"]["configMap"]["content"]

        self.assertNotIn('names = ["devdeploy-apps"]', content)
        self.assertIn('source_labels = ["__meta_kubernetes_namespace"]', content)
        self.assertIn('target_label  = "namespace"', content)
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
        by_kind_and_name = {
            (document["kind"], document["metadata"]["name"]): document
            for document in documents
        }
        service_account = by_kind_and_name[("ServiceAccount", "devdeploy-observability-reader")]
        proxy_role = by_kind_and_name[("Role", "devdeploy-observability-service-proxy-reader")]
        proxy_binding = by_kind_and_name[("RoleBinding", "devdeploy-observability-service-proxy-reader")]
        runtime_role = by_kind_and_name[("Role", "devdeploy-workload-runtime-reader")]
        runtime_binding = by_kind_and_name[("RoleBinding", "devdeploy-workload-runtime-reader")]
        cluster_role = by_kind_and_name[("ClusterRole", "devdeploy-observability-namespace-reader")]
        cluster_role_binding = by_kind_and_name[
            ("ClusterRoleBinding", "devdeploy-observability-namespace-reader")
        ]

        self.assertEqual(service_account["metadata"]["namespace"], "monitoring")
        self.assertEqual(proxy_role["metadata"]["namespace"], "monitoring")
        self.assertEqual(proxy_binding["subjects"][0]["name"], "devdeploy-observability-reader")
        self.assertEqual(proxy_binding["roleRef"]["name"], "devdeploy-observability-service-proxy-reader")
        self.assertEqual(runtime_role["metadata"]["namespace"], "devdeploy-apps")
        self.assertEqual(runtime_binding["subjects"][0]["name"], "devdeploy-observability-reader")
        self.assertEqual(runtime_binding["subjects"][0]["namespace"], "monitoring")
        self.assertEqual(runtime_binding["roleRef"]["name"], "devdeploy-workload-runtime-reader")
        self.assertEqual(cluster_role_binding["subjects"][0]["name"], "devdeploy-observability-reader")
        self.assertEqual(cluster_role_binding["subjects"][0]["namespace"], "monitoring")
        self.assertEqual(cluster_role_binding["roleRef"]["name"], "devdeploy-observability-namespace-reader")

        proxy_rules = {(tuple(rule["resources"]), tuple(rule["verbs"])) for rule in proxy_role["rules"]}
        self.assertIn((("services",), ("get", "list", "watch")), proxy_rules)
        self.assertIn((("services/proxy",), ("get",)), proxy_rules)
        runtime_rules = {
            (tuple(rule["apiGroups"]), tuple(rule["resources"]), tuple(rule["verbs"]))
            for rule in runtime_role["rules"]
        }
        self.assertIn((("",), ("pods", "services"), ("get", "list", "watch")), runtime_rules)
        self.assertIn((("apps",), ("deployments",), ("get", "list", "watch")), runtime_rules)
        self.assertIn((("",), ("services/proxy",), ("get",)), runtime_rules)
        cluster_rules = {
            (tuple(rule["apiGroups"]), tuple(rule["resources"]), tuple(rule["verbs"]))
            for rule in cluster_role["rules"]
        }
        self.assertEqual(
            cluster_rules,
            {
                (("",), ("namespaces", "nodes", "pods", "services"), ("get", "list", "watch")),
                (("apps",), ("deployments",), ("get", "list", "watch")),
            },
        )
        self.assertFalse(
            any("services/proxy" in rule[1] for rule in cluster_rules),
        )

        text = str(documents).lower()
        self.assertNotIn("secrets", text)
        self.assertNotIn("configmaps", text)
        self.assertNotIn("create", text)
        self.assertNotIn("update", text)
        self.assertNotIn("patch", text)
        self.assertNotIn("delete", text)
        self.assertNotIn("impersonate", text)

    def test_workload_observability_kustomization_renders_only_manifest_assets(self) -> None:
        kustomization = self.read_yaml("kustomization.yaml")

        self.assertEqual(
            kustomization["resources"],
            ["backend-service-proxy-reader.yaml", "grafana-datasources.yaml"],
        )

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
