"""
データベース内の 'street_light' 表記揺れの洗浄と、
対応する safety_points 及び road_edges のスコア再計算を行う一度切りのマイグレーションスクリプト
"""
import sys
import logging
from sqlalchemy import text
from sqlalchemy.orm import Session
from app.core.database import SessionLocal
from app.services.scoring import update_edge_scores_near_point
from app.core.score_config import SCORE_MODIFIERS
from geoalchemy2.shape import to_shape

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

def run_migration():
    db: Session = SessionLocal()
    try:
        logger.info("=== 1. DB内の 'street_light' を 'streetlight' へ更新します ===")
        res1 = db.execute(text("UPDATE detections SET label = 'streetlight' WHERE label = 'street_light';"))
        logger.info(f"Updated {res1.rowcount} records in detections table.")
        
        # safety_pointsのscore_modifierのうち、以前streetlight(または旧street_light)と認識されず 0.0 で登録されてしまっていたものの再計算
        logger.info("=== 2. streetlight および sidewalk の score_modifier 訂正 ===")
        # 街灯は 0.10, 歩道は 0.15
        val_streetlight = SCORE_MODIFIERS.get("streetlight", 0.10)
        val_sidewalk = SCORE_MODIFIERS.get("sidewalk", 0.15)
        
        res2 = db.execute(
            text("""
                UPDATE safety_points 
                SET score_modifier = :val_sl
                WHERE detection_id IN (
                    SELECT id FROM detections WHERE label = 'streetlight'
                ) AND (score_modifier = 0.0 OR score_modifier IS NULL);
            """),
            {"val_sl": val_streetlight}
        )
        logger.info(f"Updated {res2.rowcount} safety_points for streetlight to {val_streetlight}.")

        res3 = db.execute(
            text("""
                UPDATE safety_points 
                SET score_modifier = :val_sw
                WHERE detection_id IN (
                    SELECT id FROM detections WHERE label = 'sidewalk'
                ) AND (score_modifier = 0.0 OR score_modifier IS NULL);
            """),
            {"val_sw": val_sidewalk}
        )
        logger.info(f"Updated {res3.rowcount} safety_points for sidewalk to {val_sidewalk}.")
        db.commit()
        
        logger.info("=== 3. 影響を受ける周辺ロードエッジ(road_edges)の初期化＆一斉再計算を実行します ===")
        # 削除・変更前の古い累積を完全にゼロ化するため一度リセット
        db.execute(text("""
            UPDATE road_edges 
            SET dynamic_safety_score = 0.0,
                safety_score = base_safety_score,
                routing_cost = length * (1.0 / GREATEST(0.01, base_safety_score));
        """))
        db.commit()
        logger.info(" -> 全ロードエッジスコアをリセットしました。")

        # 現在登録されている全 safety_points について道路エッジスコアを確実に再計算する
        points = db.execute(text("SELECT ST_X(geom) as lng, ST_Y(geom) as lat FROM safety_points WHERE is_visible = TRUE")).all()
        logger.info(f"計 {len(points)} 個の安全ポイントについて周辺エッジの最新スコアを再構築します...")
        
        total_edges_updated = 0
        for p in points:
            count = update_edge_scores_near_point(db, p.lng, p.lat)
            total_edges_updated += count
            
        db.commit()
        logger.info(f"再計算がすべて完了しました！ 合計で延べ {total_edges_updated} エッジが最適化されました。")
        
    except Exception as e:
        db.rollback()
        logger.error(f"Migration error occurred: {e}", exc_info=True)
        sys.exit(1)
    finally:
        db.close()

if __name__ == "__main__":
    run_migration()
