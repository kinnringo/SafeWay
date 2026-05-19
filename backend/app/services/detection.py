"""YOLO 推論サービス

アップロードされた画像に対して YOLO による物体検出を実行し、
街灯等の検出結果を返すビジネスロジック。
"""
import io
from pathlib import Path
from PIL import Image
from ultralytics import YOLO

# モデルのパスを設定 (backend/data/best.pt)
MODEL_PATH = Path(__file__).parent.parent.parent / "data" / "best.pt"

# 起動時に毎回ロードすると重いので、キャッシュ用の変数を用意
_model = None

def get_model():
    global _model
    if _model is None:
        if MODEL_PATH.exists():
            _model = YOLO(str(MODEL_PATH))
        else:
            raise FileNotFoundError(f"モデルファイルが見つかりません: {MODEL_PATH}")
    return _model

async def detect_objects(image_bytes: bytes) -> list[dict]:
    """画像バイト列を受け取り、検出結果のリストを返す。"""
    # 1. バイト列を画像(PIL Image)として読み込む
    image = Image.open(io.BytesIO(image_bytes))
    
    # 2. モデルを取得し、推論を実行
    model = get_model()
    # ※ダミーモデルでとりあえず何か反応させるため、conf(信頼度)の閾値を意図的に低く(0.2)しています
    results = model(image, conf=0.2)
    
    detections = []
    
    # 3. Ultralyticsの推論結果を、フロントエンドに返す形式の辞書に変換
    if len(results) > 0:
        for box in results[0].boxes:
            detections.append({
                "label": model.names[int(box.cls)],
                "confidence": float(box.conf),
                "bbox": box.xyxy[0].tolist(), # [x1, y1, x2, y2]のリスト
            })
            
    return detections
