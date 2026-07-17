from datetime import datetime, timezone
from typing import Protocol

from kubernetes import client
from kubernetes.client.exceptions import ApiException

from app.schemas.platform import PlatformClusterHealthItem, PlatformClusterHealthResponse
from app.services.gitops.kubernetes_status_reader import KubernetesGitOpsStatusReader
from app.services.gitops.status_reader import GitOpsStatusError


API_REQUEST_TIMEOUT = (3, 5)
LAUNCHER_RECOMMENDATION = "Run launcher preflight for detailed Docker/kind diagnostics."
WORKLOAD_RECOVERY_STEPS = [
    LAUNCHER_RECOMMENDATION,
    "Restart Docker Desktop and WSL before considering cluster recreation.",
    "Recreate only devdeploy-workload if launcher preflight still reports a corrupted API port.",
]
MANAGEMENT_RECOVERY_STEPS = [
    LAUNCHER_RECOMMENDATION,
    "Restart Docker Desktop and WSL before considering cluster recreation.",
    "Do not recreate devdeploy-mgmt unless platform data is backed up or local data loss is accepted.",
]


class ClusterApiProbe(Protocol):
    def check_api(self) -> None: ...


class KubernetesVersionApiProbe:
    def __init__(self, api_client: client.ApiClient):
        self.version_api = client.VersionApi(api_client)

    def check_api(self) -> None:
        self.version_api.get_code(_request_timeout=API_REQUEST_TIMEOUT)


class UnavailableClusterApiProbe:
    def check_api(self) -> None:
        raise GitOpsStatusError(
            "status_reader_unavailable",
            "Cluster API configuration is unavailable.",
        )


class PlatformClusterHealthService:
    def __init__(
        self,
        *,
        management_probe: ClusterApiProbe,
        workload_probe: ClusterApiProbe,
        management_context: str = "kind-devdeploy-mgmt",
        workload_context: str = "kind-devdeploy-workload",
    ):
        self.management_probe = management_probe
        self.workload_probe = workload_probe
        self.management_context = management_context
        self.workload_context = workload_context

    @classmethod
    def from_server_config(
        cls,
        *,
        management_kubeconfig: str | None,
        management_kubeconfig_context: str | None,
        workload_kubeconfig: str | None,
        workload_kubeconfig_context: str | None,
        use_in_cluster_management: bool,
    ) -> "PlatformClusterHealthService":
        management_probe = cls._build_probe(
            kubeconfig_path=management_kubeconfig,
            kubeconfig_context=management_kubeconfig_context,
            allow_in_cluster=use_in_cluster_management,
        )
        workload_probe = cls._build_probe(
            kubeconfig_path=workload_kubeconfig,
            kubeconfig_context=workload_kubeconfig_context,
            allow_in_cluster=False,
        )
        return cls(
            management_probe=management_probe,
            workload_probe=workload_probe,
            management_context=management_kubeconfig_context or "kind-devdeploy-mgmt",
            workload_context=workload_kubeconfig_context or "kind-devdeploy-workload",
        )

    def read_health(self) -> PlatformClusterHealthResponse:
        management = self._check_cluster(
                probe=self.management_probe,
                cluster_name="devdeploy-mgmt",
                context=self.management_context,
                role="management",
            )
        workload = self._check_cluster(
                probe=self.workload_probe,
                cluster_name="devdeploy-workload",
                context=self.workload_context,
                role="workload",
            )
        return PlatformClusterHealthResponse(
            management=management,
            workload=workload,
            platform_ready=(
                PlatformClusterHealthService._allows_platform_ready(management)
                and PlatformClusterHealthService._allows_platform_ready(workload)
            ),
        )

    @staticmethod
    def _build_probe(
        *,
        kubeconfig_path: str | None,
        kubeconfig_context: str | None,
        allow_in_cluster: bool,
    ) -> ClusterApiProbe:
        try:
            api_client = KubernetesGitOpsStatusReader._build_api_client(
                kubeconfig_path=kubeconfig_path,
                kubeconfig_context=kubeconfig_context,
                allow_in_cluster=allow_in_cluster,
            )
        except GitOpsStatusError:
            return UnavailableClusterApiProbe()
        return KubernetesVersionApiProbe(api_client)

    @staticmethod
    def _check_cluster(
        *,
        probe: ClusterApiProbe,
        cluster_name: str,
        context: str,
        role: str,
    ) -> PlatformClusterHealthItem:
        checked_at = datetime.now(timezone.utc)
        try:
            probe.check_api()
        except GitOpsStatusError:
            return PlatformClusterHealthService._configuration_item(
                cluster_name=cluster_name,
                context=context,
                role=role,
                checked_at=checked_at,
            )
        except ApiException as exc:
            return PlatformClusterHealthService._api_error_item(
                cluster_name=cluster_name,
                context=context,
                role=role,
                http_status=exc.status,
                checked_at=checked_at,
            )
        except Exception:
            return PlatformClusterHealthService._unreachable_item(
                cluster_name=cluster_name,
                context=context,
                role=role,
                reason="api_unreachable",
                checked_at=checked_at,
            )

        return PlatformClusterHealthItem(
            cluster_name=cluster_name,
            context=context,
            role=role,
            status="healthy",
            api_reachable=True,
            reason="ok",
            message=f"{PlatformClusterHealthService._role_label(role)} cluster API is reachable.",
            checked_at=checked_at,
        )

    @staticmethod
    def _configuration_item(
        *,
        cluster_name: str,
        context: str,
        role: str,
        checked_at: datetime,
    ) -> PlatformClusterHealthItem:
        return PlatformClusterHealthItem(
            cluster_name=cluster_name,
            context=context,
            role=role,
            status="unknown",
            api_reachable=False,
            reason="configuration_unavailable",
            message=(
                f"{PlatformClusterHealthService._role_label(role)} cluster API configuration "
                "is unavailable."
            ),
            recommended_action=LAUNCHER_RECOMMENDATION,
            checked_at=checked_at,
        )

    @staticmethod
    def _api_error_item(
        *,
        cluster_name: str,
        context: str,
        role: str,
        http_status: int | None,
        checked_at: datetime,
    ) -> PlatformClusterHealthItem:
        if http_status == 403:
            reason = "api_forbidden"
            message = (
                f"{PlatformClusterHealthService._role_label(role)} cluster API is reachable, "
                "but an optional diagnostic request was forbidden."
            )
            recommended_action = "Review the backend read-only Kubernetes permissions."
        elif http_status == 401:
            reason = "authentication_failed"
            message = (
                f"{PlatformClusterHealthService._role_label(role)} cluster API is reachable, "
                "but authentication failed."
            )
            recommended_action = "Reconcile the launcher-managed Kubernetes credentials."
        elif http_status:
            reason = "api_degraded"
            message = (
                f"{PlatformClusterHealthService._role_label(role)} cluster API is reachable, "
                "but its health probe returned an unhealthy response."
            )
            recommended_action = LAUNCHER_RECOMMENDATION
        else:
            return PlatformClusterHealthService._unreachable_item(
                cluster_name=cluster_name,
                context=context,
                role=role,
                reason="api_unreachable",
                checked_at=checked_at,
            )

        return PlatformClusterHealthItem(
            cluster_name=cluster_name,
            context=context,
            role=role,
            status="degraded",
            api_reachable=True,
            reason=reason,
            message=message,
            recommended_action=recommended_action,
            checked_at=checked_at,
        )

    @staticmethod
    def _allows_platform_ready(item: PlatformClusterHealthItem) -> bool:
        return item.status == "healthy" or item.reason == "api_forbidden"

    @staticmethod
    def _unreachable_item(
        *,
        cluster_name: str,
        context: str,
        role: str,
        reason: str,
        checked_at: datetime,
    ) -> PlatformClusterHealthItem:
        if role == "management":
            message = "Management cluster API is not reachable. Platform services may be unavailable."
            recommended_action = (
                "Run launcher preflight first. Management cluster recovery may affect platform data; "
                "do not recreate it without a backup or accepting local data loss."
            )
            impact = [
                "DevDeploy platform services, PostgreSQL, and Argo CD may be unavailable.",
                "Recreating the management cluster may remove local platform data.",
            ]
            recovery_steps = MANAGEMENT_RECOVERY_STEPS
        else:
            message = (
                "Workload cluster API is not reachable. Runtime status and reconcile checks may be unavailable."
            )
            recommended_action = (
                "Run launcher preflight. Recreate only devdeploy-workload if preflight still reports a "
                "corrupted API port after Docker Desktop and WSL restart."
            )
            impact = [
                "Runtime status, untracked discovery, drift comparison, and reconcile validation may be unavailable.",
                "If the workload cluster is recreated, runtime resources may be lost while DevDeploy records and GitOps manifests remain.",
            ]
            recovery_steps = WORKLOAD_RECOVERY_STEPS
        return PlatformClusterHealthItem(
            cluster_name=cluster_name,
            context=context,
            role=role,
            status="unreachable",
            api_reachable=False,
            reason=reason,
            message=message,
            recommended_action=recommended_action,
            impact=impact,
            recovery_steps=recovery_steps,
            checked_at=checked_at,
        )

    @staticmethod
    def _role_label(role: str) -> str:
        return "Management" if role == "management" else "Workload"
