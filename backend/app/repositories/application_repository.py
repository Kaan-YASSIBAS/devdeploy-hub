from sqlalchemy import func
from sqlalchemy.orm import Session

from app.models.application import Application


class ApplicationRepository:
    def __init__(self, db: Session):
        self.db = db

    def count(self, *, owner_id: int | None = None) -> int:
        query = self.db.query(func.count(Application.id))
        if owner_id is not None:
            query = query.filter(Application.owner_id == owner_id)
        return query.scalar() or 0

    def get_by_id(self, application_id: int) -> Application | None:
        return self.db.query(Application).filter(Application.id == application_id).first()

    def get_by_slug(self, slug: str) -> Application | None:
        return self.db.query(Application).filter(Application.slug == slug).first()

    def list_all(self) -> list[Application]:
        return self.db.query(Application).order_by(Application.created_at.desc()).all()

    def list_for_owner(self, owner_id: int) -> list[Application]:
        return (
            self.db.query(Application)
            .filter(Application.owner_id == owner_id)
            .order_by(Application.created_at.desc())
            .all()
        )

    def create(self, *, owner_id: int, data: dict) -> Application:
        application = Application(owner_id=owner_id, **data)
        self.db.add(application)
        self.db.flush()
        return application

    def update(self, application: Application, data: dict) -> Application:
        for key, value in data.items():
            setattr(application, key, value)
        self.db.flush()
        return application

    def delete(self, application: Application) -> None:
        self.db.delete(application)
        self.db.flush()
