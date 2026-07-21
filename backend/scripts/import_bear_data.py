import os
import sys
import pandas as pd
from datetime import datetime
from sqlalchemy.orm import Session

# backend ディレクトリを sys.path に追加してモジュールをインポート可能にする
sys.path.append(os.path.abspath(os.path.join(os.path.dirname(__file__), '..')))

from app.core.database import SessionLocal
from app.models.db_models import CrimeReport, SafetyPoint

# CSVファイルのパス
CSV_PATH = r"file-path"

def import_bear_data():
    print(f"Reading CSV from {CSV_PATH}...")
    try:
        df = pd.read_csv(CSV_PATH)
    except Exception as e:
        print(f"Failed to read CSV: {e}")
        return

    # 日付型のパース（「目撃された日」列）
    df['parsed_date'] = pd.to_datetime(df['目撃された日'], errors='coerce')
    
    # 2026年7月1日以降のデータを抽出
    df_filtered = df[df['parsed_date'] >= '2026-07-01'].copy()
    
    # 「目撃された時間」が空欄のデータを除外
    df_filtered = df_filtered.dropna(subset=['目撃された時間'])
    
    print(f"Target records to import: {len(df_filtered)}")
    
    db: Session = SessionLocal()
    try:
        count = 0
        for index, row in df_filtered.iterrows():
            # 日時の構築
            date_str = row['parsed_date'].strftime('%Y-%m-%d')
            time_str = str(row['目撃された時間']).strip()
            
            # 時間が "7:30" などの形式であることを想定
            try:
                occurred_at = datetime.strptime(f"{date_str} {time_str}", "%Y-%m-%d %H:%M")
            except ValueError:
                print(f"Skipping row {index} due to invalid time format: {time_str}")
                continue
                
            # descriptionの構築（頭数と状況のみ）
            desc_parts = []
            if pd.notna(row['頭数']):
                desc_parts.append(f"【頭数】{row['頭数']}")
            if pd.notna(row['出没状況・被害状況']):
                desc_parts.append(f"【状況】{row['出没状況・被害状況']}")
            
            description = " ".join(desc_parts) if desc_parts else None
            
            # 座標の取得
            x = row['x']
            y = row['y']
            geom = f"POINT({x} {y})"
            
            # CrimeReportの作成
            crime_report = CrimeReport(
                event_type="bear",
                description=description,
                geom=geom,
                occurred_at=occurred_at
            )
            db.add(crime_report)
            db.flush() # IDを取得するためにフラッシュ
            
            # SafetyPointの作成
            safety_point = SafetyPoint(
                source_type="crime_report",
                crime_report_id=crime_report.id,
                score_modifier=-0.80,
                influence_radius_m=1000.0,
                is_road_attribute=False,
                geom=geom,
                is_visible=True
            )
            db.add(safety_point)
            
            count += 1
            
        db.commit()
        print(f"Successfully imported {count} bear records.")
    except Exception as e:
        db.rollback()
        print(f"An error occurred during import: {e}")
    finally:
        db.close()

if __name__ == "__main__":
    import_bear_data()
