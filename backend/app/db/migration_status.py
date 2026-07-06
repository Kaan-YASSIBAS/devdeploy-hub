from pathlib import Path

from alembic.config import Config
from alembic.migration import MigrationContext
from alembic.script import ScriptDirectory
from sqlalchemy import create_engine
from sqlalchemy.exc import OperationalError
from sqlalchemy.pool import NullPool

from app.schemas.health import DatabaseMigrationStatusRead


DEFAULT_ALEMBIC_CONFIG = Path(__file__).resolve().parents[2] / "alembic.ini"


def create_alembic_config(config_path: Path | str = DEFAULT_ALEMBIC_CONFIG) -> Config:
    return Config(str(Path(config_path)))


def inspect_database_migration_status(
    database_url: str,
    *,
    config_path: Path | str = DEFAULT_ALEMBIC_CONFIG,
) -> DatabaseMigrationStatusRead:
    try:
        alembic_config = create_alembic_config(config_path)
        head_revisions = sorted(ScriptDirectory.from_config(alembic_config).get_heads())
    except Exception:
        return DatabaseMigrationStatusRead(
            status="error",
            message="Database migration metadata could not be inspected safely.",
        )

    try:
        engine = create_engine(database_url, poolclass=NullPool)
        with engine.connect() as connection:
            current_revisions = sorted(
                revision
                for revision in MigrationContext.configure(connection).get_current_heads()
                if revision
            )
    except (OperationalError, OSError, TimeoutError):
        return DatabaseMigrationStatusRead(
            status="unavailable",
            head_revisions=head_revisions,
            message="The database is unavailable for migration status inspection.",
        )
    except Exception:
        return DatabaseMigrationStatusRead(
            status="error",
            head_revisions=head_revisions,
            message="Database migration status could not be inspected safely.",
        )
    finally:
        if "engine" in locals():
            try:
                engine.dispose()
            except Exception:
                pass

    if set(current_revisions) == set(head_revisions) and head_revisions:
        return DatabaseMigrationStatusRead(
            status="up_to_date",
            current_revisions=current_revisions,
            head_revisions=head_revisions,
            message="Database migrations are up to date.",
        )
    return DatabaseMigrationStatusRead(
        status="pending",
        current_revisions=current_revisions,
        head_revisions=head_revisions,
        message="Database migrations are pending.",
    )


def get_database_migration_status() -> DatabaseMigrationStatusRead:
    from app.core.config import settings

    return inspect_database_migration_status(settings.database_url)
