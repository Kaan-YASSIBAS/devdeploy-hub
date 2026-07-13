"""Add service HTTP telemetry configuration.

Revision ID: 20260713_0009
Revises: 20260706_0008
Create Date: 2026-07-13 00:09:00
"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


revision: str = "20260713_0009"
down_revision: Union[str, None] = "20260706_0008"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    with op.batch_alter_table("service_definitions") as batch_op:
        batch_op.add_column(
            sa.Column("telemetry_enabled", sa.Boolean(), server_default=sa.false(), nullable=False)
        )
        batch_op.add_column(
            sa.Column("telemetry_mode", sa.String(length=32), server_default="disabled", nullable=False)
        )
        batch_op.add_column(
            sa.Column("application_protocol", sa.String(length=16), server_default="http", nullable=False)
        )
        batch_op.add_column(sa.Column("application_container_port", sa.Integer(), nullable=True))
        batch_op.add_column(sa.Column("telemetry_proxy_listener_port", sa.Integer(), nullable=True))
        batch_op.add_column(sa.Column("telemetry_admin_port", sa.Integer(), nullable=True))
        batch_op.create_check_constraint(
            "ck_service_definitions_telemetry_mode",
            "telemetry_mode IN ('disabled', 'managed_http_proxy', 'application_native')",
        )
        batch_op.create_check_constraint(
            "ck_service_definitions_application_protocol",
            "application_protocol IN ('http', 'tcp')",
        )
        batch_op.create_check_constraint(
            "ck_service_definitions_application_container_port",
            "application_container_port IS NULL OR application_container_port BETWEEN 1 AND 65535",
        )
        batch_op.create_check_constraint(
            "ck_service_definitions_telemetry_proxy_listener_port",
            "telemetry_proxy_listener_port IS NULL OR telemetry_proxy_listener_port BETWEEN 1 AND 65535",
        )
        batch_op.create_check_constraint(
            "ck_service_definitions_telemetry_admin_port",
            "telemetry_admin_port IS NULL OR telemetry_admin_port BETWEEN 1 AND 65535",
        )
        batch_op.create_check_constraint(
            "ck_service_definitions_managed_proxy_required_fields",
            (
                "telemetry_mode != 'managed_http_proxy' OR "
                "(application_protocol = 'http' AND application_container_port IS NOT NULL "
                "AND default_port IS NOT NULL AND telemetry_proxy_listener_port IS NOT NULL "
                "AND telemetry_admin_port IS NOT NULL)"
            ),
        )
        batch_op.create_check_constraint(
            "ck_service_definitions_managed_proxy_runtime_port_conflicts",
            (
                "telemetry_mode != 'managed_http_proxy' OR "
                "(default_port != application_container_port "
                "AND default_port != telemetry_proxy_listener_port "
                "AND default_port != telemetry_admin_port "
                "AND application_container_port != telemetry_proxy_listener_port "
                "AND application_container_port != telemetry_admin_port "
                "AND telemetry_proxy_listener_port != telemetry_admin_port)"
            ),
        )


def downgrade() -> None:
    with op.batch_alter_table("service_definitions") as batch_op:
        batch_op.drop_constraint("ck_service_definitions_managed_proxy_runtime_port_conflicts", type_="check")
        batch_op.drop_constraint("ck_service_definitions_managed_proxy_required_fields", type_="check")
        batch_op.drop_constraint("ck_service_definitions_telemetry_admin_port", type_="check")
        batch_op.drop_constraint("ck_service_definitions_telemetry_proxy_listener_port", type_="check")
        batch_op.drop_constraint("ck_service_definitions_application_container_port", type_="check")
        batch_op.drop_constraint("ck_service_definitions_application_protocol", type_="check")
        batch_op.drop_constraint("ck_service_definitions_telemetry_mode", type_="check")
        batch_op.drop_column("telemetry_admin_port")
        batch_op.drop_column("telemetry_proxy_listener_port")
        batch_op.drop_column("application_container_port")
        batch_op.drop_column("application_protocol")
        batch_op.drop_column("telemetry_mode")
        batch_op.drop_column("telemetry_enabled")
