import unittest
from unittest.mock import patch

from app.services.loki_service import LokiService
from app.services.prometheus_service import PrometheusService


class NamespacePrometheusServiceTestCase(unittest.TestCase):
    def test_http_queries_are_strictly_scoped_to_the_selected_namespace(self) -> None:
        definitions = PrometheusService._timeseries_definitions(
            "team-a",
            restart_window="15m",
        )

        for key in ("request_rate", "error_rate"):
            queries = definitions[key]["queries"].splitlines()
            self.assertTrue(queries)
            for query in queries:
                self.assertTrue(
                    'namespace="team-a"' in query
                    or 'exported_namespace="team-a"' in query
                )
                self.assertNotIn("devdeploy-apps", query)

    def test_empty_http_series_is_connected_no_data(self) -> None:
        service = PrometheusService(base_url="http://prometheus.example")
        payload = {"status": "success", "data": {"result": []}}

        with patch.object(service, "query_range", return_value=payload):
            result = service.get_metrics_timeseries(
                namespace="team-a",
                range_value="15m",
                metric="request_rate",
            )

        self.assertEqual(result["namespace"], "team-a")
        self.assertEqual(result["series"][0]["status"], "empty")
        self.assertEqual(result["series"][0]["points"], [])

    def test_http_series_returns_real_points_without_fabrication(self) -> None:
        service = PrometheusService(base_url="http://prometheus.example")
        payload = {
            "status": "success",
            "data": {"result": [{"values": [[1_700_000_000, "2.5"]]}]},
        }

        with patch.object(service, "query_range", return_value=payload):
            result = service.get_metrics_timeseries(
                namespace="team-a",
                range_value="15m",
                metric="error_rate",
            )

        self.assertEqual(result["series"][0]["status"], "ok")
        self.assertEqual(result["series"][0]["points"][0]["value"], 2.5)

    def test_restart_series_uses_namespace_scoped_interval_increase(self) -> None:
        definition = PrometheusService._timeseries_definitions(
            "team-a",
            restart_window="15m",
        )["pod_restarts"]

        self.assertEqual(
            definition["queries"],
            'sum(increase(kube_pod_container_status_restarts_total{namespace="team-a"}[5m]))',
        )
        self.assertNotIn("devdeploy-apps", definition["queries"])

    def test_restart_series_aggregates_all_containers_without_changing_the_summary(self) -> None:
        definition = PrometheusService._timeseries_definitions(
            "team-a",
            restart_window="15m",
        )["pod_restarts"]
        service = PrometheusService(base_url="http://prometheus.example")
        payload = {"status": "success", "data": {"result": []}}

        self.assertTrue(definition["queries"].startswith("sum(increase("))
        self.assertNotIn(" by (", definition["queries"])
        with patch.object(service, "query", return_value=payload) as query:
            summary = service._build_summary(namespace="team-a")

        self.assertIn(
            'sum(kube_pod_container_status_restarts_total{namespace="team-a"})',
            [call.args[0] for call in query.call_args_list],
        )
        self.assertEqual(summary["restart_count"], 0.0)

    def test_restart_series_preserves_zero_and_event_intervals(self) -> None:
        service = PrometheusService(base_url="http://prometheus.example")
        payload = {
            "status": "success",
            "data": {
                "result": [
                    {
                        "values": [
                            [1_700_000_000, "0"],
                            [1_700_000_300, "1"],
                            [1_700_000_600, "0"],
                            [1_700_000_900, "2"],
                        ]
                    }
                ]
            },
        }

        with patch.object(service, "query_range", return_value=payload):
            result = service.get_metrics_timeseries(
                namespace="team-a",
                range_value="15m",
                metric="pod_restarts",
            )

        self.assertEqual(
            [point["value"] for point in result["series"][0]["points"]],
            [0.0, 1.0, 0.0, 2.0],
        )
        self.assertEqual(result["series"][0]["status"], "ok")

    def test_empty_restart_series_remains_empty(self) -> None:
        service = PrometheusService(base_url="http://prometheus.example")
        payload = {"status": "success", "data": {"result": []}}

        with patch.object(service, "query_range", return_value=payload):
            result = service.get_metrics_timeseries(
                namespace="team-a",
                range_value="15m",
                metric="pod_restarts",
            )

        self.assertEqual(result["series"][0]["status"], "empty")
        self.assertEqual(result["series"][0]["points"], [])


class NamespaceLokiServiceTestCase(unittest.TestCase):
    def test_empty_selected_namespace_logs_are_a_successful_empty_result(self) -> None:
        service = LokiService(base_url="http://loki.example")

        with patch.object(service, "_query_range", return_value=[]) as query:
            result = service.query_logs(namespace="team-a", limit=100)

        self.assertEqual(result, [])
        query.assert_called_once_with(query='{namespace="team-a"}', limit=100)


if __name__ == "__main__":
    unittest.main()
