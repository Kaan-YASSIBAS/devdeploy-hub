from datetime import datetime, timezone

from sqlalchemy import CheckConstraint, Column, DateTime, ForeignKey, Integer, String, Text

from app.db.base import Base


def utc_now() -> datetime:
    return datetime.now(timezone.utc)


class GitOpsDeploymentRequest(Base):
    __tablename__ = "gitops_deployment_requests"
    __table_args__ = (
        CheckConstraint(
            "status IN ('pending', 'pending_manual_trigger', 'workflow_triggered', 'pr_opened', 'failed')",
            name="ck_gitops_deployment_requests_status",
        ),
    )

    id = Column(Integer, primary_key=True, index=True)
    application_id = Column(Integer, ForeignKey("applications.id", ondelete="SET NULL"), nullable=True)
    app_name = Column(String(63), nullable=False)
    image = Column(String(255), nullable=False)
    tag = Column(String(128), nullable=False)
    namespace = Column(String(63), nullable=False, default="devdeploy-workloads")
    container_port = Column(Integer, nullable=False)
    replicas = Column(Integer, nullable=False, default=1)
    ingress_host = Column(String(253), nullable=True)
    status = Column(String(40), nullable=False, default="pending")
    workflow_run_url = Column(String(500), nullable=True)
    pull_request_url = Column(String(500), nullable=True)
    error_message = Column(Text, nullable=True)
    created_by_id = Column(Integer, ForeignKey("users.id", ondelete="RESTRICT"), nullable=False)
    created_at = Column(DateTime(timezone=True), nullable=False, default=utc_now)
    updated_at = Column(DateTime(timezone=True), nullable=True, onupdate=utc_now)
