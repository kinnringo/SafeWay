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
        -- Step 1: 新しいポイントから更新対象範囲（:radius_m）以内にある edges を特定する
        SELECT e.id, e.geom, e.base_safety_score, e.length
        FROM road_edges e
        WHERE ST_DWithin(
            ST_Transform(e.geom, 3857),
            ST_Transform(ST_SetSRID(ST_MakePoint(:lng, :lat), 4326), 3857),
            :radius_m
        )
    ),
    nearby_points AS (
        -- Step 2: 周辺の safety_points を抽出する
        --         影響半径の最大値（クマの1000m等）を考慮し、余裕を持った範囲で検索する
        SELECT sp.id, sp.geom, sp.score_modifier, sp.influence_radius_m, sp.is_road_attribute
        FROM safety_points sp
        WHERE sp.is_visible = TRUE
          AND ST_DWithin(
              ST_Transform(sp.geom, 3857),
              ST_Transform(ST_SetSRID(ST_MakePoint(:lng, :lat), 4326), 3857),
              :radius_m + 1500.0
          )
    ),
    point_closest_edges AS (
        -- Step 3: 道路属性 (is_road_attribute=TRUE) について、最も近い路地（単一エッジ）を求める (KNN)
        SELECT np.id AS point_id,
               (
                   SELECT e.id
                   FROM road_edges e
                   ORDER BY e.geom <-> np.geom
                   LIMIT 1
               ) AS closest_edge_id
        FROM nearby_points np
        WHERE np.is_road_attribute = TRUE
    ),
    edge_stats AS (
        -- Step 4: 各エッジに対するスコア影響の合算
        SELECT ae.id AS edge_id, COALESCE(SUM(cs.score), 0.0) AS score_sum
        FROM affected_edges ae
        LEFT JOIN (
            -- 4A: 道路属性からのスコア（最も近い単一エッジのみに適用）
            SELECT pce.closest_edge_id AS edge_id, np.score_modifier AS score
            FROM nearby_points np
            JOIN point_closest_edges pce ON np.id = pce.point_id
            
            UNION ALL
            
            -- 4B: 広域ハザードからのスコア（距離減衰付き）
            SELECT e.id AS edge_id,
                   np.score_modifier * GREATEST(0.0, 1.0 - (ST_Distance(ST_Transform(e.geom, 3857), ST_Transform(np.geom, 3857)) / np.influence_radius_m)) AS score
            FROM nearby_points np
            JOIN road_edges e ON ST_DWithin(ST_Transform(e.geom, 3857), ST_Transform(np.geom, 3857), np.influence_radius_m)
            WHERE np.is_road_attribute = FALSE
        ) AS cs ON cs.edge_id = ae.id
        GROUP BY ae.id
    )
    -- Step 5: safety_score と routing_cost を更新する
    UPDATE road_edges
    SET
        dynamic_safety_score = edge_stats.score_sum,
        safety_score = GREATEST(0.01, LEAST(1.0, ae.base_safety_score + edge_stats.score_sum)),
        routing_cost = ae.length * (
            1.0 / GREATEST(0.01, LEAST(1.0, ae.base_safety_score + edge_stats.score_sum))
        )
    FROM edge_stats
    JOIN affected_edges ae ON ae.id = edge_stats.edge_id
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
