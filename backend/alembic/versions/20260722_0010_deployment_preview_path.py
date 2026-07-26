"""Add deployment preview path.

Revision ID: 20260722_0010
Revises: 20260713_0009
Create Date: 2026-07-22 00:10:00
"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


revision: str = "20260722_0010"
down_revision: Union[str, None] = "20260713_0009"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    with op.batch_alter_table("deployment_records") as batch_op:
        batch_op.add_column(
            sa.Column(
                "preview_path",
                sa.String(length=2048),
                server_default="/",
                nullable=False,
            )
        )


def downgrade() -> None:
    with op.batch_alter_table("deployment_records") as batch_op:
        batch_op.drop_column("preview_path")
