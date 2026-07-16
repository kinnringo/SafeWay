import logging
import urllib.parse
import urllib.request
import json
from fastapi import APIRouter, HTTPException, Query
from app.core.config import settings

logger = logging.getLogger(__name__)
router = APIRouter()

_PLACES_API_URL = "https://maps.googleapis.com/maps/api/place/textsearch/json"

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
