"""Pydantic スキーマ定義

フロントエンドとバックエンド間の API 契約を定義する。
ここを変更する場合は、必ずフロント担当と合意してから行う。"""

from datetime import datetime
from typing import Optional
from pydantic import BaseModel, Field


# ---------------------------------------------------------------------------
# 認証
# ---------------------------------------------------------------------------


class UserCreate(BaseModel):
    """ユーザー登録リクエスト"""

    username: str = Field(..., min_length=3, max_length=50, description="ユーザー名（3〜50文字）")
    password: str = Field(..., min_length=6, description="パスワード（6文字以上）")


class UserResponse(BaseModel):
    """ユーザー情報レスポンス"""

    id: int = Field(..., description="ユーザー ID")
    username: str = Field(..., description="ユーザー名")
    coins: int = Field(..., description="保有コイン数")
    created_at: datetime = Field(..., description="登録日時")

    model_config = {"from_attributes": True}


class TokenResponse(BaseModel):
    """ログイン成功時のレスポンス"""

    access_token: str = Field(..., description="JWT アクセストークン")
    token_type: str = Field("bearer", description="トークン種別")


# ---------------------------------------------------------------------------
# ルート検索
# ---------------------------------------------------------------------------


class RouteRequest(BaseModel):
    """ルート検索リクエスト"""

    start_lat: float = Field(..., ge=-90.0, le=90.0, description="出発地の緯度")
    start_lng: float = Field(..., ge=-180.0, le=180.0, description="出発地の経度")
    end_lat: float = Field(..., ge=-90.0, le=90.0, description="目的地の緯度")
    end_lng: float = Field(..., ge=-180.0, le=180.0, description="目的地の経度")
    hazard_radius_m: Optional[float] = Field(
        1000.0, ge=0.0, description="ルート周辺の危険情報を取得する範囲（メートル）。デフォルトは1km（1000m）。"
    )


class RouteInfo(BaseModel):
    """個別ルート情報"""

    route: dict = Field(..., description="GeoJSON FeatureCollection 形式のルートデータ")
    distance_m: float = Field(..., description="ルートの総距離（メートル）")
    safety_score: float = Field(
        ..., ge=0.0, le=1.0, description="ルート全体の安全スコア（0.0〜1.0）"
    )


class RouteResponse(BaseModel):
    """ルート検索レスポンス（安全＋最短＋沿道ハザード）"""

    safe_route: RouteInfo = Field(..., description="安全ルート情報")
    shortest_route: RouteInfo = Field(..., description="最短ルート情報")
    nearby_hazards: list["HazardPoint"] = Field(
        default_factory=list,
        description="ルート周辺の危険情報（検索範囲はリクエストの hazard_radius_m で指定）"
    )


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
    earned_coins: int = Field(0, description="この投稿で獲得したコイン数")


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
    event_type: Optional[str] = Field(
        None, description="イベント種別（bear 等）。source_type が crime_report の場合のみ"
    )
    description: Optional[str] = Field(
        None, description="詳細情報や補足テキスト。source_type が crime_report の場合等"
    )
    updated_at: datetime = Field(..., description="最終更新日時")


class HazardsResponse(BaseModel):
    """ハザード情報一覧レスポンス"""

    points: list[HazardPoint] = Field(..., description="ハザードポイントのリスト")
    count: int = Field(..., description="返却されたポイント数")


# ---------------------------------------------------------------------------
# カバレッジ情報（情報空白地帯可視化用）
# ---------------------------------------------------------------------------


class CoverageCellResponse(BaseModel):
    """1つのグリッドセルの情報密度"""

    lat: float = Field(..., description="セル南端の緯度")
    lng: float = Field(..., description="セル西端の経度")
    count: int = Field(..., description="セル内の SafetyPoint 数")


class CoverageResponse(BaseModel):
    """カバレッジ情報レスポンス"""

    cells: list[CoverageCellResponse] = Field(..., description="データが存在するセルのリスト")
    cell_size: float = Field(..., description="セルサイズ（度）")
    total_cells: int = Field(..., description="返却されたセル数")


# ---------------------------------------------------------------------------
# 通知機能
# ---------------------------------------------------------------------------


class DeviceTokenRegister(BaseModel):
    """FCMデバイストークンの登録リクエスト"""

    fcm_token: str = Field(..., description="Firebase から発行されるデバイストークン")
    notification_radius_m: float = Field(
        5000.0, ge=100.0, le=100000.0,
        description="通知を受け取る範囲（メートル）。デフォルト5000m(5km)。100m〜100km"
    )


class DeviceTokenResponse(BaseModel):
    """FCMデバイストークン登録レスポンス"""

    status: str = Field(..., description="登録結果。'registered' または 'updated'")
    notification_radius_m: float = Field(..., description="設定された通知範囲（メートル）")


class CrimeReportCreate(BaseModel):
    """危険情報登録リクエスト"""

    event_type: str = Field(
        ...,
        description="危険種別。例: 'bear'（クマ）, 'suspicious_person'（不審者）, 'traffic'（交通事故）, 'disaster'（災害）"
    )
    description: Optional[str] = Field(None, description="詳細な説明文")
    lat: float = Field(..., ge=-90.0, le=90.0, description="発生場所の緯度")
    lng: float = Field(..., ge=-180.0, le=180.0, description="発生場所の経度")
    occurred_at: Optional[datetime] = Field(None, description="発生日時。省略時はサーバー到達時点のシステム時間を自動設定")


class CrimeReportResponse(BaseModel):
    """危険情報登録レスポンス"""

    id: int = Field(..., description="登録された crime_report の ID")
    event_type: str = Field(..., description="危険種別")
    lat: float = Field(..., description="発生場所の緯度")
    lng: float = Field(..., description="発生場所の経度")
    occurred_at: datetime = Field(..., description="発生日時")
    notified_users: int = Field(..., description="通知を送信したデバイス数")


class CrimeReportDetail(BaseModel):
    """危険情報詳細レスポンス（GETポーリング用）"""

    id: int = Field(..., description="crime_report の ID")
    event_type: str = Field(..., description="危険種別（'bear', 'suspicious_person'など）")
    description: Optional[str] = Field(None, description="詳細な説明文")
    lat: float = Field(..., description="発生場所の緯度")
    lng: float = Field(..., description="発生場所の経度")
    occurred_at: datetime = Field(..., description="発生日時")
    created_at: datetime = Field(..., description="データ登録日時")


class DebugDetectionCreate(BaseModel):
    """デモ・デバッグ専用の検出情報登録リクエスト"""

    label: str = Field(..., description="検出物体のラベル。例: 'streetlight' (街灯), 'sidewalk' (歩道)")
    lat: float = Field(..., ge=-90.0, le=90.0, description="指定座標の緯度")
    lng: float = Field(..., ge=-180.0, le=180.0, description="指定座標の経度")
    confidence: Optional[float] = Field(0.99, description="信頼度")


class DebugDetectionResponse(BaseModel):
    """デモ・デバッグ専用の検出情報レスポンス"""

    id: int
    label: str
    lat: float
    lng: float
    score_modifier: float
    created_at: datetime


# ---------------------------------------------------------------------------
# 保存ルート
# ---------------------------------------------------------------------------


class SavedRouteCreate(BaseModel):
    """ルート保存リクエスト"""

    start_lat: float = Field(..., ge=-90.0, le=90.0, description="出発地の緯度")
    start_lng: float = Field(..., ge=-180.0, le=180.0, description="出発地の経度")
    end_lat: float = Field(..., ge=-90.0, le=90.0, description="目的地の緯度")
    end_lng: float = Field(..., ge=-180.0, le=180.0, description="目的地の経度")
    route_type: str = Field("safe", description="保存するルート種別: 'safe' または 'shortest'")
    notification_radius_m: float = Field(
        500.0, ge=50.0, le=5000.0,
        description="このルート沿いで危険情報を検知する半径（メートル）。デフォルト 500m。"
    )
    name: Optional[str] = Field(None, max_length=100, description="ルートの任意名称（省略可）")


class SavedRouteResponse(BaseModel):
    """保存ルートのレスポンス"""

    id: int = Field(..., description="保存ルートID")
    user_id: int = Field(..., description="オーナーのユーザーID")
    start_lat: float
    start_lng: float
    end_lat: float
    end_lng: float
    route_type: str = Field(..., description="ルート種別: 'safe' または 'shortest'")
    notification_radius_m: float
    name: Optional[str] = None
    created_at: datetime

    model_config = {"from_attributes": True}


# ---------------------------------------------------------------------------
# 保存ルートアラート
# ---------------------------------------------------------------------------


class RouteAlertResponse(BaseModel):
    """保存ルート沿いの危険情報アラートレスポンス"""

    id: int = Field(..., description="アラートレコードID（after_id ポーリング用）")
    saved_route_id: int = Field(..., description="対象の保存ルートID")
    crime_report_id: int = Field(..., description="トリガーとなった危険情報ID")

    # 危険情報の詳細
    event_type: str = Field(..., description="危険情報の種別（bear, suspicious_person 等）")
    description: Optional[str] = Field(None, description="危険情報の詳細テキスト")
    report_lat: float = Field(..., description="危険情報の発生緯度")
    report_lng: float = Field(..., description="危険情報の発生経度")
    occurred_at: datetime = Field(..., description="危険情報の発生日時")

    created_at: datetime = Field(..., description="アラートの生成日時")

    model_config = {"from_attributes": True}
