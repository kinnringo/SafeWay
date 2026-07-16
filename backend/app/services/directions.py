"""Google Maps Directions API サービス

歩行者モードの最短経路を Directions API で計算し、
GeoJSON FeatureCollection 形式の RouteInfo として返す。

失敗時は None を返し、呼び出し元で OSM フォールバックができるようにする。
"""

import json
import logging
import math
import urllib.parse
import urllib.request

from app.core.config import settings
from app.models.schemas import RouteInfo

logger = logging.getLogger(__name__)

# Directions API エンドポイント
_DIRECTIONS_URL = "https://maps.googleapis.com/maps/api/directions/json"


def _decode_polyline(encoded: str) -> list[list[float]]:
    """
    Google の Encoded Polyline Algorithm で圧縮された文字列を
    [[lng, lat], ...] の座標リスト（GeoJSON 形式: 経度, 緯度の順）に変換する。
    """
    coords = []
    index = 0
    lat = 0
    lng = 0

    while index < len(encoded):
        # 緯度をデコード
        result = 1
        shift = 0
        while True:
            b = ord(encoded[index]) - 63 - 1
            index += 1
            result += b << shift
            shift += 5
            if b < 0x1F:
                break
        lat += (~result >> 1) if (result & 1) != 0 else (result >> 1)

        # 経度をデコード
        result = 1
        shift = 0
        while True:
            b = ord(encoded[index]) - 63 - 1
            index += 1
            result += b << shift
            shift += 5
            if b < 0x1F:
                break
        lng += (~result >> 1) if (result & 1) != 0 else (result >> 1)

        # GeoJSON は [lng, lat] の順
        coords.append([lng * 1e-5, lat * 1e-5])

    return coords


def _haversine_m(coord1: list[float], coord2: list[float]) -> float:
    """[lng, lat] 形式の2点間のハバーサイン距離（メートル）を返す。"""
    lng1, lat1 = coord1
    lng2, lat2 = coord2
    r = 6371000.0
    phi1 = math.radians(lat1)
    phi2 = math.radians(lat2)
    dphi = math.radians(lat2 - lat1)
    dlambda = math.radians(lng2 - lng1)
    a = math.sin(dphi / 2) ** 2 + math.cos(phi1) * math.cos(phi2) * math.sin(dlambda / 2) ** 2
    return r * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a))


def get_shortest_route(
    start_lat: float,
    start_lng: float,
    end_lat: float,
    end_lng: float,
    *,
    default_safety_score: float = 0.5,
) -> RouteInfo | None:
    """
    Google Maps Directions API（歩行者モード）で最短経路を取得し RouteInfo を返す。

    Args:
        start_lat / start_lng: 出発地の緯度・経度
        end_lat / end_lng:     目的地の緯度・経度
        default_safety_score:  安全スコアのデフォルト値（0.01〜1.0）

    Returns:
        RouteInfo（GeoJSON FeatureCollection + 距離 + 安全スコア）、失敗時は None
    """
    if not settings.GOOGLE_MAPS_API_KEY:
        logger.warning("GOOGLE_MAPS_API_KEY が未設定のため Directions API をスキップします。")
        return None

    params = {
        "origin": f"{start_lat},{start_lng}",
        "destination": f"{end_lat},{end_lng}",
        "mode": "walking",
        "key": settings.GOOGLE_MAPS_API_KEY,
        "language": "ja",
    }
    url = f"{_DIRECTIONS_URL}?{urllib.parse.urlencode(params)}"

    try:
        with urllib.request.urlopen(url, timeout=10) as response:
            data = json.loads(response.read())
    except Exception as e:
        logger.error("Directions API 呼び出し失敗: %s", e)
        return None

    status = data.get("status")
    if status != "OK":
        logger.warning("Directions API ステータスが OK 以外: %s", status)
        return None

    routes = data.get("routes", [])
    if not routes:
        logger.warning("Directions API からルートが返されませんでした。")
        return None

    # 最初のルート、最初の leg を使用
    route = routes[0]
    legs = route.get("legs", [])
    if not legs:
        return None

    # ルート全体を overview_polyline からデコードして1つの Feature として返す。
    # 区間ごとの step も利用できるが、安全スコアは一律デフォルト値のため
    # overview ポリラインで1本の Feature にまとめる方が適切。
    overview_polyline = route.get("overview_polyline", {}).get("points", "")
    if not overview_polyline:
        return None

    coords = _decode_polyline(overview_polyline)
    if len(coords) < 2:
        return None

    # 総距離は API から取得（legs[*].distance.value の合計、単位はメートル）
    total_distance_m = sum(leg.get("distance", {}).get("value", 0) for leg in legs)

    if total_distance_m == 0:
        # フォールバック: 座標から計算
        for i in range(len(coords) - 1):
            total_distance_m += _haversine_m(coords[i], coords[i + 1])

    geojson = {
        "type": "FeatureCollection",
        "features": [
            {
                "type": "Feature",
                "geometry": {
                    "type": "LineString",
                    "coordinates": coords,
                },
                "properties": {
                    "safety_score": default_safety_score,
                },
            }
        ],
    }

    return RouteInfo(
        route=geojson,
        distance_m=float(total_distance_m),
        safety_score=default_safety_score,
    )
