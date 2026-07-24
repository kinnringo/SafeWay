from datetime import datetime, timedelta, timezone
from typing import Optional

from fastapi import Depends, HTTPException, status
from fastapi.security import OAuth2PasswordBearer
from jose import JWTError, jwt
from passlib.context import CryptContext
from sqlalchemy.orm import Session

from app.core.config import settings
from app.core.database import get_db
from app.models.db_models import User

_pwd_context = CryptContext(schemes=["bcrypt"], deprecated="auto")


def hash_password(plain: str) -> str:
    """平文パスワードを bcrypt でハッシュ化して返す。"""
    return _pwd_context.hash(plain)


def verify_password(plain: str, hashed: str) -> bool:
    """平文パスワードとハッシュを照合する。"""
    return _pwd_context.verify(plain, hashed)


_oauth2_scheme = OAuth2PasswordBearer(tokenUrl="/api/auth/login")


def create_access_token(data: dict, expires_delta=None) -> str:
    """JWT アクセストークンを生成して返す。"""
    payload = data.copy()
    expire = datetime.now(timezone.utc) + (
        expires_delta if expires_delta else timedelta(minutes=settings.JWT_EXPIRE_MINUTES)
    )
    payload.update({"exp": expire})
    return jwt.encode(payload, settings.JWT_SECRET_KEY, algorithm=settings.JWT_ALGORITHM)


def _decode_token(token: str) -> dict:
    """JWT をデコードしてペイロードを返す。失敗時は HTTPException(401) を送出。"""
    exc = HTTPException(
        status_code=status.HTTP_401_UNAUTHORIZED,
        detail="Invalid credentials",
        headers={"WWW-Authenticate": "Bearer"},
    )
    try:
        return jwt.decode(token, settings.JWT_SECRET_KEY, algorithms=[settings.JWT_ALGORITHM])
    except JWTError:
        raise exc


def get_current_user(
    token: str = Depends(_oauth2_scheme),
    db: Session = Depends(get_db),
) -> User:
    """認証済みユーザーを返す FastAPI 依存関数。"""
    payload = _decode_token(token)
    username: Optional[str] = payload.get("sub")
    if username is None:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid credentials",
            headers={"WWW-Authenticate": "Bearer"},
        )
    user = db.query(User).filter(User.username == username).first()
    if user is None:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="User not found",
            headers={"WWW-Authenticate": "Bearer"},
        )
    return user


_oauth2_scheme_optional = OAuth2PasswordBearer(tokenUrl="/api/auth/login", auto_error=False)


def get_current_user_optional(
    token: Optional[str] = Depends(_oauth2_scheme_optional),
    db: Session = Depends(get_db),
) -> Optional[User]:
    """トークンがあれば認証済みユーザーを返し、なければ None を返す。"""
    if not token:
        return None
    try:
        payload = jwt.decode(token, settings.JWT_SECRET_KEY, algorithms=[settings.JWT_ALGORITHM])
        username: Optional[str] = payload.get("sub")
        if not username:
            return None
        return db.query(User).filter(User.username == username).first()
    except JWTError:
        return None
