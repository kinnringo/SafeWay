import logging
import httpx
from fastapi import APIRouter, HTTPException, Query
from fastapi.responses import RedirectResponse
from app.core.config import settings

logger = logging.getLogger(__name__)
router = APIRouter()

_PLACES_API_URL = "https://maps.googleapis.com/maps/api/place/textsearch/json"
_NEARBY_API_URL = "https://maps.googleapis.com/maps/api/place/nearbysearch/json"
_DETAILS_API_URL = "https://maps.googleapis.com/maps/api/place/details/json"
_PHOTO_API_URL = "https://maps.googleapis.com/maps/api/place/photo"


@router.get("/places/search")
async def search_places(
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

    try:
        async with httpx.AsyncClient(timeout=10.0) as client:
            response = await client.get(_PLACES_API_URL, params=params)
            response.raise_for_status()
            return response.json()
    except httpx.TimeoutException:
        logger.error("Google Places API request timed out")
        raise HTTPException(status_code=504, detail="Google Places API request timed out.")
    except httpx.HTTPStatusError as e:
        logger.error(f"Google Places API returned error status: {e.response.status_code}")
        raise HTTPException(status_code=502, detail="Google Places API returned an error.")
    except Exception as e:
        logger.error(f"Unexpected error in places search: {e}")
        raise HTTPException(status_code=500, detail="Internal server error.")


@router.get("/places/nearby")
async def nearby_places(
    lat: float = Query(..., description="緯度"),
    lng: float = Query(..., description="経度")
):
    """
    Google Places API (Nearby Search) のプロキシエンドポイント。
    フロントエンドからの CORS 制約を回避し、指定した座標周辺の施設情報を距離順で取得する。
    """
    if not settings.GOOGLE_MAPS_API_KEY:
        raise HTTPException(status_code=500, detail="Google Maps API Key is not configured.")

    params = {
        "location": f"{lat},{lng}",
        "rankby": "distance",
        "type": "point_of_interest",
        "key": settings.GOOGLE_MAPS_API_KEY,
        "language": "ja",
    }

    try:
        async with httpx.AsyncClient(timeout=10.0) as client:
            response = await client.get(_NEARBY_API_URL, params=params)
            response.raise_for_status()
            return response.json()
    except httpx.TimeoutException:
        logger.error("Google Places API nearby search request timed out")
        raise HTTPException(status_code=504, detail="Google Places API request timed out.")
    except httpx.HTTPStatusError as e:
        logger.error(f"Google Places API nearby search returned error status: {e.response.status_code}")
        raise HTTPException(status_code=502, detail="Google Places API returned an error.")
    except Exception as e:
        logger.error(f"Unexpected error in nearby search: {e}")
        raise HTTPException(status_code=500, detail="Internal server error.")


@router.get("/places/details")
async def place_details(
    place_id: str = Query(..., description="Google Place ID")
):
    """
    Google Places API (Place Details) のプロキシエンドポイント。
    フロントエンドからの CORS 制約を回避し、指定した施設の詳細情報を取得する。
    """
    if not settings.GOOGLE_MAPS_API_KEY:
        raise HTTPException(status_code=500, detail="Google Maps API Key is not configured.")

    params = {
        "place_id": place_id,
        "key": settings.GOOGLE_MAPS_API_KEY,
        "language": "ja",
        "region": "jp",
    }

    try:
        async with httpx.AsyncClient(timeout=10.0) as client:
            response = await client.get(_DETAILS_API_URL, params=params)
            response.raise_for_status()
            return response.json()
    except httpx.TimeoutException:
        logger.error("Google Places API details request timed out")
        raise HTTPException(status_code=504, detail="Google Places API request timed out.")
    except httpx.HTTPStatusError as e:
        logger.error(f"Google Places API details returned error status: {e.response.status_code}")
        raise HTTPException(status_code=502, detail="Google Places API returned an error.")
    except Exception as e:
        logger.error(f"Unexpected error in place details: {e}")
        raise HTTPException(status_code=500, detail="Internal server error.")


@router.get("/places/photo")
async def place_photo(
    photo_reference: str = Query(..., description="写真のリファレンス文字列"),
    maxwidth: int = Query(400, description="画像の最大幅"),
):
    """
    Google Places API (Place Photo) のプロキシエンドポイント。
    Googleからのリダイレクト先（実際の画像URL）をフロントエンドへ 302 でリダイレクトする。
    """
    if not settings.GOOGLE_MAPS_API_KEY:
        raise HTTPException(status_code=500, detail="Google Maps API Key is not configured.")

    params = {
        "photo_reference": photo_reference,
        "maxwidth": str(maxwidth),
        "key": settings.GOOGLE_MAPS_API_KEY,
    }

    try:
        # Google Places Photo API は画像を直接返すか、実際の画像URLへ 302 リダイレクトを返す。
        # リダイレクトを追従せず、その Location ヘッダをそのままフロントに返す。
        async with httpx.AsyncClient(timeout=10.0, follow_redirects=False) as client:
            response = await client.get(_PHOTO_API_URL, params=params)
            
            # リダイレクト（301, 302, 303, 307, 308）の場合
            if 300 <= response.status_code < 400 and "location" in response.headers:
                return RedirectResponse(url=response.headers["location"])
            
            # リダイレクトされずに画像データが直接返ってきた場合（ストリーミングはせずに今回は簡略化してエラーハンドリング）
            # 基本的に 302 が返ってくるため、それ以外は期待しない動作として処理する
            response.raise_for_status()
            logger.error("Place Photo API did not return a redirect as expected.")
            raise HTTPException(status_code=502, detail="Unexpected response from Google Photo API.")
            
    except httpx.TimeoutException:
        logger.error("Google Places API photo request timed out")
        raise HTTPException(status_code=504, detail="Google Places API request timed out.")
    except httpx.HTTPStatusError as e:
        logger.error(f"Google Places API photo returned error status: {e.response.status_code}")
        raise HTTPException(status_code=502, detail="Google Places API returned an error.")
    except Exception as e:
        logger.error(f"Unexpected error in place photo: {e}")
        raise HTTPException(status_code=500, detail="Internal server error.")
