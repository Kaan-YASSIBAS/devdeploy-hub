from datetime import datetime, timezone

from sqlalchemy import CheckConstraint, Column, DateTime, ForeignKey, Integer, String, Text
from sqlalchemy.orm import relationship

from app.db.base import Base


def utc_now() -> datetime:
    return datetime.now(timezone.utc)


class Application(Base):
    __tablename__ = "applications"
    __table_args__ = (
        CheckConstraint(
            "default_environment IN ('dev', 'staging', 'prod')",
            name="ck_applications_default_environment",
        ),
    )

    id = Column(Integer, primary_key=True, index=True)
    name = Column(String(120), nullable=False)
    slug = Column(String(140), unique=True, index=True, nullable=False)
    description = Column(Text, nullable=True)
    repository_url = Column(String(500), nullable=True)
    image_name = Column(String(255), nullable=False)
    container_port = Column(Integer, nullable=False)
    default_environment = Column(String(32), nullable=False, default="dev")
    owner_id = Column(Integer, ForeignKey("users.id", ondelete="CASCADE"), nullable=False)
    created_at = Column(DateTime(timezone=True), nullable=False, default=utc_now)
    updated_at = Column(DateTime(timezone=True), nullable=True, onupdate=utc_now)

    owner = relationship("User", back_populates="applications")
    deployments = relationship("Deployment", back_populates="application", cascade="all, delete-orphan")
