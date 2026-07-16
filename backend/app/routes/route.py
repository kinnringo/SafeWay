"""ルート検索API"""

import json
import logging
from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy import text
from sqlalchemy.exc import OperationalError, ProgrammingError
from sqlalchemy.orm import Session

from app.core.database import get_db
from app.models.schemas import RouteRequest, RouteResponse, RouteInfo, HazardPoint
from app.services.roads_snap import snap_route_to_roads
from app.services.directions import get_shortest_route as _directions_shortest_route

logger = logging.getLogger(__name__)
router = APIRouter()

# ---------------------------------------------------------------------------
# SQL定義
# ---------------------------------------------------------------------------

# 近隣5本のエッジから最大10個の候補ノードを抽出し、
# その中で本当に最も近いノードを選ぶ。
# LIMIT 1 だけだと、最近接エッジの端点が最近接ノードとは限らないため、
# 候補を広げて精度を確保する。
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

# pgRouting Dijkstra 経路探索クエリのテンプレート
# {cost_column} はホワイトリスト検証済みの値のみが入る（_ALLOWED_COST_COLUMNS）
_DIJKSTRA_PATH_SQL_TEMPLATE = """
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
        p.seq, 
        p.node, 
        p.edge, 
        p.cost, 
        p.agg_cost, 
        r.source_node, 
        r.target_node, 
        r.length, 
        r.safety_score, 
        ST_AsGeoJSON(r.geom) AS geom_json
    FROM path p
    LEFT JOIN road_edges r ON p.edge = r.id
    ORDER BY p.seq;
"""

# ルート沿いのエリア型ハザード（犯罪・野生動物等）を検索するクエリ
# detection（街灯・信号機等）は含めない（エッジの safety_score に既に反映済み）
_NEARBY_HAZARDS_SQL = text("""
    SELECT
        sp.id,
        ST_Y(sp.geom) AS lat,
        ST_X(sp.geom) AS lng,
        sp.source_type,
        sp.score_modifier,
        sp.updated_at,
        d.label,
        d.confidence
    FROM safety_points sp
    LEFT JOIN detections d ON sp.detection_id = d.id
    WHERE sp.is_visible = TRUE
      AND sp.source_type != 'detection'
      AND ST_DWithin(
          ST_Transform(sp.geom, 3857),
          ST_Transform(ST_GeomFromText(:route_wkt, 4326), 3857),
          :radius_m
      )
    ORDER BY sp.updated_at DESC;
""")

# SQLインジェクション防止: cost_column に許可される値のホワイトリスト
_ALLOWED_COST_COLUMNS = {"routing_cost", "length"}

# 沿道ハザード検索のデフォルト半径（メートル） - 現在は引数で動的に渡されるため定数としては使用しないが、コメントとして残す
# _HAZARD_SEARCH_RADIUS_M = 100.0

# ---------------------------------------------------------------------------
# 内部ロジック
# ---------------------------------------------------------------------------


def _query_route_info(db: Session, start_node: int, end_node: int, cost_column: str) -> RouteInfo:
    """
    pgRoutingを実行し、指定されたコストに基づいて経路情報 (RouteInfo) を構築する。
    各エッジ（道路区間）を個別の GeoJSON Feature として返し、区間ごとの安全スコアを保持する。

    Args:
        db:          SQLAlchemy セッション
        start_node:  出発ノードID
        end_node:    到着ノードID
        cost_column: コスト指標カラム名（_ALLOWED_COST_COLUMNS のいずれか）
    """
    # ホワイトリスト検証（SQLインジェクション防止）
    if cost_column not in _ALLOWED_COST_COLUMNS:
        raise ValueError(f"Invalid cost_column: {cost_column!r}. Allowed: {_ALLOWED_COST_COLUMNS}")

    sql = _DIJKSTRA_PATH_SQL_TEMPLATE.format(cost_column=cost_column)
    result = db.execute(
        text(sql),
        {"start_node": start_node, "end_node": end_node}
    )
    steps = result.all()

    # pgRoutingの探索結果が空＝経路が存在しない
    if not steps or len(steps) <= 1:
        raise HTTPException(
            status_code=400,
            detail=f"No route found between the start and end points for {cost_column} metric."
        )

    features = []
    total_distance_m = 0.0
    weighted_safety_sum = 0.0

    for step in steps:
        edge_id = step.edge
        current_node = step.node

        # 終点ノードは対応するエッジがない (edge = -1) ためループ終了
        if edge_id == -1:
            break

        geom_json_str = step.geom_json
        if not geom_json_str:
            continue

        geom = json.loads(geom_json_str)
        edge_coords = geom["coordinates"]

        # 進行方向の判定:
        # pgr_dijkstra の node は「そのステップに進入するノード」を表す。
        # source_node が進入ノードと一致 → 順方向（source → target）
        # source_node が進入ノードと不一致 → 逆方向（target → source）→ 座標を反転
        is_reverse = (step.source_node != current_node)

        if is_reverse:
            edge_coords = list(reversed(edge_coords))

        # LineString には最低2点必要
        if len(edge_coords) < 2:
            continue

        length = step.length or 0.0
        safety_score = step.safety_score or 0.5
        total_distance_m += length
        weighted_safety_sum += safety_score * length

        # エッジごとに個別の Feature を生成（区間別安全スコア付き）
        features.append({
            "type": "Feature",
            "geometry": {
                "type": "LineString",
                "coordinates": edge_coords,
            },
            "properties": {
                "safety_score": safety_score,
            },
        })

    if total_distance_m > 0:
        avg_safety_score = weighted_safety_sum / total_distance_m
    else:
        avg_safety_score = 0.5

    # 安全スコアを 0.01〜1.0 にクランプ
    avg_safety_score = max(0.01, min(1.0, avg_safety_score))

    # GeoJSON FeatureCollection 形式に整形
    geojson = {
        "type": "FeatureCollection",
        "features": features,
    }

    return RouteInfo(
        route=geojson,
        distance_m=total_distance_m,
        safety_score=avg_safety_score
    )


def _collect_all_coordinates(route_info: RouteInfo) -> list[list[float]]:
    """
    RouteInfo 内の全 Feature から座標を連結し、1本の連続した座標列として返す。
    沿道ハザード検索用の LineString WKT を生成するために使用する。
    """
    all_coords = []
    for feature in route_info.route.get("features", []):
        coords = feature.get("geometry", {}).get("coordinates", [])
        if not all_coords:
            all_coords.extend(coords)
        elif coords:
            # 接続点の重複を除去
            if all_coords[-1] == coords[0]:
                all_coords.extend(coords[1:])
            else:
                all_coords.extend(coords)
    return all_coords


def _coords_to_linestring_wkt(coords: list[list[float]]) -> str:
    """座標リストを WKT LINESTRING 文字列に変換する。"""
    if len(coords) < 2:
        return ""
    point_strs = [f"{c[0]} {c[1]}" for c in coords]
    return f"LINESTRING({', '.join(point_strs)})"


def _query_nearby_hazards(db: Session, route_info: RouteInfo, radius_m: float = 1000.0) -> list[HazardPoint]:
    """
    ルート沿い（指定した radius_m 以内）のエリア型ハザードを検索する。
    detection（街灯・信号機等）は除外し、犯罪・野生動物等のみを返す。
    """
    coords = _collect_all_coordinates(route_info)
    if len(coords) < 2:
        return []

    route_wkt = _coords_to_linestring_wkt(coords)
    if not route_wkt:
        return []

    result = db.execute(
        _NEARBY_HAZARDS_SQL,
        {"route_wkt": route_wkt, "radius_m": radius_m}
    )
    rows = result.all()

    hazards = []
    for row in rows:
        hazards.append(HazardPoint(
            id=row.id,
            lat=row.lat,
            lng=row.lng,
            source_type=row.source_type,
            score_modifier=row.score_modifier,
            label=row.label,
            confidence=row.confidence,
            updated_at=row.updated_at,
        ))

    return hazards


# ---------------------------------------------------------------------------
# エンドポイント
# ---------------------------------------------------------------------------


@router.post("/route", response_model=RouteResponse)
def search_route(request: RouteRequest, db: Session = Depends(get_db)):
    """
    出発地・目的地を受け取り、安全スコア優先（safe_route）と最短距離優先（shortest_route）の2本のルートを返す。
    加えて、ルート沿いのエリア型ハザード情報（犯罪・野生動物等）を nearby_hazards として返す。
    """
    try:
        # 1. 出発地に最も近い交差点ノードを検索
        start_node_result = db.execute(
            _NEAREST_NODE_SQL,
            {"lng": request.start_lng, "lat": request.start_lat}
        ).fetchone()

        # 2. 目的地に最も近い交差点ノードを検索
        end_node_result = db.execute(
            _NEAREST_NODE_SQL,
            {"lng": request.end_lng, "lat": request.end_lat}
        ).fetchone()

        if not start_node_result or not end_node_result:
            raise HTTPException(
                status_code=404,
                detail="Start or end location is too far from the road network or not found.",
            )

        start_node_id = start_node_result.node_id
        end_node_id = end_node_result.node_id

        # 3. 出発ノードと到着ノードが同一の場合は、極小の直線ダミールートを返す（ゼロ除算・探索エラー回避）
        if start_node_id == end_node_id:
            geojson = {
                "type": "FeatureCollection",
                "features": [
                    {
                        "type": "Feature",
                        "geometry": {
                            "type": "LineString",
                            "coordinates": [
                                [request.start_lng, request.start_lat],
                                [request.end_lng, request.end_lat],
                            ],
                        },
                        "properties": {
                            "safety_score": 1.0,
                        },
                    }
                ],
            }
            zero_route = RouteInfo(route=geojson, distance_m=0.0, safety_score=1.0)
            return RouteResponse(
                safe_route=zero_route,
                shortest_route=zero_route,
                nearby_hazards=[],
            )

        # 4. 安全優先ルートを探索 (コスト指標: routing_cost)
        safe_route = _query_route_info(db, start_node_id, end_node_id, "routing_cost")

        # 4b. Roads API（Snap to Roads）でGoogle Mapsの道路形状に合わせてスナップ
        # 失敗時は roads_snap.py 内でフォールバックし、元の OSM ルートを返す
        safe_route = snap_route_to_roads(safe_route)

        # 5. 最短ルートを探索: Directions API（失敗時は OSM/pgRouting にフォールバック）
        shortest_route = _directions_shortest_route(
            start_lat=request.start_lat,
            start_lng=request.start_lng,
            end_lat=request.end_lat,
            end_lng=request.end_lng,
        )
        if shortest_route is None:
            logger.info("Directions API が失敗したため OSM pgRouting にフォールバックします。")
            shortest_route = _query_route_info(db, start_node_id, end_node_id, "length")

        # 6. 安全ルート沿いのエリア型ハザードを検索
        radius = request.hazard_radius_m if request.hazard_radius_m is not None else 1000.0
        nearby_hazards = _query_nearby_hazards(db, safe_route, radius_m=radius)

        return RouteResponse(
            safe_route=safe_route,
            shortest_route=shortest_route,
            nearby_hazards=nearby_hazards,
        )

    except HTTPException:
        raise
    except (OperationalError, ProgrammingError) as e:
        logger.error("Database error during route search: %s", e)
        raise HTTPException(
            status_code=503,
            detail="Route search service is temporarily unavailable. Database connection error.",
        )
    except Exception as e:
        logger.error("Unexpected error during route search: %s", e, exc_info=True)
        raise HTTPException(
            status_code=500,
            detail="An unexpected error occurred during route search.",
        )
