import unittest
from unittest.mock import patch

from app.services.preflight_service import CommandResult, PreflightService


class PreflightServiceTestCase(unittest.TestCase):
    def test_busy_platform_port_is_warning_not_blocking(self) -> None:
        with patch("app.services.preflight_service.socket.socket") as socket_factory:
            socket_factory.return_value.__enter__.return_value.bind.side_effect = OSError
            check = PreflightService._port_check("port_http_ingress", "HTTP ingress port 8080", 8080)

        self.assertEqual(check.status, "warning")
        self.assertIn("platform may already be running", check.message)

    def test_workload_context_is_valid_current_context(self) -> None:
        with patch.object(
            PreflightService,
            "_run_command",
            return_value=CommandResult(
                available=True,
                returncode=0,
                output="kind-devdeploy-workload",
            ),
        ):
            check = PreflightService._kubectl_context_check()

        self.assertEqual(check.status, "ok")

    def test_ready_multi_cluster_environment_satisfies_platform_gate(self) -> None:
        command_results = {
            ("kubectl", "config", "get-contexts", "-o", "name"): CommandResult(
                available=True,
                returncode=0,
                output="kind-devdeploy-mgmt\nkind-devdeploy-workload",
            ),
            ("kind", "get", "clusters"): CommandResult(
                available=True,
                returncode=0,
                output="devdeploy-mgmt\ndevdeploy-workload",
            ),
            ("kubectl", "config", "current-context"): CommandResult(
                available=True,
                returncode=0,
                output="kind-devdeploy-workload",
            ),
        }
        ok_check = PreflightService._check("test", "Test", "ok", "Ready")
        port_warning = PreflightService._check(
            "port_http_ingress",
            "HTTP ingress port 8080",
            "warning",
            "Port is in use; the platform may already be running.",
        )

        with (
            patch.object(PreflightService, "_detect_runtime_mode", return_value="host"),
            patch.object(
                PreflightService,
                "_run_command",
                side_effect=lambda command, timeout=5.0: command_results[tuple(command)],
            ),
            patch.object(PreflightService, "_docker_cli_check", return_value=ok_check),
            patch.object(PreflightService, "_docker_daemon_check", return_value=ok_check),
            patch.object(PreflightService, "_kind_cli_check", return_value=ok_check),
            patch.object(PreflightService, "_kubectl_cli_check", return_value=ok_check),
            patch.object(PreflightService, "_git_cli_check", return_value=ok_check),
            patch.object(PreflightService, "_port_checks", return_value=[port_warning]),
        ):
            result = PreflightService.run()

        self.assertTrue(result.contexts_ready)
        self.assertTrue(result.clusters_ready)
        self.assertTrue(result.platform_ready)
        self.assertEqual(result.overall_status, "warnings")

    def test_missing_required_context_is_actionable_but_not_a_failed_check(self) -> None:
        result = CommandResult(
            available=True,
            returncode=0,
            output="kind-devdeploy-mgmt",
        )

        check = PreflightService._required_kubectl_contexts_check(
            result,
            ["kind-devdeploy-mgmt"],
        )

        self.assertEqual(check.status, "warning")
        self.assertIn("kind-devdeploy-workload", check.details or "")

    def test_context_command_error_does_not_expose_local_paths(self) -> None:
        result = CommandResult(
            available=True,
            returncode=1,
            error=r'error loading config file "C:\\Users\\example\\.kube\\config"',
        )

        check = PreflightService._required_kubectl_contexts_check(result, [])

        self.assertEqual(check.status, "warning")
        self.assertIsNone(check.details)


if __name__ == "__main__":
    unittest.main()
