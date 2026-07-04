"""Add archive timestamps to product domain records.

Revision ID: 20260705_0007
Revises: 20260704_0006
Create Date: 2026-07-05 00:07:00
"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


revision: str = "20260705_0007"
down_revision: Union[str, None] = "20260704_0006"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.add_column(
        "deployment_records",
        sa.Column("archived_at", sa.DateTime(timezone=True), nullable=True),
    )
    op.add_column(
        "service_definitions",
        sa.Column("archived_at", sa.DateTime(timezone=True), nullable=True),
    )


def downgrade() -> None:
    op.drop_column("service_definitions", "archived_at")
    op.drop_column("deployment_records", "archived_at")
