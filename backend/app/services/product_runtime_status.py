from datetime import datetime, timezone
from typing import Protocol

from app.models.deployment_record import DeploymentRecord
from app.models.service_definition import ServiceDefinition
from app.schemas.runtime_status import (
    DeploymentRuntimeStatusRead,
    RuntimeServicePortRead,
    ServiceRuntimeStatusRead,
    UntrackedDeploymentListResponse,
    UntrackedDeploymentRuntimeRead,
    UntrackedServiceListResponse,
    UntrackedServiceRuntimeRead,
)
from app.services.gitops.status_reader import (
    GitOpsStatusError,
    NamedWorkloadSnapshot,
    WorkloadSnapshot,
)


RUNTIME_UNAVAILABLE_MESSAGE = "Runtime status is temporarily unavailable."
UNTRACKED_MESSAGE = (
    "This Kubernetes runtime resource is not matched to a DevDeploy managed record."
)


class WorkloadRuntimeReader(Protocol):
    def read_workload(self, app_name: str, namespace: str) -> WorkloadSnapshot: ...

    def discover_workloads(self, namespace: str) -> tuple[NamedWorkloadSnapshot, ...]: ...


class UnavailableWorkloadRuntimeReader:
    def read_workload(self, app_name: str, namespace: str) -> WorkloadSnapshot:
        _ = (app_name, namespace)
        raise GitOpsStatusError("status_reader_unavailable", RUNTIME_UNAVAILABLE_MESSAGE)

    def discover_workloads(self, namespace: str) -> tuple[NamedWorkloadSnapshot, ...]:
        _ = namespace
        raise GitOpsStatusError("status_reader_unavailable", RUNTIME_UNAVAILABLE_MESSAGE)


class ProductRuntimeStatusService:
    def __init__(
        self,
        *,
        reader: WorkloadRuntimeReader | None = None,
        workload_namespace: str = "devdeploy-apps",
    ):
        self.reader = reader or UnavailableWorkloadRuntimeReader()
        self.workload_namespace = workload_namespace
        self._snapshots: dict[tuple[str, str], WorkloadSnapshot | None] = {}

    def deployment_status(self, deployment: DeploymentRecord) -> DeploymentRuntimeStatusRead:
        snapshot = self._safe_snapshot(deployment.app_name, deployment.namespace)
        observed_at = datetime.now(timezone.utc)
        if snapshot is None:
            return DeploymentRuntimeStatusRead(
                display_status="unknown",
                deployment_found=False,
                service_found=False,
                observed_at=observed_at,
                message=RUNTIME_UNAVAILABLE_MESSAGE,
            )

        display_status, message = self._deployment_display(snapshot)
        return DeploymentRuntimeStatusRead(
            display_status=display_status,
            deployment_found=snapshot.deployment_exists,
            service_found=snapshot.service_exists,
            desired_replicas=snapshot.desired_replicas,
            ready_replicas=snapshot.ready_replicas,
            available_replicas=snapshot.available_replicas,
            updated_replicas=snapshot.updated_replicas,
            pod_ready_count=snapshot.ready_pod_count,
            pod_total_count=snapshot.pod_count,
            service_type=snapshot.service_type,
            service_cluster_ip=snapshot.service_cluster_ip,
            service_ports=self._ports(snapshot),
            observed_at=observed_at,
            message=message,
        )

    def service_status(self, service: ServiceDefinition) -> ServiceRuntimeStatusRead:
        snapshot = self._safe_snapshot(service.name, self.workload_namespace)
        observed_at = datetime.now(timezone.utc)
        if snapshot is None:
            return ServiceRuntimeStatusRead(
                display_status="unknown",
                service_found=False,
                namespace=self.workload_namespace,
                observed_at=observed_at,
                message=RUNTIME_UNAVAILABLE_MESSAGE,
            )

        related_status, _ = self._deployment_display(snapshot)
        if not snapshot.service_exists:
            display_status = "not_found"
            message = "The managed Kubernetes Service was not found."
        elif snapshot.expected_service_port_exists:
            display_status = "ready"
            message = "The managed Kubernetes Service is ready."
        else:
            display_status = "unknown"
            message = "The managed Kubernetes Service exists but readiness could not be confirmed."

        return ServiceRuntimeStatusRead(
            display_status=display_status,
            service_found=snapshot.service_exists,
            namespace=self.workload_namespace,
            service_type=snapshot.service_type,
            cluster_ip=snapshot.service_cluster_ip,
            ports=self._ports(snapshot),
            related_deployment_found=snapshot.deployment_exists,
            related_deployment_status=related_status,
            observed_at=observed_at,
            message=message,
        )

    def untracked_deployments(
        self,
        managed_names: set[str],
    ) -> UntrackedDeploymentListResponse:
        snapshots = self._safe_discovery()
        if snapshots is None:
            return UntrackedDeploymentListResponse(
                items=[],
                runtime_available=False,
                message=RUNTIME_UNAVAILABLE_MESSAGE,
            )

        observed_at = datetime.now(timezone.utc)
        items = []
        for item in snapshots:
            snapshot = item.workload
            if item.name in managed_names or not snapshot.deployment_exists:
                continue
            display_status, _ = self._deployment_display(snapshot)
            items.append(
                UntrackedDeploymentRuntimeRead(
                    name=item.name,
                    namespace=self.workload_namespace,
                    display_status=display_status,
                    desired_replicas=snapshot.desired_replicas,
                    ready_replicas=snapshot.ready_replicas,
                    available_replicas=snapshot.available_replicas,
                    updated_replicas=snapshot.updated_replicas,
                    pod_ready_count=snapshot.ready_pod_count,
                    pod_total_count=snapshot.pod_count,
                    service_found=snapshot.service_exists,
                    service_ports=self._ports(snapshot),
                    observed_at=observed_at,
                    message=UNTRACKED_MESSAGE,
                )
            )
        return UntrackedDeploymentListResponse(items=items, runtime_available=True)

    def untracked_services(
        self,
        managed_names: set[str],
    ) -> UntrackedServiceListResponse:
        snapshots = self._safe_discovery()
        if snapshots is None:
            return UntrackedServiceListResponse(
                items=[],
                runtime_available=False,
                message=RUNTIME_UNAVAILABLE_MESSAGE,
            )

        observed_at = datetime.now(timezone.utc)
        items = []
        for item in snapshots:
            snapshot = item.workload
            if item.name in managed_names or not snapshot.service_exists:
                continue
            deployment_status, _ = self._deployment_display(snapshot)
            service_ready = bool(
                snapshot.service_cluster_ip
                and snapshot.service_cluster_ip != "None"
                and snapshot.service_ports
            )
            items.append(
                UntrackedServiceRuntimeRead(
                    name=item.name,
                    namespace=self.workload_namespace,
                    display_status="ready" if service_ready else "unknown",
                    service_type=snapshot.service_type,
                    cluster_ip=snapshot.service_cluster_ip,
                    ports=self._ports(snapshot),
                    related_deployment_found=snapshot.deployment_exists,
                    related_deployment_status=deployment_status,
                    observed_at=observed_at,
                    message=UNTRACKED_MESSAGE,
                )
            )
        return UntrackedServiceListResponse(items=items, runtime_available=True)

    def _safe_snapshot(self, app_name: str, namespace: str) -> WorkloadSnapshot | None:
        key = (namespace, app_name)
        if key in self._snapshots:
            return self._snapshots[key]
        try:
            snapshot = self.reader.read_workload(app_name, namespace)
        except Exception:
            snapshot = None
        self._snapshots[key] = snapshot
        return snapshot

    def _safe_discovery(self) -> tuple[NamedWorkloadSnapshot, ...] | None:
        try:
            return self.reader.discover_workloads(self.workload_namespace)
        except Exception:
            return None

    @staticmethod
    def _deployment_display(snapshot: WorkloadSnapshot) -> tuple[str, str]:
        if not snapshot.deployment_exists:
            return "not_found", "The managed Kubernetes Deployment was not found."
        if snapshot.failure_detected or snapshot.pod_crashloop_detected:
            return "unknown", "The managed workload reports a runtime failure."

        desired = snapshot.desired_replicas
        ready = snapshot.ready_replicas
        available = snapshot.available_replicas
        pods_ready = snapshot.ready_pod_count
        pod_count = snapshot.pod_count
        if (
            desired is not None
            and desired > 0
            and ready is not None
            and ready >= desired
            and available is not None
            and available >= desired
            and pod_count > 0
            and pods_ready >= pod_count
        ):
            return "running", "The managed workload is running and ready."
        return "progressing", "The managed workload is progressing toward readiness."

    @staticmethod
    def _ports(snapshot: WorkloadSnapshot) -> list[RuntimeServicePortRead] | None:
        if not snapshot.service_ports:
            return None
        return [
            RuntimeServicePortRead(
                name=port.name,
                port=port.port,
                target_port=port.target_port,
                protocol=port.protocol,
            )
            for port in snapshot.service_ports
        ]
