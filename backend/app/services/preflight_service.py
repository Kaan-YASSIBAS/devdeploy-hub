from __future__ import annotations

import shutil
import socket
import subprocess
from dataclasses import dataclass
import os
from pathlib import Path
from typing import cast

from app.schemas.setup import PreflightCheckStatus, SetupPreflightCheck, SetupPreflightResponse


LOCALHOST = "127.0.0.1"
REQUIRED_KIND_CLUSTERS = ("devdeploy-mgmt", "devdeploy-workload")
REQUIRED_KUBECTL_CONTEXTS = ("kind-devdeploy-mgmt", "kind-devdeploy-workload")
REQUIRED_PORTS = {
    "port_api_server": ("API server port 58080", 58080),
    "port_http_ingress": ("HTTP ingress port 8080", 8080),
    "port_https_ingress": ("HTTPS ingress port 8443", 8443),
}
SERVICE_ACCOUNT_TOKEN_PATH = Path("/var/run/secrets/kubernetes.io/serviceaccount/token")
KUBERNETES_RUNTIME_MESSAGE = (
    "Preflight is running inside the DevDeploy backend pod. Host tools such as Docker, kind, kubectl, and Git "
    "cannot be verified from this runtime. Future local environment creation should run from a local launcher/backend."
)
HOST_RUNTIME_MESSAGE = "Preflight is running in a host-local backend process, so host tools and ports can be verified."
HOST_LOCAL_CHECKS = [
    ("docker_cli", "Docker CLI"),
    ("docker_daemon", "Docker daemon"),
    ("kind_cli", "kind CLI"),
    ("kubectl_cli", "kubectl CLI"),
    ("git_cli", "Git CLI"),
    ("port_api_server", "API server port 58080"),
    ("port_http_ingress", "HTTP ingress port 8080"),
    ("port_https_ingress", "HTTPS ingress port 8443"),
    ("required_kubectl_contexts", "Required kubectl contexts"),
    ("kubectl_context", "Current kubectl context"),
    ("existing_devdeploy_clusters", "DevDeploy kind clusters"),
]


@dataclass(frozen=True)
class CommandResult:
    available: bool
    returncode: int | None = None
    output: str | None = None
    error: str | None = None


class PreflightService:
    """Read-only local environment checks for future setup automation."""

    @classmethod
    def run(cls) -> SetupPreflightResponse:
        runtime_mode = cls._detect_runtime_mode()
        runtime_message = cls._runtime_message(runtime_mode)

        if runtime_mode == "kubernetes":
            checks = cls._kubernetes_runtime_limited_checks()
            detected_contexts: list[str] = []
            detected_clusters: list[str] = []
            contexts_ready = False
            clusters_ready = False
        else:
            contexts_result = cls._run_command(["kubectl", "config", "get-contexts", "-o", "name"])
            clusters_result = cls._run_command(["kind", "get", "clusters"])
            detected_contexts = cls._result_lines(contexts_result)
            detected_clusters = cls._result_lines(clusters_result)
            contexts_ready = cls._contains_all(detected_contexts, REQUIRED_KUBECTL_CONTEXTS)
            clusters_ready = cls._contains_all(detected_clusters, REQUIRED_KIND_CLUSTERS)
            checks = [
                cls._docker_cli_check(),
                cls._docker_daemon_check(),
                cls._kind_cli_check(),
                cls._kubectl_cli_check(),
                cls._git_cli_check(),
                *cls._port_checks(),
                cls._required_kubectl_contexts_check(contexts_result, detected_contexts),
                cls._kubectl_context_check(),
                cls._existing_kind_clusters_check(clusters_result, detected_clusters),
            ]

        if any(check.status == "failed" for check in checks):
            overall_status = "blocked"
        elif any(check.status == "warning" for check in checks):
            overall_status = "warnings"
        else:
            overall_status = "ready"

        return SetupPreflightResponse(
            runtime_mode=runtime_mode,
            runtime_message=runtime_message,
            overall_status=overall_status,
            required_contexts=list(REQUIRED_KUBECTL_CONTEXTS),
            detected_contexts=detected_contexts,
            required_clusters=list(REQUIRED_KIND_CLUSTERS),
            detected_clusters=detected_clusters,
            contexts_ready=contexts_ready,
            clusters_ready=clusters_ready,
            platform_ready=contexts_ready and clusters_ready,
            checks=checks,
        )

    @staticmethod
    def _detect_runtime_mode() -> str:
        if os.getenv("KUBERNETES_SERVICE_HOST") or SERVICE_ACCOUNT_TOKEN_PATH.exists():
            return "kubernetes"
        return "host"

    @staticmethod
    def _runtime_message(runtime_mode: str) -> str:
        if runtime_mode == "kubernetes":
            return KUBERNETES_RUNTIME_MESSAGE
        if runtime_mode == "host":
            return HOST_RUNTIME_MESSAGE
        return "Preflight runtime could not be identified. Results may be limited."

    @classmethod
    def _kubernetes_runtime_limited_checks(cls) -> list[SetupPreflightCheck]:
        return [
            cls._check(
                check_id,
                label,
                "warning",
                "This host-local check is running inside the DevDeploy backend pod and cannot verify the user's host machine.",
                "Runtime mode: kubernetes",
            )
            for check_id, label in HOST_LOCAL_CHECKS
        ]

    @staticmethod
    def _command_exists(command: str) -> bool:
        return shutil.which(command) is not None

    @classmethod
    def _run_command(cls, command: list[str], timeout: float = 5.0) -> CommandResult:
        if not cls._command_exists(command[0]):
            return CommandResult(available=False, error=f"{command[0]} was not found on PATH.")

        try:
            completed = subprocess.run(
                command,
                capture_output=True,
                check=False,
                shell=False,
                text=True,
                timeout=timeout,
            )
        except subprocess.TimeoutExpired:
            return CommandResult(available=True, error=f"{command[0]} did not respond before timeout.")
        except OSError as exc:
            return CommandResult(available=True, error=f"{command[0]} could not be executed: {exc.__class__.__name__}.")

        output = (completed.stdout or completed.stderr or "").strip()
        return CommandResult(
            available=True,
            returncode=completed.returncode,
            output=cls._safe_output(output),
            error=None if completed.returncode == 0 else cls._safe_first_line(output),
        )

    @staticmethod
    def _safe_first_line(output: str | None) -> str | None:
        if not output:
            return None
        return output.splitlines()[0][:240]

    @staticmethod
    def _safe_output(output: str | None) -> str | None:
        if not output:
            return None
        lines = [line[:240] for line in output.splitlines()[:10]]
        return "\n".join(lines)

    @staticmethod
    def _result_lines(result: CommandResult) -> list[str]:
        if result.returncode != 0 or not result.output:
            return []
        return [line.strip() for line in result.output.splitlines() if line.strip()]

    @staticmethod
    def _contains_all(detected: list[str], required: tuple[str, ...]) -> bool:
        detected_set = set(detected)
        return all(item in detected_set for item in required)

    @classmethod
    def _docker_cli_check(cls) -> SetupPreflightCheck:
        result = cls._run_command(["docker", "--version"])
        if not result.available:
            return cls._check("docker_cli", "Docker CLI", "failed", "Docker CLI was not found.")
        if result.returncode != 0:
            return cls._check("docker_cli", "Docker CLI", "failed", "Docker CLI could not be executed.", result.error)
        return cls._check("docker_cli", "Docker CLI", "ok", "Docker CLI is installed.", result.output)

    @classmethod
    def _docker_daemon_check(cls) -> SetupPreflightCheck:
        result = cls._run_command(["docker", "info", "--format", "{{.ServerVersion}}"], timeout=8.0)
        if not result.available:
            return cls._check("docker_daemon", "Docker daemon", "failed", "Docker CLI was not found.")
        if result.returncode != 0:
            return cls._check("docker_daemon", "Docker daemon", "failed", "Docker daemon is not reachable.", result.error)
        return cls._check("docker_daemon", "Docker daemon", "ok", "Docker daemon is reachable.", result.output)

    @classmethod
    def _kind_cli_check(cls) -> SetupPreflightCheck:
        result = cls._run_command(["kind", "version"])
        if not result.available:
            return cls._check("kind_cli", "kind CLI", "failed", "kind CLI was not found.")
        if result.returncode != 0:
            return cls._check("kind_cli", "kind CLI", "failed", "kind CLI could not be executed.", result.error)
        return cls._check("kind_cli", "kind CLI", "ok", "kind CLI is installed.", result.output)

    @classmethod
    def _kubectl_cli_check(cls) -> SetupPreflightCheck:
        result = cls._run_command(["kubectl", "version", "--client"])
        if not result.available:
            return cls._check("kubectl_cli", "kubectl CLI", "failed", "kubectl CLI was not found.")
        if result.returncode != 0:
            return cls._check("kubectl_cli", "kubectl CLI", "failed", "kubectl CLI could not be executed.", result.error)
        return cls._check("kubectl_cli", "kubectl CLI", "ok", "kubectl CLI is installed.", result.output)

    @classmethod
    def _git_cli_check(cls) -> SetupPreflightCheck:
        result = cls._run_command(["git", "--version"])
        if not result.available:
            return cls._check("git_cli", "Git CLI", "warning", "Git CLI was not found.")
        if result.returncode != 0:
            return cls._check("git_cli", "Git CLI", "warning", "Git CLI could not be executed.", result.error)
        return cls._check("git_cli", "Git CLI", "ok", "Git CLI is installed.", result.output)

    @classmethod
    def _port_checks(cls) -> list[SetupPreflightCheck]:
        return [
            cls._port_check(check_id, label, port)
            for check_id, (label, port) in REQUIRED_PORTS.items()
        ]

    @classmethod
    def _port_check(cls, check_id: str, label: str, port: int) -> SetupPreflightCheck:
        try:
            with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
                sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
                sock.bind((LOCALHOST, port))
        except OSError:
            return cls._check(
                check_id,
                label,
                "warning",
                f"Port {port} is in use on {LOCALHOST}; the local DevDeploy platform may already be running.",
            )
        return cls._check(check_id, label, "ok", f"Port {port} is available on {LOCALHOST}.")

    @classmethod
    def _required_kubectl_contexts_check(
        cls,
        result: CommandResult,
        contexts: list[str],
    ) -> SetupPreflightCheck:
        if not result.available:
            return cls._check(
                "required_kubectl_contexts",
                "Required kubectl contexts",
                "warning",
                "kubectl CLI was not found, so required DevDeploy contexts could not be verified.",
            )
        if result.returncode != 0:
            return cls._check(
                "required_kubectl_contexts",
                "Required kubectl contexts",
                "warning",
                "Required DevDeploy kubectl contexts could not be listed.",
            )

        missing = [context for context in REQUIRED_KUBECTL_CONTEXTS if context not in set(contexts)]
        if missing:
            return cls._check(
                "required_kubectl_contexts",
                "Required kubectl contexts",
                "warning",
                "One or more required DevDeploy kubectl contexts are missing.",
                f"Missing: {', '.join(missing)}",
            )
        return cls._check(
            "required_kubectl_contexts",
            "Required kubectl contexts",
            "ok",
            "Management and workload kubectl contexts are available.",
            ", ".join(REQUIRED_KUBECTL_CONTEXTS),
        )

    @classmethod
    def _kubectl_context_check(cls) -> SetupPreflightCheck:
        result = cls._run_command(["kubectl", "config", "current-context"])
        if not result.available:
            return cls._check("kubectl_context", "Current kubectl context", "warning", "kubectl CLI was not found.")
        if result.returncode != 0:
            return cls._check(
                "kubectl_context",
                "Current kubectl context",
                "warning",
                "No current kubectl context is available.",
            )

        context = result.output or ""
        status: PreflightCheckStatus = "ok" if context in REQUIRED_KUBECTL_CONTEXTS else "warning"
        message = (
            "Current kubectl context targets a DevDeploy cluster."
            if status == "ok"
            else "Current kubectl context is informational and does not target a DevDeploy cluster."
        )
        return cls._check("kubectl_context", "Current kubectl context", status, message, context)

    @classmethod
    def _existing_kind_clusters_check(
        cls,
        result: CommandResult,
        clusters: list[str],
    ) -> SetupPreflightCheck:
        if not result.available:
            return cls._check(
                "existing_devdeploy_clusters",
                "DevDeploy kind clusters",
                "warning",
                "kind CLI was not found, so DevDeploy clusters could not be verified.",
            )
        if result.returncode != 0:
            return cls._check(
                "existing_devdeploy_clusters",
                "DevDeploy kind clusters",
                "warning",
                "Existing kind clusters could not be listed.",
                result.error,
            )

        missing = [cluster for cluster in REQUIRED_KIND_CLUSTERS if cluster not in set(clusters)]
        if missing:
            return cls._check(
                "existing_devdeploy_clusters",
                "DevDeploy kind clusters",
                "warning",
                "One or more required DevDeploy kind clusters are missing.",
                f"Missing: {', '.join(missing)}",
            )
        return cls._check(
            "existing_devdeploy_clusters",
            "DevDeploy kind clusters",
            "ok",
            "Management and workload kind clusters are available.",
            ", ".join(REQUIRED_KIND_CLUSTERS),
        )

    @staticmethod
    def _check(
        check_id: str,
        label: str,
        status: PreflightCheckStatus,
        message: str,
        details: str | None = None,
    ) -> SetupPreflightCheck:
        return SetupPreflightCheck(
            id=check_id,
            label=label,
            status=cast(PreflightCheckStatus, status),
            message=message,
            details=details,
        )
