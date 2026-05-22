"""Allow stale GitOps deployment request status.

Revision ID: 20260522_0004
Revises: 20260522_0003
Create Date: 2026-05-22 00:04:00
"""
from typing import Sequence, Union

from alembic import op


revision: str = "20260522_0004"
down_revision: Union[str, None] = "20260522_0003"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


OLD_STATUSES = "'pending', 'pending_manual_trigger', 'workflow_triggered', 'pr_opened', 'failed'"
NEW_STATUSES = f"{OLD_STATUSES}, 'stale'"


def upgrade() -> None:
    op.drop_constraint(
        "ck_gitops_deployment_requests_status",
        "gitops_deployment_requests",
        type_="check",
    )
    op.create_check_constraint(
        "ck_gitops_deployment_requests_status",
        "gitops_deployment_requests",
        f"status IN ({NEW_STATUSES})",
    )


def downgrade() -> None:
    op.execute("UPDATE gitops_deployment_requests SET status = 'failed' WHERE status = 'stale'")
    op.drop_constraint(
        "ck_gitops_deployment_requests_status",
        "gitops_deployment_requests",
        type_="check",
    )
    op.create_check_constraint(
        "ck_gitops_deployment_requests_status",
        "gitops_deployment_requests",
        f"status IN ({OLD_STATUSES})",
    )
