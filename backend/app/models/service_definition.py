from datetime import datetime, timezone

from sqlalchemy import CheckConstraint, Column, DateTime, ForeignKey, Integer, String, Text, UniqueConstraint
from sqlalchemy.orm import relationship

from app.db.base import Base


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
        UniqueConstraint("owner_id", "name", name="uq_service_definitions_owner_name"),
    )

    id = Column(Integer, primary_key=True, index=True)
    owner_id = Column(Integer, ForeignKey("users.id", ondelete="CASCADE"), nullable=False, index=True)
    name = Column(String(120), nullable=False)
    description = Column(Text, nullable=True)
    default_image = Column(String(512), nullable=True)
    default_replicas = Column(Integer, nullable=False, default=1)
    default_port = Column(Integer, nullable=True)
    created_at = Column(DateTime(timezone=True), nullable=False, default=utc_now)
    updated_at = Column(DateTime(timezone=True), nullable=False, default=utc_now, onupdate=utc_now)

    owner = relationship("User", back_populates="service_definitions")
    deployment_records = relationship("DeploymentRecord", back_populates="service_definition")
