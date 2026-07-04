from datetime import datetime, timezone

from sqlalchemy import CheckConstraint, Column, DateTime, ForeignKey, Integer, String, Text
from sqlalchemy.orm import relationship

from app.db.base import Base


def utc_now() -> datetime:
    return datetime.now(timezone.utc)


class DeploymentRecord(Base):
    __tablename__ = "deployment_records"
    __table_args__ = (
        CheckConstraint("replicas BETWEEN 1 AND 20", name="ck_deployment_records_replicas"),
        CheckConstraint(
            "container_port BETWEEN 1 AND 65535",
            name="ck_deployment_records_container_port",
        ),
        CheckConstraint(
            "service_port BETWEEN 1 AND 65535",
            name="ck_deployment_records_service_port",
        ),
        CheckConstraint("service_type IN ('ClusterIP')", name="ck_deployment_records_service_type"),
        CheckConstraint(
            "desired_state IN ('draft', 'pending')",
            name="ck_deployment_records_desired_state",
        ),
    )

    id = Column(Integer, primary_key=True, index=True)
    owner_id = Column(Integer, ForeignKey("users.id", ondelete="CASCADE"), nullable=False, index=True)
    service_definition_id = Column(
        Integer,
        ForeignKey("service_definitions.id", ondelete="SET NULL"),
        nullable=True,
        index=True,
    )
    app_name = Column(String(40), nullable=False)
    image = Column(String(512), nullable=False)
    replicas = Column(Integer, nullable=False, default=1)
    container_port = Column(Integer, nullable=False, default=80)
    service_port = Column(Integer, nullable=False, default=80)
    service_type = Column(String(32), nullable=False, default="ClusterIP")
    namespace = Column(String(63), nullable=False, default="devdeploy-apps")
    gitops_manifest_path = Column(String(500), nullable=True)
    commit_sha = Column(String(64), nullable=True)
    desired_state = Column(String(32), nullable=False, default="draft")
    status_summary = Column(Text, nullable=True)
    created_at = Column(DateTime(timezone=True), nullable=False, default=utc_now)
    updated_at = Column(DateTime(timezone=True), nullable=False, default=utc_now, onupdate=utc_now)

    owner = relationship("User", back_populates="deployment_records")
    service_definition = relationship("ServiceDefinition", back_populates="deployment_records")
