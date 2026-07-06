import logging
import os

from alembic import command
from dotenv import load_dotenv

from app.db.migration_status import (
    create_alembic_config,
    inspect_database_migration_status,
)


LOGGER = logging.getLogger("devdeploy.database_migrations")


def run_migrations() -> int:
    load_dotenv()
    database_url = os.getenv("DATABASE_URL")
    if not database_url:
        LOGGER.error("Database migration failed because DATABASE_URL is not configured.")
        return 1

    LOGGER.info("Starting database migration.")
    before = inspect_database_migration_status(database_url)
    LOGGER.info(
        "Migration state before upgrade: %s; current revision(s): %s; target revision(s): %s.",
        before.status,
        ", ".join(before.current_revisions) or "none",
        ", ".join(before.head_revisions) or "unknown",
    )
    try:
        command.upgrade(create_alembic_config(), "head")
    except Exception:
        LOGGER.error("Database migration failed. Review the sanitized migration logs.")
        return 1

    after = inspect_database_migration_status(database_url)
    if after.status != "up_to_date":
        LOGGER.error("Database migration completed without a verifiable up-to-date revision.")
        return 1
    LOGGER.info(
        "Database migration completed successfully at revision(s): %s.",
        ", ".join(after.current_revisions),
    )
    return 0


def main() -> None:
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")
    raise SystemExit(run_migrations())


if __name__ == "__main__":
    main()
