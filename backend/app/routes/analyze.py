"""画像解析API"""

from fastapi import APIRouter, File, UploadFile, Form

from app.models.schemas import AnalyzeResponse

router = APIRouter()


@router.post("/analyze", response_model=AnalyzeResponse)
async def analyze_image(
    image: UploadFile = File(...),
    lat: float = Form(...),
    lng: float = Form(...),
):
    """
    画像とGPS座標を受け取り、YOLO推論を行い検出結果を返す。

    現時点ではダミーの検出結果を返す。
    YOLO統合後に実装を差し替える。
    """
    # TODO: YOLO推論の実装
    return AnalyzeResponse(
        detections=[
            {
                "label": "streetlight",
                "confidence": 0.92,
                "bbox": [100, 200, 150, 300],
            }
        ],
        lat=lat,
        lng=lng,
        updated_score=0.75,
    )
