"""SafeWay Backend - FastAPI エントリーポイント"""

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from app.routes import route, analyze

app = FastAPI(
    title="SafeWay API",
    description="安全ナビゲーションアプリのバックエンドAPI",
    version="0.1.0",
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


@app.get("/health")
def health_check():
    """ヘルスチェック用エンドポイント"""
    return {"status": "ok"}
