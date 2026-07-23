import sys
import os

# Add backend directory to sys.path
sys.path.append(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from sqlalchemy import text
from app.core.database import SessionLocal

def backfill():
    db = SessionLocal()
    try:
        print("Starting backfill for coverage_cells from detections...")
        # Clear existing cells just in case
        db.execute(text("TRUNCATE TABLE coverage_cells;"))
        
        # Insert low res (0.01) cells
        db.execute(text("""
            INSERT INTO coverage_cells (cell_lat, cell_lng, cell_size, point_count, geom)
            SELECT 
                ROUND(CAST(FLOOR(ST_Y(geom) / 0.01) * 0.01 AS NUMERIC), 5) as cell_lat,
                ROUND(CAST(FLOOR(ST_X(geom) / 0.01) * 0.01 AS NUMERIC), 5) as cell_lng,
                0.01 as cell_size,
                COUNT(*) as point_count,
                ST_MakeEnvelope(
                    ROUND(CAST(FLOOR(ST_X(geom) / 0.01) * 0.01 AS NUMERIC), 5),
                    ROUND(CAST(FLOOR(ST_Y(geom) / 0.01) * 0.01 AS NUMERIC), 5),
                    ROUND(CAST(FLOOR(ST_X(geom) / 0.01) * 0.01 AS NUMERIC), 5) + 0.01,
                    ROUND(CAST(FLOOR(ST_Y(geom) / 0.01) * 0.01 AS NUMERIC), 5) + 0.01,
                    4326
                ) as geom
            FROM detections
            GROUP BY cell_lat, cell_lng, cell_size, geom;
        """))
        
        # Insert high res (0.002) cells
        db.execute(text("""
            INSERT INTO coverage_cells (cell_lat, cell_lng, cell_size, point_count, geom)
            SELECT 
                ROUND(CAST(FLOOR(ST_Y(geom) / 0.002) * 0.002 AS NUMERIC), 5) as cell_lat,
                ROUND(CAST(FLOOR(ST_X(geom) / 0.002) * 0.002 AS NUMERIC), 5) as cell_lng,
                0.002 as cell_size,
                COUNT(*) as point_count,
                ST_MakeEnvelope(
                    ROUND(CAST(FLOOR(ST_X(geom) / 0.002) * 0.002 AS NUMERIC), 5),
                    ROUND(CAST(FLOOR(ST_Y(geom) / 0.002) * 0.002 AS NUMERIC), 5),
                    ROUND(CAST(FLOOR(ST_X(geom) / 0.002) * 0.002 AS NUMERIC), 5) + 0.002,
                    ROUND(CAST(FLOOR(ST_Y(geom) / 0.002) * 0.002 AS NUMERIC), 5) + 0.002,
                    4326
                ) as geom
            FROM detections
            GROUP BY cell_lat, cell_lng, cell_size, geom;
        """))
        
        db.commit()
        print("Backfill completed successfully.")
        
        count = db.execute(text("SELECT COUNT(*) FROM coverage_cells;")).scalar()
        print(f"Total coverage cells created: {count}")
    except Exception as e:
        db.rollback()
        print(f"Error during backfill: {e}")
    finally:
        db.close()

if __name__ == "__main__":
    backfill()
