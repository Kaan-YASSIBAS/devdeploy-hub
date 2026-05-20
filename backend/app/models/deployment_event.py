from datetime import datetime, timezone

from sqlalchemy import CheckConstraint, Column, DateTime, ForeignKey, Integer, String
from sqlalchemy.orm import relationship

from app.db.base import Base


def utc_now() -> datetime:
    return datetime.now(timezone.utc)


class DeploymentEvent(Base):
    __tablename__ = "deployment_events"
    __table_args__ = (
        CheckConstraint("level IN ('info', 'warning', 'error', 'success')", name="ck_deployment_events_level"),
    )

    id = Column(Integer, primary_key=True, index=True)
    deployment_id = Column(Integer, ForeignKey("deployments.id", ondelete="CASCADE"), nullable=False)
    event_type = Column(String(80), nullable=False)
    level = Column(String(32), nullable=False, default="info")
    message = Column(String(500), nullable=False)
    created_at = Column(DateTime(timezone=True), nullable=False, default=utc_now)

    deployment = relationship("Deployment", back_populates="events")
