"""ハザード情報API

地図上に表示するための safety_points データを返す。
バウンディングボックスによるエリア絞り込みと、source_type によるフィルタリングに対応。
"""
import logging
from typing import Optional

from fastapi import APIRouter, Depends, Query
from geoalchemy2 import functions as geofunc
from sqlalchemy import and_
from sqlalchemy.orm import Session, joinedload

from app.core.database import get_db
from app.models.db_models import Detection, SafetyPoint, CrimeReport
from app.models.schemas import HazardPoint, HazardsResponse

logger = logging.getLogger(__name__)
router = APIRouter()


@router.get("/hazards", response_model=HazardsResponse)
def get_hazards(
    min_lat: Optional[float] = Query(None, description="バウンディングボックス南端の緯度"),
    min_lng: Optional[float] = Query(None, description="バウンディングボックス西端の経度"),
    max_lat: Optional[float] = Query(None, description="バウンディングボックス北端の緯度"),
    max_lng: Optional[float] = Query(None, description="バウンディングボックス東端の経度"),
    source_type: Optional[str] = Query(None, description="フィルタ: 情報源の種別（detection, crime_report）"),
    db: Session = Depends(get_db),
):
    """
    地図表示用のハザードポイント一覧を返す。

    - バウンディングボックス4パラメータが全て指定された場合、その範囲内のポイントのみ返す。
    - source_type が指定された場合、その種別のポイントのみ返す。
    - is_visible=False のポイントは常に除外する。
    """
    # ベースクエリ: is_visible=True のみ、detection と crime_report を事前ロード
    query = (
        db.query(SafetyPoint)
        .options(
            joinedload(SafetyPoint.detection),
            joinedload(SafetyPoint.crime_report)
        )
        .filter(SafetyPoint.is_visible == True)
    )

    # バウンディングボックスフィルタ
    bbox_params = [min_lat, min_lng, max_lat, max_lng]
    if all(p is not None for p in bbox_params):
        # ST_MakeEnvelope(xmin, ymin, xmax, ymax, srid)
        bbox = geofunc.ST_MakeEnvelope(min_lng, min_lat, max_lng, max_lat, 4326)
        query = query.filter(geofunc.ST_Within(SafetyPoint.geom, bbox))

    # source_type フィルタ
    if source_type is not None:
        query = query.filter(SafetyPoint.source_type == source_type)

    # 更新日時の新しい順
    safety_points = query.order_by(SafetyPoint.updated_at.desc()).all()

    # レスポンス構築
    results: list[HazardPoint] = []
    for sp in safety_points:
        # PostGIS の POINT geometry から lat/lng を抽出
        point_wkt = db.execute(
            geofunc.ST_AsText(sp.geom)
        ).scalar()
        # "POINT(lng lat)" 形式からパース
        coords = point_wkt.replace("POINT(", "").replace(")", "").split()
        lng = float(coords[0])
        lat = float(coords[1])

        # detection からラベルと信頼度を取得
        label = None
        confidence = None
        if sp.detection is not None:
            label = sp.detection.label
            confidence = sp.detection.confidence

        # crime_report から event_type と description を取得
        event_type = None
        description = None
        if sp.crime_report is not None:
            event_type = sp.crime_report.event_type
            description = sp.crime_report.description

        results.append(
            HazardPoint(
                id=sp.id,
                lat=lat,
                lng=lng,
                source_type=sp.source_type,
                score_modifier=sp.score_modifier,
                label=label,
                confidence=confidence,
                event_type=event_type,
                description=description,
                updated_at=sp.updated_at,
            )
        )

    logger.info("Returning %d hazard points", len(results))
    return HazardsResponse(points=results, count=len(results))
