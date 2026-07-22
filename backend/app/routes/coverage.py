"""カバレッジ情報API（情報空白地帯可視化）

地図上に表示するための情報密度データを返す。
事前集計テーブル coverage_cells を参照し、データ量に依存しない
高速なレスポンスを実現する。

フロント側では、返却されたセルを色付き半透明ポリゴンとして描画し、
返却されなかった領域を灰色（情報なし）として表示する。
"""
import logging
import math

from fastapi import APIRouter, Depends, Query
from geoalchemy2 import functions as geofunc
from sqlalchemy.orm import Session

from app.core.database import get_db
from app.models.db_models import CoverageCell
from app.models.schemas import CoverageCellResponse, CoverageResponse

logger = logging.getLogger(__name__)
router = APIRouter()

# ズームレベルに応じたセルサイズ（度）
# low:  0.01°（約1km）→ ズーム ≤ 13
# high: 0.002°（約200m）→ ズーム > 13
CELL_SIZE_LOW = 0.01
CELL_SIZE_HIGH = 0.002
ZOOM_THRESHOLD = 13.0


def _zoom_to_cell_size(zoom: float) -> float:
    """ズームレベルからセルサイズを決定する"""
    if zoom <= ZOOM_THRESHOLD:
        return CELL_SIZE_LOW
    return CELL_SIZE_HIGH


@router.get("/coverage", response_model=CoverageResponse)
def get_coverage(
    min_lat: float = Query(..., description="バウンディングボックス南端の緯度"),
    min_lng: float = Query(..., description="バウンディングボックス西端の経度"),
    max_lat: float = Query(..., description="バウンディングボックス北端の緯度"),
    max_lng: float = Query(..., description="バウンディングボックス東端の経度"),
    zoom: float = Query(..., description="現在のズームレベル（セルサイズ決定に使用）"),
    db: Session = Depends(get_db),
):
    """
    指定されたバウンディングボックス内のカバレッジ情報を返す。

    - データが存在するセルだけを返す。
    - フロント側で、返却されなかったセルは「灰色（情報なし）」として描画する。
    - GiSTインデックスにより、データ量に依存しない高速な検索を実現。
    """
    cell_size = _zoom_to_cell_size(zoom)

    # バウンディングボックスでフィルタリング
    bbox = geofunc.ST_MakeEnvelope(min_lng, min_lat, max_lng, max_lat, 4326)

    rows = (
        db.query(
            CoverageCell.cell_lat,
            CoverageCell.cell_lng,
            CoverageCell.point_count,
        )
        .filter(
            CoverageCell.cell_size == cell_size,
            geofunc.ST_Intersects(CoverageCell.geom, bbox),
        )
        .all()
    )

    cells = [
        CoverageCellResponse(lat=row[0], lng=row[1], count=row[2])
        for row in rows
    ]

    logger.info(
        "Coverage: zoom=%.1f, cell_size=%.4f, cells=%d",
        zoom, cell_size, len(cells),
    )

    return CoverageResponse(
        cells=cells,
        cell_size=cell_size,
        total_cells=len(cells),
    )
