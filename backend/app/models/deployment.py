from datetime import datetime, timezone

from sqlalchemy import CheckConstraint, Column, DateTime, ForeignKey, Integer, String
from sqlalchemy.orm import relationship

from app.db.base import Base


def utc_now() -> datetime:
    return datetime.now(timezone.utc)


class Deployment(Base):
    __tablename__ = "deployments"
    __table_args__ = (
        CheckConstraint("environment IN ('dev', 'staging', 'prod')", name="ck_deployments_environment"),
        CheckConstraint("status IN ('pending', 'running', 'success', 'failed')", name="ck_deployments_status"),
        CheckConstraint("strategy IN ('rolling', 'recreate')", name="ck_deployments_strategy"),
    )

    id = Column(Integer, primary_key=True, index=True)
    application_id = Column(Integer, ForeignKey("applications.id", ondelete="CASCADE"), nullable=False)
    environment = Column(String(32), nullable=False)
    image_tag = Column(String(120), nullable=False)
    replica_count = Column(Integer, nullable=False)
    strategy = Column(String(32), nullable=False, default="rolling")
    status = Column(String(32), nullable=False, default="pending")
    requested_by_id = Column(Integer, ForeignKey("users.id", ondelete="RESTRICT"), nullable=False)
    created_at = Column(DateTime(timezone=True), nullable=False, default=utc_now)
    updated_at = Column(DateTime(timezone=True), nullable=True, onupdate=utc_now)

    application = relationship("Application", back_populates="deployments")
    requested_by = relationship("User", back_populates="deployments")
    events = relationship(
        "DeploymentEvent",
        back_populates="deployment",
        cascade="all, delete-orphan",
        order_by="DeploymentEvent.created_at",
    )
