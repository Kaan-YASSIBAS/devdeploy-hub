from datetime import datetime

from pydantic import BaseModel, Field


class ObservabilityComponentHealth(BaseModel):
    available: bool
    detail: str | None = None


class ObservabilityHealth(BaseModel):
    kubernetes: ObservabilityComponentHealth
    prometheus: ObservabilityComponentHealth
    loki: ObservabilityComponentHealth


class ClusterSummary(BaseModel):
    current_context: str | None = None
    namespaces_count: int
    pods_count: int
    deployments_count: int
    services_count: int
    nodes_count: int
    ready_nodes_count: int


class NamespaceSummary(BaseModel):
    name: str
    status: str | None = None
    created_at: datetime | None = None
    labels: dict[str, str] = Field(default_factory=dict)


class PodSummary(BaseModel):
    namespace: str
    name: str
    phase: str | None = None
    node_name: str | None = None
    restart_count: int
    containers_ready: str
    created_at: datetime | None = None
    labels: dict[str, str] = Field(default_factory=dict)


class DeploymentSummary(BaseModel):
    namespace: str
    name: str
    replicas: int
    ready_replicas: int
    available_replicas: int
    updated_replicas: int
    labels: dict[str, str] = Field(default_factory=dict)


class ServicePortSummary(BaseModel):
    name: str | None = None
    port: int
    target_port: str | int | None = None
    protocol: str | None = None


class ServiceSummary(BaseModel):
    namespace: str
    name: str
    type: str | None = None
    cluster_ip: str | None = None
    ports: list[ServicePortSummary] = Field(default_factory=list)
    labels: dict[str, str] = Field(default_factory=dict)


class MetricsSummary(BaseModel):
    cpu_usage_cores: float
    memory_working_set_bytes: float
    pod_count: float
    restart_count: float
    deployment_available_replicas: float


class MetricSeriesPoint(BaseModel):
    timestamp: datetime
    value: float


class MetricSeries(BaseModel):
    key: str
    name: str
    unit: str
    status: str = "ok"
    detail: str | None = None
    points: list[MetricSeriesPoint] = Field(default_factory=list)


class MetricsTimeSeriesResponse(BaseModel):
    namespace: str
    range: str
    step: str
    prometheus_available: bool = True
    series: list[MetricSeries] = Field(default_factory=list)


class LogEntry(BaseModel):
    timestamp: str
    line: str
    labels: dict[str, str] = Field(default_factory=dict)
