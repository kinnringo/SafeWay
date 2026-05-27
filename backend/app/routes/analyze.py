"""画像解析API"""

from fastapi import APIRouter, File, UploadFile, Form, Depends
from sqlalchemy.orm import Session

from app.core.database import get_db
from app.models.db_models import Detection, SafetyPoint
from app.models.schemas import AnalyzeResponse
from app.services.detection import detect_objects

router = APIRouter()

@router.post("/analyze", response_model=AnalyzeResponse)
async def analyze_image(
    image: UploadFile = File(...),
    lat: float = Form(...),
    lng: float = Form(...),
    db: Session = Depends(get_db),
):
    """
    画像とGPS座標を受け取り、YOLO推論を行い、結果をDBに保存して返す。
    """
    # 1. アップロードされた画像ファイルの中身（バイト列）を読み込む
    image_bytes = await image.read()
    
    # 2. YOLO推論サービスを呼び出す
    detections = await detect_objects(image_bytes)
    
    # 3. 検出結果をデータベースに保存
    # 点のジオメトリを POINT(経度 緯度) で記述 (PostGISはX=lng, Y=lat)
    point_geom = f"SRID=4326;POINT({lng} {lat})"
    
    for d in detections:
        db_detection = Detection(
            user_id=None,  # ログイン未実装のため一時的にNone
            label=d["label"],
            confidence=d["confidence"],
            image_path=None,  # 必要に応じてファイル保存パスを指定
            geom=point_geom,
        )
        db.add(db_detection)
        db.flush()  # IDを発行するためにflush
        
        # ラベルに応じて安全スコアへの影響度を決定
        # 街灯はプラス、障害物や水たまりはマイナス
        score_modifier = 0.0
        label_lower = d["label"].lower()
        if "light" in label_lower or "lantern" in label_lower:
            score_modifier = 0.1
        elif label_lower in ["obstacle", "puddle", "crack", "hole"]:
            score_modifier = -0.2
            
        db_safety_point = SafetyPoint(
            source_type="detections",
            detection_id=db_detection.id,
            score_modifier=score_modifier,
            geom=point_geom,
            is_visible=True,
        )
        db.add(db_safety_point)
        
    db.commit()
    
    # 4. 検出結果をもとに安全スコアを計算する（現時点では仮の計算式）
    base_score = 0.5
    bonus = len(detections) * 0.1
    updated_score = min(1.0, base_score + bonus)
    
    return AnalyzeResponse(
        detections=detections,
        lat=lat,
        lng=lng,
        updated_score=updated_score,
    )
