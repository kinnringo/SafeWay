"""画像解析API"""

from fastapi import APIRouter, File, UploadFile, Form

from app.models.schemas import AnalyzeResponse
from app.services.detection import detect_objects

router = APIRouter()

@router.post("/analyze", response_model=AnalyzeResponse)
async def analyze_image(
    image: UploadFile = File(...),
    lat: float = Form(...),
    lng: float = Form(...),
):
    """
    画像とGPS座標を受け取り、YOLO推論を行い検出結果を返す。
    """
    # 1. アップロードされた画像ファイルの中身（バイト列）を読み込む
    image_bytes = await image.read()
    
    # 2. YOLO推論サービスを呼び出す
    detections = await detect_objects(image_bytes)
    
    # 3. 検出結果をもとに安全スコアを計算する（現時点では仮の計算式）
    # ※ 本来はここで街灯の有無やDBの過去データを参照してスコアを算出する
    base_score = 0.5
    # 例：何か1つ検出されるごとにスコアを+0.1する（最大1.0）
    bonus = len(detections) * 0.1
    updated_score = min(1.0, base_score + bonus)
    
    return AnalyzeResponse(
        detections=detections,
        lat=lat,
        lng=lng,
        updated_score=updated_score,
    )
