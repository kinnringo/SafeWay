import io
import requests
from PIL import Image
from sqlalchemy.orm import Session
from sqlalchemy import text

# DB接続用に backend/app からインポート
from app.core.database import SessionLocal
from app.models.db_models import Detection, SafetyPoint

API_URL = "http://127.0.0.1:8000/api/analyze"

def create_dummy_image_bytes():
    # 640x640 の白いダミー画像を作成 (YOLO が好むサイズ)
    img = Image.new('RGB', (640, 640), color='white')
    buf = io.BytesIO()
    img.save(buf, format='JPEG')
    return buf.getvalue()

def get_db_counts():
    db: Session = SessionLocal()
    try:
        det_count = db.query(Detection).count()
        sp_count = db.query(SafetyPoint).count()
        return det_count, sp_count
    finally:
        db.close()

def run_test():
    img_bytes = create_dummy_image_bytes()
    
    print("--- Test Start ---")
    
    # 0. 初期件数の確認
    init_det, init_sp = get_db_counts()
    print(f"Initial DB counts - Detections: {init_det}, SafetyPoints: {init_sp}")
    
    # 1. 1回目のアップロード (前橋駅付近, 街灯検出のダミー)
    print("\n1. Uploading first image (Maebashi station)...")
    files = {'image': ('test.jpg', img_bytes, 'image/jpeg')}
    data = {
        'lat': 36.3895,
        'lng': 139.0634,
        'bearing': 180.0,
        'focal_length_35mm': 26.0,
        'test_mode': True
    }
    
    response = requests.post(API_URL, files=files, data=data)
    if response.status_code != 200:
        print(f"Error: 1st API request failed with status {response.status_code}: {response.text}")
        return
        
    res_data = response.json()
    print("API Response:", res_data)
    
    det_count_1, sp_count_1 = get_db_counts()
    print(f"After 1st upload - Detections: {det_count_1} (diff: +{det_count_1 - init_det}), SafetyPoints: {sp_count_1} (diff: +{sp_count_1 - init_sp})")
    
    # 2. 2回目のアップロード (全く同じ位置、同じ方位角)
    print("\n2. Uploading second image (exact same position)...")
    files = {'image': ('test.jpg', img_bytes, 'image/jpeg')}
    # 同じデータを送る
    response2 = requests.post(API_URL, files=files, data=data)
    if response2.status_code != 200:
        print(f"Error: 2nd API request failed with status {response2.status_code}: {response2.text}")
        return
        
    det_count_2, sp_count_2 = get_db_counts()
    print(f"After 2nd upload - Detections: {det_count_2} (diff: +{det_count_2 - det_count_1}), SafetyPoints: {sp_count_2} (diff: +{sp_count_2 - sp_count_1})")
    
    # 検証: Detections は +1 されているが、SafetyPoints は増えていない (重複排除が効いている) はず
    det_diff = det_count_2 - det_count_1
    sp_diff = sp_count_2 - sp_count_1
    
    if det_diff > 0 and sp_diff == 0:
        print("\n[SUCCESS] Deduplication logic verified! SafetyPoint count did not increase for same location.")
    else:
        print(f"\n[FAILURE] Deduplication logic failed. Detection diff: {det_diff}, SafetyPoint diff: {sp_diff} (expected 0)")
        
    # 3. 3回目のアップロード (少し離れた位置: 約100m先、北緯 36.3905, 東経 139.0634)
    print("\n3. Uploading third image (100m away position)...")
    files = {'image': ('test.jpg', img_bytes, 'image/jpeg')}
    data_away = {
        'lat': 36.3905,
        'lng': 139.0634,
        'bearing': 180.0,
        'focal_length_35mm': 26.0,
        'test_mode': True
    }
    response3 = requests.post(API_URL, files=files, data=data_away)
    if response3.status_code != 200:
        print(f"Error: 3rd API request failed with status {response3.status_code}: {response3.text}")
        return
        
    det_count_3, sp_count_3 = get_db_counts()
    print(f"After 3rd upload - Detections: {det_count_3} (diff: +{det_count_3 - det_count_2}), SafetyPoints: {sp_count_3} (diff: +{sp_count_3 - sp_count_2})")
    
    sp_diff_away = sp_count_3 - sp_count_2
    if sp_diff_away == 1:
        print("\n[SUCCESS] Distant location successfully created a new SafetyPoint!")
    else:
        print(f"\n[FAILURE] Distant location did not create a new SafetyPoint. Diff: {sp_diff_away} (expected 1)")

if __name__ == "__main__":
    run_test()
