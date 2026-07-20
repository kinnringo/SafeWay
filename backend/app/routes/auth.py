"""認証エンドポイント

POST /api/auth/register  - ユーザー登録
POST /api/auth/login     - ログイン（JWT 返却）
GET  /api/auth/me        - 現在のユーザー情報取得（認証必須）
"""

import logging
from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy.orm import Session

from app.core.auth import create_access_token, get_current_user, hash_password, verify_password
from app.core.database import get_db
from app.models.db_models import User
from app.models.schemas import TokenResponse, UserCreate, UserResponse

logger = logging.getLogger(__name__)
router = APIRouter()


@router.post(
    "/auth/register",
    response_model=UserResponse,
    status_code=status.HTTP_201_CREATED,
    summary="ユーザー登録",
)
def register(body: UserCreate, db: Session = Depends(get_db)) -> UserResponse:
    """新規ユーザーを登録する。

    - ユーザー名はシステム全体で一意。
    - パスワードは bcrypt でハッシュ化して保存する。
    """
    if db.query(User).filter(User.username == body.username).first():
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail="ユーザー名はすでに使用されています",
        )

    user = User(
        username=body.username,
        password_hash=hash_password(body.password),
        coins=0,
    )
    db.add(user)
    db.commit()
    db.refresh(user)
    logger.info("新規ユーザー登録: %s (id=%d)", user.username, user.id)
    return user


@router.post(
    "/auth/login",
    response_model=TokenResponse,
    summary="ログイン（JWT 取得）",
)
def login(body: UserCreate, db: Session = Depends(get_db)) -> TokenResponse:
    """ユーザー名・パスワードを検証し、JWT アクセストークンを返す。"""
    user = db.query(User).filter(User.username == body.username).first()
    if user is None or not verify_password(body.password, user.password_hash):
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="ユーザー名またはパスワードが正しくありません",
            headers={"WWW-Authenticate": "Bearer"},
        )

    token = create_access_token({"sub": user.username})
    logger.info("ログイン成功: %s (id=%d)", user.username, user.id)
    return TokenResponse(access_token=token, token_type="bearer")


@router.get(
    "/auth/me",
    response_model=UserResponse,
    summary="現在のユーザー情報取得",
)
def me(current_user: User = Depends(get_current_user)) -> UserResponse:
    """Authorization ヘッダーの JWT を検証し、ログイン中のユーザー情報を返す。"""
    return current_user
