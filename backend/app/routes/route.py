"""ルート検索API"""

import json
import logging
from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy import text
from sqlalchemy.orm import Session

from app.core.database import get_db
from app.models.schemas import RouteRequest, RouteResponse, RouteInfo

logger = logging.getLogger(__name__)
router = APIRouter()

# GIST空間インデックス（<->演算子）を利用した、最も近い交差点ノードの高速検索クエリ
_NEAREST_NODE_SQL = text("""
    SELECT 
        CASE 
            WHEN ST_Distance(ST_StartPoint(geom), ST_SetSRID(ST_MakePoint(:lng, :lat), 4326)) < 
                 ST_Distance(ST_EndPoint(geom), ST_SetSRID(ST_MakePoint(:lng, :lat), 4326))
            THEN source_node
            ELSE target_node
        END AS node_id
    FROM road_edges
    ORDER BY geom <-> ST_SetSRID(ST_MakePoint(:lng, :lat), 4326)
    LIMIT 1;
""")

# pgRouting Dijkstra 経路探索クエリのテンプレート
# カラム名（routing_cost または length）は安全に動的構築する
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


def _query_route_info(db: Session, start_node: int, end_node: int, cost_column: str) -> RouteInfo:
    """
    pgRoutingを実行し、指定されたコストに基づいて経路情報 (RouteInfo) を構築する。
    """
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

    coordinates = []
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

        # 進行方向（逆方向か）の判定
        # target_node == current_node の場合は、交差点を「逆走」しているため座標配列を反転する
        is_reverse = (step.target_node == current_node)

        if is_reverse:
            edge_coords = list(reversed(edge_coords))

        # 中間ノードの重複を排除しながら座標を結合
        if not coordinates:
            coordinates.extend(edge_coords)
        else:
            coordinates.extend(edge_coords[1:])

        length = step.length or 0.0
        safety_score = step.safety_score or 0.5
        total_distance_m += length
        weighted_safety_sum += safety_score * length

    if total_distance_m > 0:
        avg_safety_score = weighted_safety_sum / total_distance_m
    else:
        avg_safety_score = 0.5

    # 安全スコアを 0.01〜1.0 にクランプ
    avg_safety_score = max(0.01, min(1.0, avg_safety_score))

    # GeoJSON FeatureCollection 形式に整形
    geojson = {
        "type": "FeatureCollection",
        "features": [
            {
                "type": "Feature",
                "geometry": {
                    "type": "LineString",
                    "coordinates": coordinates,
                },
                "properties": {
                    "safety_score": avg_safety_score,
                },
            }
        ],
    }

    return RouteInfo(
        route=geojson,
        distance_m=total_distance_m,
        safety_score=avg_safety_score
    )


@router.post("/route", response_model=RouteResponse)
async def search_route(request: RouteRequest, db: Session = Depends(get_db)):
    """
    出発地・目的地を受け取り、安全スコア優先（safe_route）と最短距離優先（shortest_route）の2本のルートを返す。
    """
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
        )

    # 4. 安全優先ルートを探索 (コスト指標: routing_cost)
    safe_route = _query_route_info(db, start_node_id, end_node_id, "routing_cost")

    # 5. 最短ルートを探索 (コスト指標: length)
    shortest_route = _query_route_info(db, start_node_id, end_node_id, "length")

    return RouteResponse(
        safe_route=safe_route,
        shortest_route=shortest_route,
    )
