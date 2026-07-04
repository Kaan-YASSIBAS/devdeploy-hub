from sqlalchemy.orm import Session

from app.models.service_definition import ServiceDefinition


class ServiceDefinitionRepository:
    def __init__(self, db: Session):
        self.db = db

    def get_by_id(self, service_id: int) -> ServiceDefinition | None:
        return self.db.query(ServiceDefinition).filter(ServiceDefinition.id == service_id).first()

    def get_by_owner_and_name(self, owner_id: int, name: str) -> ServiceDefinition | None:
        return (
            self.db.query(ServiceDefinition)
            .filter(ServiceDefinition.owner_id == owner_id, ServiceDefinition.name == name)
            .first()
        )

    def list_all(self) -> list[ServiceDefinition]:
        return self.db.query(ServiceDefinition).order_by(ServiceDefinition.created_at.desc()).all()

    def list_for_owner(self, owner_id: int) -> list[ServiceDefinition]:
        return (
            self.db.query(ServiceDefinition)
            .filter(ServiceDefinition.owner_id == owner_id)
            .order_by(ServiceDefinition.created_at.desc())
            .all()
        )

    def create(self, *, owner_id: int, data: dict) -> ServiceDefinition:
        service = ServiceDefinition(owner_id=owner_id, **data)
        self.db.add(service)
        self.db.flush()
        return service

    def update(self, service: ServiceDefinition, data: dict) -> ServiceDefinition:
        for key, value in data.items():
            setattr(service, key, value)
        self.db.flush()
        return service
