from datetime import datetime, timezone

from sqlalchemy import Boolean, CheckConstraint, Column, DateTime, ForeignKey, Integer, String, Text, UniqueConstraint
from sqlalchemy.orm import relationship

from app.db.base import Base
from app.schemas.telemetry import HttpTelemetryConfig, disabled_telemetry


def utc_now() -> datetime:
    return datetime.now(timezone.utc)


class ServiceDefinition(Base):
    __tablename__ = "service_definitions"
    __table_args__ = (
        CheckConstraint(
            "default_replicas BETWEEN 1 AND 20",
            name="ck_service_definitions_default_replicas",
        ),
        CheckConstraint(
            "default_port IS NULL OR default_port BETWEEN 1 AND 65535",
            name="ck_service_definitions_default_port",
        ),
        CheckConstraint(
            "telemetry_mode IN ('disabled', 'managed_http_proxy', 'application_native')",
            name="ck_service_definitions_telemetry_mode",
        ),
        CheckConstraint(
            "application_protocol IN ('http', 'tcp')",
            name="ck_service_definitions_application_protocol",
        ),
        CheckConstraint(
            "application_container_port IS NULL OR application_container_port BETWEEN 1 AND 65535",
            name="ck_service_definitions_application_container_port",
        ),
        CheckConstraint(
            "telemetry_proxy_listener_port IS NULL OR telemetry_proxy_listener_port BETWEEN 1 AND 65535",
            name="ck_service_definitions_telemetry_proxy_listener_port",
        ),
        CheckConstraint(
            "telemetry_admin_port IS NULL OR telemetry_admin_port BETWEEN 1 AND 65535",
            name="ck_service_definitions_telemetry_admin_port",
        ),
        CheckConstraint(
            (
                "telemetry_mode != 'managed_http_proxy' OR "
                "(application_protocol = 'http' AND application_container_port IS NOT NULL "
                "AND default_port IS NOT NULL AND telemetry_proxy_listener_port IS NOT NULL "
                "AND telemetry_admin_port IS NOT NULL)"
            ),
            name="ck_service_definitions_managed_proxy_required_fields",
        ),
        CheckConstraint(
            (
                "telemetry_mode != 'managed_http_proxy' OR "
                "(default_port != application_container_port "
                "AND default_port != telemetry_proxy_listener_port "
                "AND default_port != telemetry_admin_port "
                "AND application_container_port != telemetry_proxy_listener_port "
                "AND application_container_port != telemetry_admin_port "
                "AND telemetry_proxy_listener_port != telemetry_admin_port)"
            ),
            name="ck_service_definitions_managed_proxy_runtime_port_conflicts",
        ),
        UniqueConstraint("owner_id", "name", name="uq_service_definitions_owner_name"),
    )

    id = Column(Integer, primary_key=True, index=True)
    owner_id = Column(Integer, ForeignKey("users.id", ondelete="CASCADE"), nullable=False, index=True)
    name = Column(String(120), nullable=False)
    description = Column(Text, nullable=True)
    default_image = Column(String(512), nullable=True)
    default_replicas = Column(Integer, nullable=False, default=1)
    default_port = Column(Integer, nullable=True)
    telemetry_enabled = Column(Boolean, nullable=False, default=False)
    telemetry_mode = Column(String(32), nullable=False, default="disabled")
    application_protocol = Column(String(16), nullable=False, default="http")
    application_container_port = Column(Integer, nullable=True)
    telemetry_proxy_listener_port = Column(Integer, nullable=True)
    telemetry_admin_port = Column(Integer, nullable=True)
    archived_at = Column(DateTime(timezone=True), nullable=True)
    created_at = Column(DateTime(timezone=True), nullable=False, default=utc_now)
    updated_at = Column(DateTime(timezone=True), nullable=False, default=utc_now, onupdate=utc_now)

    owner = relationship("User", back_populates="service_definitions")
    deployment_records = relationship("DeploymentRecord", back_populates="service_definition")

    @property
    def telemetry(self) -> HttpTelemetryConfig:
        if not self.telemetry_enabled or self.telemetry_mode == "disabled":
            return disabled_telemetry()
        return HttpTelemetryConfig(
            enabled=bool(self.telemetry_enabled),
            mode=self.telemetry_mode,
            application_protocol=self.application_protocol,
            application_container_port=self.application_container_port,
            service_port=self.default_port,
            proxy_listener_port=self.telemetry_proxy_listener_port,
            admin_port=self.telemetry_admin_port,
        )
