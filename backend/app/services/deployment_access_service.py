from app.models.deployment_record import DeploymentRecord
from app.schemas.deployment_access import (
    DeploymentAccessRead,
    DeploymentAccessServiceRead,
    DeploymentAccessStatus,
)
from app.services.gitops.status_reader import ServicePortSnapshot, WorkloadSnapshot
from app.services.product_runtime_status import ProductRuntimeStatusService


HTTP_PORT_NAMES = {"http", "https", "web"}
COMMON_HTTP_PORTS = {80, 443, 8080, 8443}
SUPPORTED_SERVICE_TYPES = {"ClusterIP"}


class DeploymentAccessService:
    def __init__(self, runtime_service: ProductRuntimeStatusService):
        self.runtime_service = runtime_service

    def evaluate(self, deployment: DeploymentRecord) -> DeploymentAccessRead:
        try:
            snapshot = self.runtime_service.workload_snapshot(
                deployment.app_name,
                deployment.namespace,
            )
            if snapshot is None:
                return self._response(
                    deployment,
                    status="runtime_unavailable",
                    message="Workload runtime access is temporarily unavailable.",
                )
            if not self._deployment_ready(snapshot):
                return self._response(
                    deployment,
                    status="not_ready",
                    message="The managed workload is not ready for app access.",
                    service=self._service_metadata(deployment, snapshot),
                )
            if not snapshot.service_exists:
                return self._response(
                    deployment,
                    status="service_missing",
                    message="The managed Kubernetes Service was not found.",
                )
            if snapshot.service_type not in SUPPORTED_SERVICE_TYPES:
                return self._response(
                    deployment,
                    status="unsupported",
                    message="The managed Service type is not supported for browser preview.",
                    service=self._service_metadata(deployment, snapshot),
                )

            port = self._select_http_port(snapshot.service_ports)
            if port is None:
                return self._response(
                    deployment,
                    status="unsupported",
                    message="No supported HTTP-like Service port was found.",
                    service=self._service_metadata(deployment, snapshot),
                )

            return self._response(
                deployment,
                available=True,
                status="available",
                message=(
                    "The app appears reachable. Browser preview will be enabled in a later phase."
                ),
                service=DeploymentAccessServiceRead(
                    name=deployment.app_name,
                    namespace=deployment.namespace,
                    port=port.port,
                    service_type=snapshot.service_type,
                ),
            )
        except Exception:
            return self._response(
                deployment,
                status="unknown",
                message="App access status could not be determined safely.",
            )

    @staticmethod
    def _deployment_ready(snapshot: WorkloadSnapshot) -> bool:
        desired = snapshot.desired_replicas
        ready = snapshot.ready_replicas
        available = snapshot.available_replicas
        return bool(
            snapshot.deployment_exists
            and not snapshot.failure_detected
            and not snapshot.pod_crashloop_detected
            and desired is not None
            and desired > 0
            and ready is not None
            and ready >= desired
            and available is not None
            and available >= desired
            and snapshot.pod_count > 0
            and snapshot.ready_pod_count >= snapshot.pod_count
        )

    @staticmethod
    def _select_http_port(
        ports: tuple[ServicePortSnapshot, ...],
    ) -> ServicePortSnapshot | None:
        for port in ports:
            name = (port.name or "").lower()
            protocol = (port.protocol or "TCP").upper()
            if protocol == "TCP" and (name in HTTP_PORT_NAMES or port.port in COMMON_HTTP_PORTS):
                return port
        return None

    @staticmethod
    def _service_metadata(
        deployment: DeploymentRecord,
        snapshot: WorkloadSnapshot,
    ) -> DeploymentAccessServiceRead | None:
        if not snapshot.service_exists:
            return None
        port = DeploymentAccessService._select_http_port(snapshot.service_ports)
        return DeploymentAccessServiceRead(
            name=deployment.app_name,
            namespace=deployment.namespace,
            port=port.port if port else None,
            service_type=snapshot.service_type,
        )

    @staticmethod
    def _response(
        deployment: DeploymentRecord,
        *,
        status: DeploymentAccessStatus,
        message: str,
        available: bool = False,
        service: DeploymentAccessServiceRead | None = None,
    ) -> DeploymentAccessRead:
        return DeploymentAccessRead(
            available=available,
            status=status,
            app_name=deployment.app_name,
            message=message,
            service=service,
        )
