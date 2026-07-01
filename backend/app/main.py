"""SafeWay Backend - FastAPI エントリーポイント"""

from contextlib import asynccontextmanager
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from sqlalchemy import text

from app.core.database import engine, Base
from app.routes import route, analyze, hazards

def init_db():
    try:
        with engine.begin() as conn:
            # PostGIS 拡張をロード
            conn.execute(text("CREATE EXTENSION IF NOT EXISTS postgis;"))
        
        # モデルをロードして Base.metadata に登録する
        from app.models import db_models
        
        # テーブルを作成
        Base.metadata.create_all(bind=engine)
        print("Database initialized successfully.")
    except Exception as e:
        print(f"Error initializing database: {e}")

@asynccontextmanager
async def lifespan(app: FastAPI):
    # 起動時の処理
    init_db()
    yield

app = FastAPI(
    title="SafeWay API",
    description="安全ナビゲーションアプリのバックエンドAPI",
    version="0.1.0",
    lifespan=lifespan,
)

# Flutter アプリからのリクエストを許可
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],  # 開発中は全許可、本番では制限する
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

app.include_router(route.router, prefix="/api", tags=["routing"])
app.include_router(analyze.router, prefix="/api", tags=["analyze"])
app.include_router(hazards.router, prefix="/api", tags=["hazards"])


@app.get("/health")
def health_check():
    """ヘルスチェック用エンドポイント"""
    return {"status": "ok"}
