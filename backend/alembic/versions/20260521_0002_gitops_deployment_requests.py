"""Add GitOps deployment requests.

Revision ID: 20260521_0002
Revises: 20260520_0001
Create Date: 2026-05-21 00:02:00
"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


revision: str = "20260521_0002"
down_revision: Union[str, None] = "20260520_0001"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.create_table(
        "gitops_deployment_requests",
        sa.Column("id", sa.Integer(), nullable=False),
        sa.Column("application_id", sa.Integer(), nullable=True),
        sa.Column("app_name", sa.String(length=63), nullable=False),
        sa.Column("image", sa.String(length=255), nullable=False),
        sa.Column("tag", sa.String(length=128), nullable=False),
        sa.Column("namespace", sa.String(length=63), server_default="devdeploy-workloads", nullable=False),
        sa.Column("container_port", sa.Integer(), nullable=False),
        sa.Column("replicas", sa.Integer(), server_default="1", nullable=False),
        sa.Column("ingress_host", sa.String(length=253), nullable=True),
        sa.Column("status", sa.String(length=40), server_default="pending", nullable=False),
        sa.Column("workflow_run_url", sa.String(length=500), nullable=True),
        sa.Column("pull_request_url", sa.String(length=500), nullable=True),
        sa.Column("error_message", sa.Text(), nullable=True),
        sa.Column("created_by_id", sa.Integer(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.text("now()"), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=True),
        sa.CheckConstraint(
            "status IN ('pending', 'pending_manual_trigger', 'workflow_triggered', 'pr_opened', 'failed')",
            name="ck_gitops_deployment_requests_status",
        ),
        sa.ForeignKeyConstraint(["application_id"], ["applications.id"], ondelete="SET NULL"),
        sa.ForeignKeyConstraint(["created_by_id"], ["users.id"], ondelete="RESTRICT"),
        sa.PrimaryKeyConstraint("id"),
    )
    op.create_index("ix_gitops_deployment_requests_id", "gitops_deployment_requests", ["id"], unique=False)


def downgrade() -> None:
    op.drop_index("ix_gitops_deployment_requests_id", table_name="gitops_deployment_requests")
    op.drop_table("gitops_deployment_requests")
