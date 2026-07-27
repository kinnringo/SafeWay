"""通知機能API

FCMデバイストークンの登録と、危険情報の登録→FCM通知送信を行うエンドポイント。
"""
import logging
from datetime import datetime
from typing import Optional, List

from fastapi import APIRouter, Depends, HTTPException, status, Query
from geoalchemy2 import functions as geofunc
from sqlalchemy import text
from sqlalchemy.orm import Session

from app.core.database import get_db
from app.core.auth import get_current_user
from app.core.score_config import (
    SCORE_MODIFIERS,
    DEFAULT_SCORE_MODIFIER,
    INFLUENCE_RADIUS_M,
    HAZARD_SCORE_MODIFIERS,
    HAZARD_INFLUENCE_RADIUS_M,
)
from app.models.db_models import User, DeviceToken, CrimeReport, SafetyPoint, SavedRoute, RouteAlert
from app.models.schemas import (
    DeviceTokenRegister,
    DeviceTokenResponse,
    CrimeReportCreate,
    CrimeReportResponse,
    CrimeReportDetail,
)
from app.services.fcm import send_crime_report_notifications
from app.services.scoring import update_edge_scores_near_point


logger = logging.getLogger(__name__)
router = APIRouter()


# ---------------------------------------------------------------------------
# POST /api/notifications/register
# ---------------------------------------------------------------------------


@router.post(
    "/notifications/register",
    response_model=DeviceTokenResponse,
    summary="FCMデバイストークンの登録・更新",
    description=(
        "アプリ起動時に呼び出し、Firebase Cloud Messaging のデバイストークンをサーバーに登録します。"
        "同一ユーザーのトークンが既に存在する場合は更新します（アプリ再インストール等のトークン変更に対応）。"
        "認証必須（Bearer JWTトークン）。"
    ),
)
def register_device_token(
    payload: DeviceTokenRegister,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    """FCMトークンを登録 or 更新する。"""
    existing = db.query(DeviceToken).filter(DeviceToken.user_id == current_user.id).first()

    if existing:
        # 既存レコードを更新
        existing.fcm_token = payload.fcm_token
        existing.notification_radius_m = payload.notification_radius_m
        existing.updated_at = datetime.utcnow()
        db.commit()
        logger.info("FCMトークン更新: user_id=%d, radius=%.0fm", current_user.id, payload.notification_radius_m)
        return DeviceTokenResponse(status="updated", notification_radius_m=payload.notification_radius_m)
    else:
        # 新規登録
        device_token = DeviceToken(
            user_id=current_user.id,
            fcm_token=payload.fcm_token,
            notification_radius_m=payload.notification_radius_m,
            updated_at=datetime.utcnow(),
        )
        db.add(device_token)
        db.commit()
        logger.info("FCMトークン登録: user_id=%d, radius=%.0fm", current_user.id, payload.notification_radius_m)
        return DeviceTokenResponse(status="registered", notification_radius_m=payload.notification_radius_m)


# ---------------------------------------------------------------------------
# POST /api/crime-reports
# ---------------------------------------------------------------------------


@router.post(
    "/crime-reports",
    response_model=CrimeReportResponse,
    status_code=status.HTTP_201_CREATED,
    summary="危険情報の登録と近隣ユーザーへの通知",
    description=(
        "クマ出没・不審者等の危険情報を登録し、FCMトークンを登録している全ユーザーに"
        "プッシュ通知を送信します。認証不要（発表デモや外部トリガーからも利用可能）。"
    ),
)
def create_crime_report(
    payload: CrimeReportCreate,
    db: Session = Depends(get_db),
):
    """
    危険情報を crime_reports + safety_points に登録し、
    FCMデバイストークンを登録している全ユーザーに通知を送る。
    """
    # --- 1. crime_reports テーブルに保存 ---
    obj_geom = f"SRID=4326;POINT({payload.lng} {payload.lat})"

    occurred_time = payload.occurred_at or datetime.utcnow()

    crime_report = CrimeReport(
        event_type=payload.event_type,
        description=payload.description,
        geom=obj_geom,
        occurred_at=occurred_time,
        created_at=datetime.utcnow(),
    )
    db.add(crime_report)
    db.flush()  # IDを確定させる

    # --- 2. safety_points テーブルにも紐付けて登録（ハザードマップに即反映） ---
    event_type_lower = payload.event_type.lower()
    score_modifier = HAZARD_SCORE_MODIFIERS.get(event_type_lower, -0.50)
    influence_radius = HAZARD_INFLUENCE_RADIUS_M.get(event_type_lower, 500.0)

    safety_point = SafetyPoint(
        source_type="crime_report",
        crime_report_id=crime_report.id,
        score_modifier=score_modifier,
        influence_radius_m=influence_radius,
        is_road_attribute=False,
        geom=obj_geom,
        is_visible=True,
        updated_at=datetime.utcnow(),
    )
    db.add(safety_point)
    db.commit()

    # 近隣の道路網スコアを広域影響半径で即・再計算
    try:
        update_edge_scores_near_point(db, payload.lng, payload.lat, influence_radius)
        db.commit()
    except Exception as e:
        logger.warning("犯罪・ハザード通報直後のエッジスコア再計算スキップ: %s", e)
        db.rollback()

    logger.info(
        "crime_report 登録完了: id=%d, event_type=%s, mod=%.2f, rad=%.1f, lat=%.4f, lng=%.4f",
        crime_report.id, payload.event_type, score_modifier, influence_radius, payload.lat, payload.lng,
    )

    # --- 3. FCM通知の送信（DBコミット後に実行。通知失敗でもDBは巻き戻さない） ---
    notified = 0
    try:
        notified = send_crime_report_notifications(
            db=db,
            report_lat=payload.lat,
            report_lng=payload.lng,
            event_type=payload.event_type,
            description=payload.description,
            report_id=crime_report.id,
        )
    except Exception as e:
        # FCM送信エラーは通知のみ。DBへの登録は成功しているため 500 にはしない。
        logger.error("FCM通知送信中に予期しないエラー: %s", e)

    # --- 4. 保存ルート沿道照合 → route_alerts 生成 ---
    try:
        _create_route_alerts(db, crime_report.id, payload.lat, payload.lng)
    except Exception as e:
        logger.error("route_alerts 生成中にエラー（登録自体は成功）: %s", e)

    return CrimeReportResponse(
        id=crime_report.id,
        event_type=crime_report.event_type,
        lat=payload.lat,
        lng=payload.lng,
        occurred_at=crime_report.occurred_at,
        notified_users=notified,
    )



# ---------------------------------------------------------------------------
# 保存ルート沿道照合・route_alerts 生成（内部処理）
# ---------------------------------------------------------------------------

_ROUTE_ALERT_CHECK_SQL = text("""
    SELECT id, user_id, notification_radius_m
    FROM saved_routes
    WHERE route_geom IS NOT NULL
      AND ST_DWithin(
          ST_Transform(route_geom, 3857),
          ST_Transform(ST_SetSRID(ST_MakePoint(:lng, :lat), 4326), 3857),
          notification_radius_m
      )
""")


def _create_route_alerts(db: Session, crime_report_id: int, lat: float, lng: float) -> int:
    """
    登録された危険情報の座標が、保存ルートの notification_radius_m 以内にある場合に
    route_alerts レコードを生成する。
    重複登録防止のため、同一 (saved_route_id, crime_report_id) の組は挿入しない。

    Returns:
        生成したアラート件数
    """
    rows = db.execute(_ROUTE_ALERT_CHECK_SQL, {"lng": lng, "lat": lat}).all()
    if not rows:
        return 0

    count = 0
    for row in rows:
        # 重複チェック
        exists = db.query(RouteAlert).filter(
            RouteAlert.saved_route_id == row.id,
            RouteAlert.crime_report_id == crime_report_id,
        ).first()
        if exists:
            continue

        alert = RouteAlert(
            user_id=row.user_id,
            saved_route_id=row.id,
            crime_report_id=crime_report_id,
            created_at=datetime.utcnow(),
        )
        db.add(alert)
        count += 1

    if count > 0:
        db.commit()
        logger.info(
            "route_alerts 生成: crime_report_id=%d, 対象ルート数=%d",
            crime_report_id, count,
        )

    return count



# ---------------------------------------------------------------------------
# GET /api/crime-reports
# ---------------------------------------------------------------------------


@router.get(
    "/crime-reports",
    response_model=List[CrimeReportDetail],
    summary="危険情報の一覧取得（差分ポーリング・新着検知対応）",
    description=(
        "登録済みの危険情報（クマ出没等）の一覧を取得します。"
        "after_id を指定すると、そのIDより大きい（＝新しく投稿された）差分データのみを昇順で返却するため、"
        "デモ等でのリアルタイムアラート代用のポーリング監視機能として即時に活躍します。"
    ),
)
def get_crime_reports(
    after_id: Optional[int] = Query(None, description="指定したIDより大きい最新レコードのみを取得"),
    limit: int = Query(20, ge=1, le=100, description="最大取得件数"),
    db: Session = Depends(get_db),
):
    """危険情報を返す。after_id 指定があれば差分取得する。"""
    query = db.query(CrimeReport)

    if after_id is not None:
        query = query.filter(CrimeReport.id > after_id).order_by(CrimeReport.id.asc())
    else:
        query = query.order_by(CrimeReport.id.desc())

    reports = query.limit(limit).all()

    results: List[CrimeReportDetail] = []
    for cr in reports:
        point_wkt = db.execute(geofunc.ST_AsText(cr.geom)).scalar()
        coords = point_wkt.replace("POINT(", "").replace(")", "").split()
        lng = float(coords[0])
        lat = float(coords[1])

        results.append(
            CrimeReportDetail(
                id=cr.id,
                event_type=cr.event_type,
                description=cr.description,
                lat=lat,
                lng=lng,
                occurred_at=cr.occurred_at,
                created_at=cr.created_at,
            )
        )

    if after_id is None:
        results.reverse()

    return results
