import logging
import urllib.parse
import urllib.request
import json
from fastapi import APIRouter, HTTPException, Query
from app.core.config import settings

logger = logging.getLogger(__name__)
router = APIRouter()

_PLACES_API_URL = "https://maps.googleapis.com/maps/api/place/textsearch/json"
_NEARBY_API_URL = "https://maps.googleapis.com/maps/api/place/nearbysearch/json"

@router.get("/places/search")
def search_places(
    query: str = Query(..., description="検索キーワード"),
    location: str | None = Query(None, description="現在地 (lat,lng)"),
    radius: str | None = Query(None, description="検索範囲 (メートル)")
):
    """
    Google Places API (Text Search) のプロキシエンドポイント。
    フロントエンドからの CORS 制約を回避するために使用する。
    """
    if not settings.GOOGLE_MAPS_API_KEY:
        raise HTTPException(status_code=500, detail="Google Maps API Key is not configured.")

    params = {
        "query": query,
        "key": settings.GOOGLE_MAPS_API_KEY,
        "language": "ja",
        "region": "jp",
    }
    
    if location:
        params["location"] = location
    if radius:
        params["radius"] = radius
        
    url = f"{_PLACES_API_URL}?{urllib.parse.urlencode(params)}"
    
    try:
        req = urllib.request.Request(url)
        with urllib.request.urlopen(req, timeout=10) as response:
            data = json.loads(response.read().decode('utf-8'))
            return data
    except urllib.error.URLError as e:
        logger.error(f"Google Places API request failed: {e}")
        raise HTTPException(status_code=502, detail="Failed to connect to Google Places API.")
    except Exception as e:
        logger.error(f"Unexpected error in places search: {e}")
        raise HTTPException(status_code=500, detail="Internal server error.")


@router.get("/places/nearby")
def nearby_places(
    lat: float = Query(..., description="緯度"),
    lng: float = Query(..., description="経度"),
    radius: float = Query(30.0, description="検索半径（メートル）")
):
    """
    Google Places API (Nearby Search) のプロキシエンドポイント。
    フロントエンドからの CORS 制約を回避し、指定した座標周辺の施設情報を取得する。
    """
    if not settings.GOOGLE_MAPS_API_KEY:
        raise HTTPException(status_code=500, detail="Google Maps API Key is not configured.")

    params = {
        "location": f"{lat},{lng}",
        "radius": str(radius),
        "key": settings.GOOGLE_MAPS_API_KEY,
        "language": "ja",
    }
    
    url = f"{_NEARBY_API_URL}?{urllib.parse.urlencode(params)}"
    
    try:
        req = urllib.request.Request(url)
        with urllib.request.urlopen(req, timeout=10) as response:
            data = json.loads(response.read().decode('utf-8'))
            return data
    except urllib.error.URLError as e:
        logger.error(f"Google Places API nearby search request failed: {e}")
        raise HTTPException(status_code=502, detail="Failed to connect to Google Places API.")
    except Exception as e:
        logger.error(f"Unexpected error in nearby search: {e}")
        raise HTTPException(status_code=500, detail="Internal server error.")

