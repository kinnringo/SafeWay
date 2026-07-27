"""
データベース内のレコード（detections および crime_reports）の特定ID・範囲削除と、
紐づく safety_points の削除、ならびに道路ネットワークの安全スコアリセット＆全面リフレッシュ統合スクリプト。

【使用方法 / ターミナルコマンド例】
    # 1. detections (アセット検出) の ID 1 から 18 を完全に削除し、スコアを再構築する
    .venv\\Scripts\\python scripts\\clean_db_records.py detections 1 18

    # 2. crime_reports (危険情報/クマ・犯罪等) の ID 46 から 49 を削除し、スコアを再構築する
    .venv\\Scripts\\python scripts\\clean_db_records.py crime_reports 46 49

    # 単一ID (例: detections の 25) のみを削除したい場合
    .venv\\Scripts\\python scripts\\clean_db_records.py detections 25 25

※ 対象の指定パラメータには、短縮形やハイフン区切り（crime, crime-reports, cr, d など）も対応
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

def delete_and_rescore(target_type: str, min_id: int, max_id: int):
    db: Session = SessionLocal()
    try:
        # 入力の表記揺れを正規化
        normalized_target = target_type.lower().strip()
        if normalized_target in ["detections", "detection", "d", "det"]:
            table_name = "detections"
            fk_col = "detection_id"
        elif normalized_target in ["crime_reports", "crime-reports", "crime_report", "crime", "cr", "c"]:
            table_name = "crime_reports"
            fk_col = "crime_report_id"
        else:
            logger.error(f"❌ 不明な対象ジャンルです: '{target_type}'。'detections' または 'crime_reports' を指定してください。")
            sys.exit(1)

        logger.info(f"=== 1. 【{table_name}】テーブル ID {min_id} 〜 {max_id} および紐づく safety_points を完全削除します ===")
        
        # 1. safety_points テーブルから紐づくレコードを削除
        res_sp = db.execute(
            text(f"DELETE FROM safety_points WHERE {fk_col} BETWEEN :min_id AND :max_id;"),
            {"min_id": min_id, "max_id": max_id}
        )
        logger.info(f" -> [safety_points] テーブルから {res_sp.rowcount} 件の連動レコードを削除しました。")
        
        # 2. 本体（detections または crime_reports）から対象レコードを削除
        res_main = db.execute(
            text(f"DELETE FROM {table_name} WHERE id BETWEEN :min_id AND :max_id;"),
            {"min_id": min_id, "max_id": max_id}
        )
        logger.info(f" -> [{table_name}] テーブルから {res_main.rowcount} 件の対象データを完全消去しました。")
        
        db.commit()

        logger.info("=== 2. 古いスコアの干渉を防ぐため、一度全道路エッジの安全スコアを初期値にリセットします ===")
        db.execute(text("""
            UPDATE road_edges 
            SET dynamic_safety_score = 0.0,
                safety_score = base_safety_score,
                routing_cost = length * (1.0 / GREATEST(0.01, base_safety_score));
        """))
        db.commit()
        logger.info(" -> 道路エッジの全件初期化（リセット）完了。")

        logger.info("=== 3. データベースに現存・稼働するすべての安全ポイントに基づき地図スコアを美しく再構成します ===")
        remaining_points = db.execute(text("SELECT ST_X(geom) as lng, ST_Y(geom) as lat FROM safety_points WHERE is_visible = TRUE")).all()
        logger.info(f" -> 現在維持されている 残り {len(remaining_points)} 箇所の有効ハザード/アセット拠点の情報からロード計算を実行中...")
        
        updated_count = 0
        for p in remaining_points:
            updated_count += update_edge_scores_near_point(db, p.lng, p.lat)
            
        db.commit()
        logger.info(f"✨ 道路スコアの全リフレッシュ再構築完了！ 合計 {updated_count} セグメントに安全スコアが適用されました。")

        logger.info("=== 4. ゴーストメッシュ撲滅：現行のdetections（現地投稿）のみに基づいて coverage_cells を完全リセット＆再構築します ===")
        db.execute(text("TRUNCATE TABLE coverage_cells;"))
        for cell_size in [0.01, 0.002]:
            db.execute(text("""
                INSERT INTO coverage_cells (cell_lat, cell_lng, cell_size, point_count, geom)
                SELECT 
                    ROUND(CAST(FLOOR(ST_Y(geom) / :cs) * :cs AS NUMERIC), 5) as cell_lat,
                    ROUND(CAST(FLOOR(ST_X(geom) / :cs) * :cs AS NUMERIC), 5) as cell_lng,
                    :cs as cell_size,
                    COUNT(*) as point_count,
                    ST_MakeEnvelope(
                        ROUND(CAST(FLOOR(ST_X(geom) / :cs) * :cs AS NUMERIC), 5),
                        ROUND(CAST(FLOOR(ST_Y(geom) / :cs) * :cs AS NUMERIC), 5),
                        ROUND(CAST(FLOOR(ST_X(geom) / :cs) * :cs AS NUMERIC), 5) + :cs,
                        ROUND(CAST(FLOOR(ST_Y(geom) / :cs) * :cs AS NUMERIC), 5) + :cs,
                        4326
                    ) as geom
                FROM detections
                GROUP BY 1, 2, 3, 5
                ON CONFLICT (cell_lat, cell_lng, cell_size) DO UPDATE
                SET point_count = coverage_cells.point_count + EXCLUDED.point_count;
            """), {"cs": cell_size})
        db.commit()
        cnt_cells = db.execute(text("SELECT COUNT(*) FROM coverage_cells;")).scalar()
        logger.info(f"🌿 カバレッジセル完全同期！不必要なハザードや残骸は消え、純粋なアセット由来の {cnt_cells} メッシュが反映されました。")

    except Exception as e:
        db.rollback()
        logger.error(f"❌ 処理中にエラーが発生しました: {e}", exc_info=True)
        sys.exit(1)
    finally:
        db.close()

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="指定した種別のデータと紐づくスコア影響を一元削除＆再構築します")
    parser.add_argument("type", type=str, help="対象データ種別 ('detections' または 'crime_reports')")
    parser.add_argument("min_id", type=int, help="削除対象の開始ID (最小)")
    parser.add_argument("max_id", type=int, help="削除対象の終了ID (最大)")
    
    args = parser.parse_args()
    delete_and_rescore(args.type, args.min_id, args.max_id)
