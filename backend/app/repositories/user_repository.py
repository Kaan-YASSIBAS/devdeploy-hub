from sqlalchemy import func
from sqlalchemy.orm import Session

from app.models.user import User


class UserRepository:
    def __init__(self, db: Session):
        self.db = db

    def count(self) -> int:
        return self.db.query(func.count(User.id)).scalar() or 0

    def get_by_id(self, user_id: int) -> User | None:
        return self.db.query(User).filter(User.id == user_id).first()

    def get_by_email(self, email: str) -> User | None:
        return self.db.query(User).filter(User.email == email).first()

    def get_by_username(self, username: str) -> User | None:
        return self.db.query(User).filter(User.username == username).first()

    def create(self, *, email: str, username: str, hashed_password: str, role: str = "developer") -> User:
        user = User(email=email, username=username, hashed_password=hashed_password, role=role)
        self.db.add(user)
        self.db.flush()
        return user
