from sqlalchemy import text
from sqlalchemy.engine import Engine

def setup_triggers(engine: Engine):
    """
    データベーストリガーを設定する。
    detections テーブルにデータが追加/更新/削除された際、
    coverage_cells テーブルを集計・更新する。
    """
    trigger_sql = """
    CREATE OR REPLACE FUNCTION update_coverage_cells()
    RETURNS TRIGGER AS $$
    DECLARE
        v_cell_size FLOAT;
        v_sizes FLOAT[] := ARRAY[0.01, 0.002];
        v_cell_lat FLOAT;
        v_cell_lng FLOAT;
        v_geom geometry;
    BEGIN
        -- DELETE 実行時 または UPDATE で座標が変わった場合（古い座標のカウントを減らす）
        IF (TG_OP = 'DELETE') OR (TG_OP = 'UPDATE' AND NOT ST_Equals(OLD.geom, NEW.geom)) THEN
            FOREACH v_cell_size IN ARRAY v_sizes LOOP
                v_cell_lat := ROUND(CAST(FLOOR(ST_Y(OLD.geom) / v_cell_size) * v_cell_size AS NUMERIC), 5);
                v_cell_lng := ROUND(CAST(FLOOR(ST_X(OLD.geom) / v_cell_size) * v_cell_size AS NUMERIC), 5);
                
                UPDATE coverage_cells
                SET point_count = point_count - 1
                WHERE ABS(cell_lat - v_cell_lat) < 1e-6 AND ABS(cell_lng - v_cell_lng) < 1e-6 AND ABS(cell_size - v_cell_size) < 1e-6;
                
                -- カウントが0以下になったセルは削除
                DELETE FROM coverage_cells WHERE point_count <= 0;
            END LOOP;
        END IF;

        -- INSERT 実行時 または UPDATE で座標が変わった場合（新しい座標のカウントを増やす）
        IF (TG_OP = 'INSERT') OR (TG_OP = 'UPDATE' AND NOT ST_Equals(OLD.geom, NEW.geom)) THEN
            FOREACH v_cell_size IN ARRAY v_sizes LOOP
                v_cell_lat := ROUND(CAST(FLOOR(ST_Y(NEW.geom) / v_cell_size) * v_cell_size AS NUMERIC), 5);
                v_cell_lng := ROUND(CAST(FLOOR(ST_X(NEW.geom) / v_cell_size) * v_cell_size AS NUMERIC), 5);
                v_geom := ST_MakeEnvelope(v_cell_lng, v_cell_lat, v_cell_lng + v_cell_size, v_cell_lat + v_cell_size, 4326);
                
                INSERT INTO coverage_cells (cell_lat, cell_lng, cell_size, point_count, geom)
                VALUES (v_cell_lat, v_cell_lng, v_cell_size, 1, v_geom)
                ON CONFLICT (cell_lat, cell_lng, cell_size)
                DO UPDATE SET point_count = coverage_cells.point_count + 1;
            END LOOP;
        END IF;

        IF (TG_OP = 'DELETE') THEN
            RETURN OLD;
        ELSE
            RETURN NEW;
        END IF;
    END;
    $$ LANGUAGE plpgsql;

    DROP TRIGGER IF EXISTS trigger_update_coverage_cells ON detections;
    CREATE TRIGGER trigger_update_coverage_cells
    AFTER INSERT OR UPDATE OR DELETE ON detections
    FOR EACH ROW EXECUTE FUNCTION update_coverage_cells();
    """
    
    try:
        with engine.begin() as conn:
            conn.execute(text(trigger_sql))
            print("Database triggers created successfully.")
    except Exception as e:
        print(f"Error creating triggers: {e}")
