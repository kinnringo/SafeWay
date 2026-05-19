"""ルート検索API"""

from fastapi import APIRouter

from app.models.schemas import RouteRequest, RouteResponse

router = APIRouter()


@router.post("/route", response_model=RouteResponse)
async def search_route(request: RouteRequest):
    """
    出発地・目的地を受け取り、安全スコアベースの最適ルートを返す。

    現時点ではダミーの直線ルートを返す。
    ルーティングエンジン確定後に実装を差し替える。
    """
    # TODO: ルーティングエンジンによる経路探索を実装
    return RouteResponse(
        route={
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
                    "properties": {"safety_score": 0.5},
                }
            ],
        },
        distance_m=0.0,
        safety_score=0.5,
    )
