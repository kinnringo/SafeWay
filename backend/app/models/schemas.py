"""Pydantic スキーマ定義

フロントエンドとバックエンド間の API 契約を定義する。
ここを変更する場合は、必ずフロント担当と合意してから行う。"""

from datetime import datetime
from typing import Optional
from pydantic import BaseModel, Field


# ---------------------------------------------------------------------------
# ルート検索
# ---------------------------------------------------------------------------


class RouteRequest(BaseModel):
    """ルート検索リクエスト"""

    start_lat: float = Field(..., description="出発地の緯度")
    start_lng: float = Field(..., description="出発地の経度")
    end_lat: float = Field(..., description="目的地の緯度")
    end_lng: float = Field(..., description="目的地の経度")


class RouteInfo(BaseModel):
    """個別ルート情報"""

    route: dict = Field(..., description="GeoJSON FeatureCollection 形式のルートデータ")
    distance_m: float = Field(..., description="ルートの総距離（メートル）")
    safety_score: float = Field(
        ..., ge=0.0, le=1.0, description="ルート全体の安全スコア（0.0〜1.0）"
    )


class RouteResponse(BaseModel):
    """ルート検索レスポンス（安全＋最短）"""

    safe_route: RouteInfo = Field(..., description="安全ルート情報")
    shortest_route: RouteInfo = Field(..., description="最短ルート情報")


# ---------------------------------------------------------------------------
# 画像解析
# ---------------------------------------------------------------------------


class DetectionResult(BaseModel):
    """1つの検出結果とその位置推定情報"""

    label: str = Field(..., description="検出ラベル（streetlight, obstacle 等）")
    confidence: float = Field(..., ge=0.0, le=1.0, description="YOLO の信頼度")
    bbox: list[float] = Field(..., description="バウンディングボックス [x1, y1, x2, y2]（画像ピクセル座標）")

    # 推定されたオブジェクトの実際の位置
    object_lat: float = Field(..., description="推定したオブジェクトの緯度")
    object_lng: float = Field(..., description="推定したオブジェクトの経度")

    # 距離推定の参考情報
    estimated_distance_m: Optional[float] = Field(
        None, description="カメラから物体までの推定水平距離（メートル）。position_accuracy が low の場合は null"
    )

    # 位置精度フラグ
    position_accuracy: str = Field(
        ...,
        description=(
            "位置推定の精度。"
            "'high': コンパス方位角と焦点距離から推定（精度良好）。"
            "'low': 情報不足のため撮影者位置を使用（精度低）。"
        ),
    )

    # 安全スコアへの影響
    score_modifier: float = Field(
        ..., description="このオブジェクトが安全スコアに与える影響（正=安全方向、負=危険方向）"
    )


class AnalyzeResponse(BaseModel):
    """画像解析レスポンス"""

    detections: list[DetectionResult] = Field(..., description="検出結果のリスト")
    user_lat: float = Field(..., description="撮影者の緯度")
    user_lng: float = Field(..., description="撮影者の経度")
    updated_score: float = Field(
        ..., ge=0.0, le=1.0, description="更新後の安全スコア（暫定計算値）"
    )


# ---------------------------------------------------------------------------
# ハザード情報（地図表示用）
# ---------------------------------------------------------------------------


class HazardPoint(BaseModel):
    """1件のハザードポイント（地図上に表示する危険/安全情報）"""

    id: int = Field(..., description="SafetyPoint の ID")
    lat: float = Field(..., description="緯度")
    lng: float = Field(..., description="経度")
    source_type: str = Field(..., description="情報源の種別（detection, crime_report 等）")
    score_modifier: float = Field(
        ..., description="安全スコアへの影響値（正=安全、負=危険）"
    )
    label: Optional[str] = Field(
        None, description="検出ラベル（streetlight 等）。source_type が detection の場合のみ"
    )
    confidence: Optional[float] = Field(
        None, description="YOLO の信頼度。source_type が detection の場合のみ"
    )
    updated_at: datetime = Field(..., description="最終更新日時")


class HazardsResponse(BaseModel):
    """ハザード情報一覧レスポンス"""

    points: list[HazardPoint] = Field(..., description="ハザードポイントのリスト")
    count: int = Field(..., description="返却されたポイント数")
