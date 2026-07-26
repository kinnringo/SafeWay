"""
検出データ (detections) の特定ID・範囲削除および
伴う safety_points の削除と道路ネットワークの安全スコアリセット＆正確再構築ユーティリティ。

【使用方法 / ターミナルコマンド例】
    # ID 1 から 18 までの detections を完全に削除し、スコアを再評価する
    .venv\\Scripts\\python scripts\\clean_detections.py 1 18
    
    # 単一の ID (例: 25) のみを削除する場合
    .venv\\Scripts\\python scripts\\clean_detections.py 25 25
"""
import sys
import os
from pathlib import Path
import argparse
import logging

# プロジェクトルート (backend) をインポートパスへ追加
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from sqlalchemy import text
from sqlalchemy.orm import Session
from app.core.database import SessionLocal
from app.services.scoring import update_edge_scores_near_point

logging.basicConfig(level=logging.INFO, format='%(asctime)s [%(levelname)s] %(message)s')
logger = logging.getLogger(__name__)

def delete_and_rescore(min_id: int, max_id: int):
    db: Session = SessionLocal()
    try:
        logger.info(f"=== 1. ID が {min_id} から {max_id} の安全ポイント及び検出データを完全削除します ===")
        
        # 1. safety_points テーブルから関連するデータを削除
        res_sp = db.execute(
            text("DELETE FROM safety_points WHERE detection_id BETWEEN :min_id AND :max_id;"),
            {"min_id": min_id, "max_id": max_id}
        )
        logger.info(f" -> safety_points テーブルから {res_sp.rowcount} 件の関連レコードを削除しました。")
        
        # 2. detections テーブルから対象データを削除
        res_det = db.execute(
            text("DELETE FROM detections WHERE id BETWEEN :min_id AND :max_id;"),
            {"min_id": min_id, "max_id": max_id}
        )
        logger.info(f" -> detections テーブルから {res_det.rowcount} 件のデータを削除しました。")
        
        db.commit()

        logger.info("=== 2. 古いスコア影響を取り除くため、全道路エッジの安全スコアを一度リセットします ===")
        # 削除されたポイントによる過去の加減点を一旦リセットする
        db.execute(text("""
            UPDATE road_edges 
            SET dynamic_safety_score = 0.0,
                safety_score = base_safety_score,
                routing_cost = length * (1.0 / GREATEST(0.01, base_safety_score));
        """))
        db.commit()
        logger.info(" -> 道路エッジの初期化（リセット）完了。")

        logger.info("=== 3. 現在稼働中（残留）の全ハザード・アセット情報から地図スコアを美しく再計算します ===")
        remaining_points = db.execute(text("SELECT ST_X(geom) as lng, ST_Y(geom) as lat FROM safety_points WHERE is_visible = TRUE")).all()
        logger.info(f" -> 現在保持されている 残り {len(remaining_points)} 箇所のデータで周辺計算をやり直します...")
        
        updated_count = 0
        for p in remaining_points:
            updated_count += update_edge_scores_near_point(db, p.lng, p.lat)
            
        db.commit()
        logger.info(f"✨ 全ての再構築が完了しました！ 合計 {updated_count} エッジに対してスコアが正常適用されています。")

    except Exception as e:
        db.rollback()
        logger.error(f"エラーが発生しました: {e}", exc_info=True)
        sys.exit(1)
    finally:
        db.close()

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="指定範囲のdetectionsを削除して安全スコアをリセット＆再構成します")
    parser.add_argument("min_id", type=int, help="削除対象の開始ID (最小)")
    parser.add_argument("max_id", type=int, help="削除対象の終了ID (最大)")
    
    args = parser.parse_args()
    delete_and_rescore(args.min_id, args.max_id)
