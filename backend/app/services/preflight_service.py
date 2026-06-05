from __future__ import annotations

import shutil
import socket
import subprocess
from dataclasses import dataclass

from app.schemas.setup import SetupPreflightCheck, SetupPreflightResponse


LOCALHOST = "127.0.0.1"
DEFAULT_KIND_CLUSTER_NAME = "devdeploy"
DEFAULT_KUBECTL_CONTEXT = "kind-devdeploy"
REQUIRED_PORTS = {
    "port_api_server": ("API server port 58080", 58080),
    "port_http_ingress": ("HTTP ingress port 8080", 8080),
    "port_https_ingress": ("HTTPS ingress port 8443", 8443),
}


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
        checks = [
            cls._docker_cli_check(),
            cls._docker_daemon_check(),
            cls._kind_cli_check(),
            cls._kubectl_cli_check(),
            cls._git_cli_check(),
            *cls._port_checks(),
            cls._kubectl_context_check(),
            cls._existing_kind_cluster_check(),
        ]

        if any(check.status == "failed" for check in checks):
            overall_status = "blocked"
        elif any(check.status == "warning" for check in checks):
            overall_status = "warnings"
        else:
            overall_status = "ready"

        return SetupPreflightResponse(overall_status=overall_status, checks=checks)

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
                "failed",
                f"Port {port} is already in use on {LOCALHOST}.",
            )
        return cls._check(check_id, label, "ok", f"Port {port} is available on {LOCALHOST}.")

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
                result.error,
            )

        context = result.output or ""
        status = "ok" if context == DEFAULT_KUBECTL_CONTEXT else "warning"
        message = (
            "Current kubectl context targets the default DevDeploy kind cluster."
            if status == "ok"
            else "Current kubectl context is not kind-devdeploy."
        )
        return cls._check("kubectl_context", "Current kubectl context", status, message, context)

    @classmethod
    def _existing_kind_cluster_check(cls) -> SetupPreflightCheck:
        result = cls._run_command(["kind", "get", "clusters"])
        if not result.available:
            return cls._check("existing_devdeploy_cluster", "Existing devdeploy cluster", "warning", "kind CLI was not found.")
        if result.returncode != 0:
            return cls._check(
                "existing_devdeploy_cluster",
                "Existing devdeploy cluster",
                "warning",
                "Existing kind clusters could not be listed.",
                result.error,
            )

        clusters = {line.strip() for line in (result.output or "").splitlines() if line.strip()}
        if DEFAULT_KIND_CLUSTER_NAME in clusters:
            return cls._check(
                "existing_devdeploy_cluster",
                "Existing devdeploy cluster",
                "warning",
                "A kind cluster named devdeploy already exists.",
                DEFAULT_KIND_CLUSTER_NAME,
            )
        return cls._check(
            "existing_devdeploy_cluster",
            "Existing devdeploy cluster",
            "ok",
            "No kind cluster named devdeploy was detected.",
        )

    @staticmethod
    def _check(
        check_id: str,
        label: str,
        status: str,
        message: str,
        details: str | None = None,
    ) -> SetupPreflightCheck:
        return SetupPreflightCheck(
            id=check_id,
            label=label,
            status=status,  # type: ignore[arg-type]
            message=message,
            details=details,
        )
