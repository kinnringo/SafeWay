"""保存ルート API

ルートの保存・一覧取得・削除と、保存ルート沿いの危険情報アラート取得を提供する。

通知フロー:
  1. POST /api/saved-routes  → 内部でルーティング実行し LineString を生成・保存
  2. POST /api/crime-reports → notifications.py が saved_routes と ST_DWithin で照合し
                                route_alerts テーブルへ書き込み
  3. GET  /api/saved-routes/alerts → フロントがポーリングして新着アラートを取得
"""
import json
import logging
from datetime import datetime
from typing import List, Optional

from fastapi import APIRouter, Depends, HTTPException, Query, status
from geoalchemy2 import functions as geofunc
from sqlalchemy import text
from sqlalchemy.orm import Session

from app.core.auth import get_current_user
from app.core.database import get_db
from app.models.db_models import CrimeReport, RouteAlert, SavedRoute, User
from app.models.schemas import RouteAlertResponse, SavedRouteCreate, SavedRouteResponse

logger = logging.getLogger(__name__)
router = APIRouter()

# ---------------------------------------------------------------------------
# 内部ルーティング用 SQL（route.py と同じロジックを再利用）
# ---------------------------------------------------------------------------

_NEAREST_NODE_SQL = text("""
    WITH nearby_edges AS (
        SELECT source_node, target_node, geom
        FROM road_edges
        ORDER BY geom <-> ST_SetSRID(ST_MakePoint(:lng, :lat), 4326)
        LIMIT 5
    ),
    candidate_nodes AS (
        SELECT source_node AS node_id, ST_StartPoint(geom) AS node_geom FROM nearby_edges
        UNION ALL
        SELECT target_node, ST_EndPoint(geom) FROM nearby_edges
    )
    SELECT node_id
    FROM candidate_nodes
    ORDER BY node_geom <-> ST_SetSRID(ST_MakePoint(:lng, :lat), 4326)
    LIMIT 1;
""")

# cost_column はホワイトリスト検証後に文字列フォーマットで埋め込む
_DIJKSTRA_SQL_TEMPLATE = """
    WITH path AS (
        SELECT seq, node, edge, cost, agg_cost
        FROM pgr_dijkstra(
            'SELECT id, source_node AS source, target_node AS target, {cost_column} AS cost FROM road_edges',
            :start_node,
            :end_node,
            false
        )
    )
    SELECT
        p.node,
        p.edge,
        ST_AsGeoJSON(r.geom) AS geom_json,
        r.source_node
    FROM path p
    LEFT JOIN road_edges r ON p.edge = r.id
    ORDER BY p.seq;
"""

_ALLOWED_COST_COLUMNS = {"routing_cost", "length"}


def _build_linestring_wkt(db: Session, start_lat: float, start_lng: float,
                           end_lat: float, end_lng: float, route_type: str) -> Optional[str]:
    """
    pgRouting でルートを計算し、全エッジ座標を連結した LINESTRING WKT を返す。
    ルーティングが失敗した場合は None を返す。
    """
    cost_column = "routing_cost" if route_type == "safe" else "length"
    if cost_column not in _ALLOWED_COST_COLUMNS:
        return None

    # 最近傍ノード取得
    start_row = db.execute(_NEAREST_NODE_SQL, {"lng": start_lng, "lat": start_lat}).fetchone()
    end_row = db.execute(_NEAREST_NODE_SQL, {"lng": end_lng, "lat": end_lat}).fetchone()

    if not start_row or not end_row:
        return None

    start_node = start_row.node_id
    end_node = end_row.node_id

    if start_node == end_node:
        return None

    sql = _DIJKSTRA_SQL_TEMPLATE.format(cost_column=cost_column)
    steps = db.execute(text(sql), {"start_node": start_node, "end_node": end_node}).all()

    if not steps or len(steps) <= 1:
        return None

    all_coords: list[list[float]] = []
    for step in steps:
        if step.edge == -1 or not step.geom_json:
            continue
        geom = json.loads(step.geom_json)
        coords = geom.get("coordinates", [])
        if not coords:
            continue

        # 進行方向の判定（route.py と同じロジック）
        is_reverse = (step.source_node != step.node)
        if is_reverse:
            coords = list(reversed(coords))

        if not all_coords:
            all_coords.extend(coords)
        elif coords:
            if all_coords[-1] == coords[0]:
                all_coords.extend(coords[1:])
            else:
                all_coords.extend(coords)

    if len(all_coords) < 2:
        return None

    point_strs = [f"{c[0]} {c[1]}" for c in all_coords]
    return f"LINESTRING({', '.join(point_strs)})"


# ---------------------------------------------------------------------------
# POST /api/saved-routes
# ---------------------------------------------------------------------------


@router.post(
    "/saved-routes",
    response_model=SavedRouteResponse,
    status_code=status.HTTP_201_CREATED,
    summary="ルートを保存する",
    description=(
        "出発地・目的地・ルート種別を受け取り、内部でルーティングを実行して "
        "LineString ジオメトリを生成・保存する。認証必須。"
    ),
)
def save_route(
    payload: SavedRouteCreate,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    # route_type バリデーション
    if payload.route_type not in {"safe", "shortest"}:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail="route_type は 'safe' または 'shortest' を指定してください。",
        )

    # 内部ルーティングで LineString を生成
    linestring_wkt = _build_linestring_wkt(
        db,
        payload.start_lat, payload.start_lng,
        payload.end_lat, payload.end_lng,
        payload.route_type,
    )

    # ルーティング失敗時は route_geom を null のまま保存（通知は機能しないが登録は許可）
    route_geom = None
    if linestring_wkt:
        route_geom = f"SRID=4326;{linestring_wkt}"
    else:
        logger.warning(
            "保存ルートのジオメトリ生成に失敗（ルーティング不可）: user_id=%d, start=(%.4f,%.4f), end=(%.4f,%.4f)",
            current_user.id, payload.start_lat, payload.start_lng, payload.end_lat, payload.end_lng,
        )

    saved = SavedRoute(
        user_id=current_user.id,
        start_lat=payload.start_lat,
        start_lng=payload.start_lng,
        end_lat=payload.end_lat,
        end_lng=payload.end_lng,
        route_type=payload.route_type,
        route_geom=route_geom,
        notification_radius_m=payload.notification_radius_m,
        name=payload.name,
        created_at=datetime.utcnow(),
    )
    db.add(saved)
    db.commit()
    db.refresh(saved)

    logger.info(
        "ルート保存: id=%d, user_id=%d, type=%s, radius=%.0fm, geom=%s",
        saved.id, current_user.id, payload.route_type,
        payload.notification_radius_m, "OK" if route_geom else "NONE",
    )
    return saved


# ---------------------------------------------------------------------------
# GET /api/saved-routes
# ---------------------------------------------------------------------------


@router.get(
    "/saved-routes",
    response_model=List[SavedRouteResponse],
    summary="保存ルート一覧を取得する",
    description="ログインユーザーが保存したルートの一覧を返す。認証必須。",
)
def list_saved_routes(
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    routes = (
        db.query(SavedRoute)
        .filter(SavedRoute.user_id == current_user.id)
        .order_by(SavedRoute.created_at.desc())
        .all()
    )
    return routes


# ---------------------------------------------------------------------------
# DELETE /api/saved-routes/{route_id}
# ---------------------------------------------------------------------------


@router.delete(
    "/saved-routes/{route_id}",
    status_code=status.HTTP_204_NO_CONTENT,
    summary="保存ルートを削除する",
    description="指定した保存ルートを削除する。関連するアラートも CASCADE で削除される。認証必須。",
)
def delete_saved_route(
    route_id: int,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    route = db.query(SavedRoute).filter(
        SavedRoute.id == route_id,
        SavedRoute.user_id == current_user.id,
    ).first()

    if not route:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="保存ルートが見つかりません。")

    db.delete(route)
    db.commit()
    logger.info("ルート削除: id=%d, user_id=%d", route_id, current_user.id)


# ---------------------------------------------------------------------------
# GET /api/saved-routes/alerts
# ---------------------------------------------------------------------------


@router.get(
    "/saved-routes/alerts",
    response_model=List[RouteAlertResponse],
    summary="保存ルート沿いの危険情報アラートを取得する（差分ポーリング対応）",
    description=(
        "ログインユーザーの保存ルート沿いで発生した危険情報アラートを返す。"
        "after_id を指定すると、そのIDより大きい新着アラートのみを古い順で返す。"
        "フロントは 3〜5 秒間隔でポーリングし、新着があれば即時アラートを表示する。"
    ),
)
def get_route_alerts(
    after_id: Optional[int] = Query(None, description="指定したIDより大きい新着アラートのみを取得"),
    limit: int = Query(20, ge=1, le=100),
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    query = db.query(RouteAlert).filter(RouteAlert.user_id == current_user.id)

    if after_id is not None:
        query = query.filter(RouteAlert.id > after_id).order_by(RouteAlert.id.asc())
    else:
        query = query.order_by(RouteAlert.id.desc())

    alerts = query.limit(limit).all()

    results: List[RouteAlertResponse] = []
    for alert in alerts:
        cr: CrimeReport = alert.crime_report
        point_wkt = db.execute(geofunc.ST_AsText(cr.geom)).scalar()
        coords = point_wkt.replace("POINT(", "").replace(")", "").split()
        lng = float(coords[0])
        lat = float(coords[1])

        results.append(RouteAlertResponse(
            id=alert.id,
            saved_route_id=alert.saved_route_id,
            crime_report_id=alert.crime_report_id,
            event_type=cr.event_type,
            description=cr.description,
            report_lat=lat,
            report_lng=lng,
            occurred_at=cr.occurred_at,
            created_at=alert.created_at,
        ))

    if after_id is None:
        results.reverse()

    return results
