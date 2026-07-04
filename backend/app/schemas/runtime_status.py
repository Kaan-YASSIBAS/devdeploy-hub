from datetime import datetime
from typing import Literal

from pydantic import BaseModel


class RuntimeServicePortRead(BaseModel):
    name: str | None = None
    port: int
    target_port: int | str | None = None
    protocol: str | None = None


class DeploymentRuntimeStatusRead(BaseModel):
    source: Literal["kubernetes"] = "kubernetes"
    display_status: Literal["running", "progressing", "not_found", "unknown"]
    deployment_found: bool
    service_found: bool
    desired_replicas: int | None = None
    ready_replicas: int | None = None
    available_replicas: int | None = None
    updated_replicas: int | None = None
    pod_ready_count: int | None = None
    pod_total_count: int | None = None
    service_type: str | None = None
    service_cluster_ip: str | None = None
    service_ports: list[RuntimeServicePortRead] | None = None
    observed_at: datetime | None = None
    message: str | None = None


class ServiceRuntimeStatusRead(BaseModel):
    source: Literal["kubernetes"] = "kubernetes"
    display_status: Literal["ready", "not_found", "unknown"]
    service_found: bool
    namespace: str
    service_type: str | None = None
    cluster_ip: str | None = None
    ports: list[RuntimeServicePortRead] | None = None
    related_deployment_found: bool | None = None
    related_deployment_status: str | None = None
    observed_at: datetime | None = None
    message: str | None = None
