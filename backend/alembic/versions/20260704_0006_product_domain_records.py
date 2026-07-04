"""Add first-class service definitions and deployment records.

Revision ID: 20260704_0006
Revises: 20260522_0005
Create Date: 2026-07-04 00:06:00
"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


revision: str = "20260704_0006"
down_revision: Union[str, None] = "20260522_0005"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.create_table(
        "service_definitions",
        sa.Column("id", sa.Integer(), nullable=False),
        sa.Column("owner_id", sa.Integer(), nullable=False),
        sa.Column("name", sa.String(length=120), nullable=False),
        sa.Column("description", sa.Text(), nullable=True),
        sa.Column("default_image", sa.String(length=512), nullable=True),
        sa.Column("default_replicas", sa.Integer(), server_default="1", nullable=False),
        sa.Column("default_port", sa.Integer(), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.text("now()"), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.text("now()"), nullable=False),
        sa.CheckConstraint(
            "default_replicas BETWEEN 1 AND 20",
            name="ck_service_definitions_default_replicas",
        ),
        sa.CheckConstraint(
            "default_port IS NULL OR default_port BETWEEN 1 AND 65535",
            name="ck_service_definitions_default_port",
        ),
        sa.ForeignKeyConstraint(["owner_id"], ["users.id"], ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint("owner_id", "name", name="uq_service_definitions_owner_name"),
    )
    op.create_index("ix_service_definitions_id", "service_definitions", ["id"], unique=False)
    op.create_index("ix_service_definitions_owner_id", "service_definitions", ["owner_id"], unique=False)

    op.create_table(
        "deployment_records",
        sa.Column("id", sa.Integer(), nullable=False),
        sa.Column("owner_id", sa.Integer(), nullable=False),
        sa.Column("service_definition_id", sa.Integer(), nullable=True),
        sa.Column("app_name", sa.String(length=40), nullable=False),
        sa.Column("image", sa.String(length=512), nullable=False),
        sa.Column("replicas", sa.Integer(), server_default="1", nullable=False),
        sa.Column("container_port", sa.Integer(), server_default="80", nullable=False),
        sa.Column("service_port", sa.Integer(), server_default="80", nullable=False),
        sa.Column("service_type", sa.String(length=32), server_default="ClusterIP", nullable=False),
        sa.Column("namespace", sa.String(length=63), server_default="devdeploy-apps", nullable=False),
        sa.Column("gitops_manifest_path", sa.String(length=500), nullable=True),
        sa.Column("commit_sha", sa.String(length=64), nullable=True),
        sa.Column("desired_state", sa.String(length=32), server_default="draft", nullable=False),
        sa.Column("status_summary", sa.Text(), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.text("now()"), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.text("now()"), nullable=False),
        sa.CheckConstraint("replicas BETWEEN 1 AND 20", name="ck_deployment_records_replicas"),
        sa.CheckConstraint(
            "container_port BETWEEN 1 AND 65535",
            name="ck_deployment_records_container_port",
        ),
        sa.CheckConstraint(
            "service_port BETWEEN 1 AND 65535",
            name="ck_deployment_records_service_port",
        ),
        sa.CheckConstraint("service_type IN ('ClusterIP')", name="ck_deployment_records_service_type"),
        sa.CheckConstraint(
            "desired_state IN ('draft', 'pending')",
            name="ck_deployment_records_desired_state",
        ),
        sa.ForeignKeyConstraint(["owner_id"], ["users.id"], ondelete="CASCADE"),
        sa.ForeignKeyConstraint(
            ["service_definition_id"],
            ["service_definitions.id"],
            ondelete="SET NULL",
        ),
        sa.PrimaryKeyConstraint("id"),
    )
    op.create_index("ix_deployment_records_id", "deployment_records", ["id"], unique=False)
    op.create_index("ix_deployment_records_owner_id", "deployment_records", ["owner_id"], unique=False)
    op.create_index(
        "ix_deployment_records_service_definition_id",
        "deployment_records",
        ["service_definition_id"],
        unique=False,
    )


def downgrade() -> None:
    op.drop_index("ix_deployment_records_service_definition_id", table_name="deployment_records")
    op.drop_index("ix_deployment_records_owner_id", table_name="deployment_records")
    op.drop_index("ix_deployment_records_id", table_name="deployment_records")
    op.drop_table("deployment_records")
    op.drop_index("ix_service_definitions_owner_id", table_name="service_definitions")
    op.drop_index("ix_service_definitions_id", table_name="service_definitions")
    op.drop_table("service_definitions")
