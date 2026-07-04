from datetime import datetime, timezone

from sqlalchemy import Boolean, CheckConstraint, Column, DateTime, Integer, String
from sqlalchemy.orm import relationship

from app.db.base import Base


def utc_now() -> datetime:
    return datetime.now(timezone.utc)


class User(Base):
    __tablename__ = "users"
    __table_args__ = (
        CheckConstraint("role IN ('admin', 'developer')", name="ck_users_role"),
    )

    id = Column(Integer, primary_key=True, index=True)
    email = Column(String(255), unique=True, index=True, nullable=False)
    username = Column(String(80), unique=True, index=True, nullable=False)
    display_name = Column(String(120), nullable=True)
    hashed_password = Column(String(255), nullable=False)
    role = Column(String(32), nullable=False, default="developer")
    is_active = Column(Boolean, nullable=False, default=True)
    created_at = Column(DateTime(timezone=True), nullable=False, default=utc_now)
    updated_at = Column(DateTime(timezone=True), nullable=True, onupdate=utc_now)

    applications = relationship("Application", back_populates="owner", cascade="all, delete-orphan")
    deployments = relationship("Deployment", back_populates="requested_by")
    api_tokens = relationship("ApiToken", back_populates="user", cascade="all, delete-orphan")
    service_definitions = relationship(
        "ServiceDefinition",
        back_populates="owner",
        cascade="all, delete-orphan",
    )
    deployment_records = relationship(
        "DeploymentRecord",
        back_populates="owner",
        cascade="all, delete-orphan",
    )
