import io
import sys
from PIL import Image
from sqlalchemy.orm import Session
from sqlalchemy import text

# パス追加
from app.core.database import SessionLocal
from app.models.db_models import Detection, SafetyPoint
from app.services.detection import detect_objects

def create_dummy_image_bytes():
    # 100x100のダミー画像を作成
    img = Image.new('RGB', (100, 100), color='white')
    buf = io.BytesIO()
    img.save(buf, format='JPEG')
    return buf.getvalue()

async def run_test():
    db: Session = SessionLocal()
    try:
        print("1. Creating dummy image and running YOLO detection...")
        img_bytes = create_dummy_image_bytes()
        detections = await detect_objects(img_bytes)
        print(f"   Detections from YOLO: {detections}")
        
        # テストのために、もしYOLOが何も検出できなくても1つダミーの検出を手動で追加する
        test_detections = list(detections)
        if not test_detections:
            print("   (No objects detected by YOLO on white image. Adding a mock streetlight detection for testing)")
            test_detections.append({
                "label": "streetlight",
                "confidence": 0.95,
                "bbox": [10.0, 10.0, 50.0, 50.0]
            })
            
        print("2. Storing detections in PostgreSQL...")
        lat = 36.3895  # 前橋駅付近
        lng = 139.0634
        point_geom = f"SRID=4326;POINT({lng} {lat})"
        
        for d in test_detections:
            db_detection = Detection(
                user_id=None,
                label=d["label"],
                confidence=d["confidence"],
                image_path="test_image.jpg",
                geom=point_geom,
            )
            db.add(db_detection)
            db.flush()
            
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
        print("   Database commit successful.")
        
        # 保存内容の検証
        print("3. Verifying stored data from PostgreSQL...")
        res_detections = db.query(Detection).all()
        print(f"   Total detections in DB: {len(res_detections)}")
        for rd in res_detections:
            # PostGISのgeomを表示させるため、空間情報をSQLでクエリ
            point_wkt = db.execute(text(f"SELECT ST_AsText(geom) FROM detections WHERE id = {rd.id}")).scalar()
            print(f"   - Detection ID: {rd.id}, Label: {rd.label}, Geom WKT: {point_wkt}")
            
        res_safety = db.query(SafetyPoint).all()
        print(f"   Total safety points in DB: {len(res_safety)}")
        for sp in res_safety:
            sp_wkt = db.execute(text(f"SELECT ST_AsText(geom) FROM safety_points WHERE id = {sp.id}")).scalar()
            print(f"   - SafetyPoint ID: {sp.id}, Modifier: {sp.score_modifier}, Geom WKT: {sp_wkt}")
            
        print("\nTest completed successfully! Database connectivity and spatial data storage verified.")
        
    except Exception as e:
        db.rollback()
        print(f"Error occurred during test: {e}")
        sys.exit(1)
    finally:
        db.close()

if __name__ == "__main__":
    import asyncio
    asyncio.run(run_test())
