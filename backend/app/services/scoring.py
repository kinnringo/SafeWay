"""安全スコア更新サービス

safety_points が追加・更新された際に、影響範囲内の edges の
safety_score と routing_cost を再計算して更新する。

設計思想:
  - 全 edges を毎回更新するのではなく、新規ポイントから INFLUENCE_RADIUS_M 以内の
    edges のみを部分更新することで、パフォーマンスを担保する
  - safety_score の最小値を 0.01 に制限し、ゼロ除算（1/score）を防ぐ
  - routing_cost = length × (1 / safety_score) の式により、安全な道ほどコストが低くなる
"""
import logging

from sqlalchemy import text
from sqlalchemy.orm import Session

from app.core.score_config import INFLUENCE_RADIUS_M

logger = logging.getLogger(__name__)

# SQL: 指定された点の周辺 INFLUENCE_RADIUS_M 以内にある edges のみを対象に
# safety_score と routing_cost を再計算して更新する部分更新クエリ
_UPDATE_EDGE_SCORES_SQL = text("""
    WITH affected_edges AS (
        -- Step 1: 新しいポイントから INFLUENCE_RADIUS_M 以内にある edges を特定する
        --         ST_DWithin は空間インデックスを使用するため高速に動作する
        --         SRID 3857 (Web Mercator) に変換することでメートル単位の距離指定が可能になる
        SELECT e.id
        FROM road_edges e
        WHERE ST_DWithin(
            ST_Transform(e.geom, 3857),
            ST_Transform(ST_SetSRID(ST_MakePoint(:lng, :lat), 4326), 3857),
            :radius_m
        )
    ),
    edge_stats AS (
        -- Step 2: 影響範囲内の各 edge につき、周囲 INFLUENCE_RADIUS_M 以内にある
        --         有効な safety_points の score_modifier を合算する
        SELECT
            e.id AS edge_id,
            COALESCE(SUM(sp.score_modifier), 0.0) AS score_sum
        FROM road_edges e
        JOIN affected_edges ae ON e.id = ae.id
        LEFT JOIN safety_points sp ON (
            sp.is_visible = TRUE
            AND ST_DWithin(
                ST_Transform(e.geom, 3857),
                ST_Transform(sp.geom, 3857),
                :radius_m
            )
        )
        GROUP BY e.id
    )
    -- Step 3: safety_score と routing_cost を更新する
    --   safety_score = CLAMP(base_safety_score + dynamic_score, 0.01, 1.0)
    --   routing_cost = length × (1.0 / safety_score)
    --     安全な道（score=0.9）→ cost が低くなる → 経路探索で選ばれやすい
    --     危険な道（score=0.1）→ cost が高くなる → 経路探索で避けられる
    UPDATE road_edges
    SET
        dynamic_safety_score = edge_stats.score_sum,
        safety_score = GREATEST(0.01, LEAST(1.0, base_safety_score + edge_stats.score_sum)),
        routing_cost = length * (
            1.0 / GREATEST(0.01, LEAST(1.0, base_safety_score + edge_stats.score_sum))
        )
    FROM edge_stats
    WHERE road_edges.id = edge_stats.edge_id
""")


def update_edge_scores_near_point(
    db: Session,
    lng: float,
    lat: float,
    radius_m: float = INFLUENCE_RADIUS_M,
) -> int:
    """
    指定した点の周囲 radius_m メートル以内にある edges の
    安全スコアと経路コストを再計算して更新する。

    safety_points への新規挿入後に呼び出すことで、
    次回のルート検索 API から即座に新しいスコアが反映される。

    Args:
        db:       SQLAlchemy セッション（呼び出し元でコミットすること）
        lng:      更新の起点となる経度（オブジェクトの推定位置）
        lat:      更新の起点となる緯度（オブジェクトの推定位置）
        radius_m: 更新対象とする半径（メートル）、デフォルトは score_config の値

    Returns:
        更新された edges の行数
    """
    result = db.execute(_UPDATE_EDGE_SCORES_SQL, {"lng": lng, "lat": lat, "radius_m": radius_m})
    affected_rows = result.rowcount

    logger.info(
        "Edge scores updated: %d edges affected near (%.6f, %.6f) within %.0fm",
        affected_rows, lat, lng, radius_m,
    )

    return affected_rows
