"""Allow destroyed deployment record state.

Revision ID: 20260706_0008
Revises: 20260705_0007
Create Date: 2026-07-06 00:08:00
"""
from typing import Sequence, Union

from alembic import op


revision: str = "20260706_0008"
down_revision: Union[str, None] = "20260705_0007"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    with op.batch_alter_table("deployment_records") as batch_op:
        batch_op.drop_constraint(
            "ck_deployment_records_desired_state",
            type_="check",
        )
        batch_op.create_check_constraint(
            "ck_deployment_records_desired_state",
            "desired_state IN ('draft', 'pending', 'destroyed')",
        )


def downgrade() -> None:
    with op.batch_alter_table("deployment_records") as batch_op:
        batch_op.drop_constraint(
            "ck_deployment_records_desired_state",
            type_="check",
        )
        batch_op.create_check_constraint(
            "ck_deployment_records_desired_state",
            "desired_state IN ('draft', 'pending')",
        )
