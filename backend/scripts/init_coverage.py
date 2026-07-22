"""カバレッジデータの初期構築スクリプト

既存の safety_points から coverage_cells を生成する。
"""
import sys
import os

# app モジュールを読み込めるようにパスを追加
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))

from sqlalchemy import text
from app.core.database import engine

def init_coverage():
    print("Initializing coverage_cells...")
    
    with engine.begin() as conn:
        # 1. 既存のデータをクリア (再実行可能なように)
        conn.execute(text("TRUNCATE TABLE coverage_cells;"))
        
        # 2. 各解像度で初期データを構築
        cell_sizes = [0.01, 0.002]
        
        for cell_size in cell_sizes:
            print(f"  Building for cell_size={cell_size}...")
            r = conn.execute(text("""
                INSERT INTO coverage_cells (cell_lat, cell_lng, cell_size, point_count, geom)
                SELECT
                    FLOOR(ST_Y(sp.geom) / :cell_size) * :cell_size,
                    FLOOR(ST_X(sp.geom) / :cell_size) * :cell_size,
                    :cell_size,
                    COUNT(*),
                    ST_MakeEnvelope(
                        FLOOR(ST_X(sp.geom) / :cell_size) * :cell_size,
                        FLOOR(ST_Y(sp.geom) / :cell_size) * :cell_size,
                        FLOOR(ST_X(sp.geom) / :cell_size) * :cell_size + :cell_size,
                        FLOOR(ST_Y(sp.geom) / :cell_size) * :cell_size + :cell_size,
                        4326
                    )
                FROM safety_points sp
                GROUP BY 1, 2, 3
                ON CONFLICT (cell_lat, cell_lng, cell_size) DO UPDATE
                SET point_count = EXCLUDED.point_count;
            """), {"cell_size": cell_size})
            print(f"    Inserted {r.rowcount} cells.")
            
    print("Done.")

if __name__ == "__main__":
    from dotenv import load_dotenv
    load_dotenv()
    init_coverage()
