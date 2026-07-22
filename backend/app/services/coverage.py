"""カバレッジセル更新サービス

SafetyPoint が追加されたときに、対応するグリッドセルの point_count を
インクリメンタルに更新する。

設計思想:
  - 書き込み時に計算し、読み込み時は参照するだけ（Write-heavy, Read-light）
  - 各解像度（low / high）のセルを INSERT or UPDATE（O(1) × 2回）
  - UNIQUE制約 + ON CONFLICT DO UPDATE でアトミックな更新を保証
"""
import logging
import math

from sqlalchemy import text
from sqlalchemy.orm import Session

logger = logging.getLogger(__name__)

# 管理する解像度一覧（度）
CELL_SIZES = [0.01, 0.002]

# UPSERT 用 SQL
# UNIQUE(cell_lat, cell_lng, cell_size) を利用した ON CONFLICT DO UPDATE
_UPSERT_COVERAGE_SQL = text("""
    INSERT INTO coverage_cells (cell_lat, cell_lng, cell_size, point_count, geom)
    VALUES (
        FLOOR(:lat / :cell_size) * :cell_size,
        FLOOR(:lng / :cell_size) * :cell_size,
        :cell_size,
        1,
        ST_MakeEnvelope(
            FLOOR(:lng / :cell_size) * :cell_size,
            FLOOR(:lat / :cell_size) * :cell_size,
            FLOOR(:lng / :cell_size) * :cell_size + :cell_size,
            FLOOR(:lat / :cell_size) * :cell_size + :cell_size,
            4326
        )
    )
    ON CONFLICT (cell_lat, cell_lng, cell_size) DO UPDATE
    SET point_count = coverage_cells.point_count + 1
""")


def update_coverage_cells(db: Session, lat: float, lng: float) -> None:
    """
    指定座標が属するカバレッジセルの point_count を +1 する。

    全ての解像度（CELL_SIZES）に対して実行する。

    Args:
        db:  SQLAlchemy セッション（呼び出し元でコミットすること）
        lat: SafetyPoint の緯度
        lng: SafetyPoint の経度
    """
    for cell_size in CELL_SIZES:
        try:
            db.execute(_UPSERT_COVERAGE_SQL, {
                "lat": lat,
                "lng": lng,
                "cell_size": cell_size,
            })
            logger.debug(
                "Coverage cell updated: (%.6f, %.6f) cell_size=%.4f",
                lat, lng, cell_size,
            )
        except Exception as e:
            logger.warning("Coverage cell update failed (cell_size=%.4f): %s", cell_size, e)
