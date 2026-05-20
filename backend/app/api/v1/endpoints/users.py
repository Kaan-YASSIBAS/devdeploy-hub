from fastapi import APIRouter, Depends
from sqlalchemy.orm import Session

from app.core.deps import get_current_user, get_db
from app.models.user import User
from app.schemas.user import UserSummary
from app.services.user_service import UserService


router = APIRouter(prefix="/users", tags=["users"])


@router.get("/me/summary", response_model=UserSummary)
def my_summary(
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
) -> UserSummary:
    return UserService(db).summary(current_user)
