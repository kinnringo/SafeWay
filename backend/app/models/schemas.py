"""Pydantic スキーマ定義

フロントエンドとバックエンド間の API 契約を定義する。
ここを変更する場合は、必ずフロント担当と合意してから行う。
"""

from pydantic import BaseModel, Field


# --- ルート検索 ---


class RouteRequest(BaseModel):
    """ルート検索リクエスト"""

    start_lat: float = Field(..., description="出発地の緯度")
    start_lng: float = Field(..., description="出発地の経度")
    end_lat: float = Field(..., description="目的地の緯度")
    end_lng: float = Field(..., description="目的地の経度")


class RouteResponse(BaseModel):
    """ルート検索レスポンス"""

    route: dict = Field(..., description="GeoJSON FeatureCollection 形式のルートデータ")
    distance_m: float = Field(..., description="ルートの総距離（メートル）")
    safety_score: float = Field(
        ..., ge=0.0, le=1.0, description="ルート全体の安全スコア（0.0〜1.0）"
    )


# --- 画像解析 ---


class Detection(BaseModel):
    """単一の検出結果"""

    label: str = Field(..., description="検出ラベル（streetlight, sidewalk 等）")
    confidence: float = Field(..., ge=0.0, le=1.0, description="信頼度")
    bbox: list[float] = Field(..., description="バウンディングボックス [x1, y1, x2, y2]")


class AnalyzeResponse(BaseModel):
    """画像解析レスポンス"""

    detections: list[dict] = Field(..., description="検出結果のリスト")
    lat: float = Field(..., description="撮影地点の緯度")
    lng: float = Field(..., description="撮影地点の経度")
    updated_score: float = Field(
        ..., ge=0.0, le=1.0, description="更新後の安全スコア"
    )
