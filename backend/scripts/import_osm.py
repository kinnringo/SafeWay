"""OSM 道路ネットワークインポートスクリプト

新潟県・群馬県の歩行者向け道路ネットワークを OSMnx で取得し、
road_edges テーブルに投入するバッチスクリプト。

使い方:
    cd backend
    .venv/Scripts/python -m scripts.import_osm [--area 新潟県] [--max-edge-length 100]

設計方針:
    - OSMnx で network_type="walk" のグラフを取得する
    - 100m を超える長大エッジは強制分割する（スコア精度の確保）
    - source_node / target_node は連番 ID にリマッピングする
    - 既存データがある場合は TRUNCATE してからインポートする
"""
import argparse
import logging
import sys
import time
from typing import Optional

import osmnx as ox
import networkx as nx
from shapely.geometry import LineString
from sqlalchemy import text

# backend/ をルートとして実行されることを想定
sys.path.insert(0, ".")
from app.core.database import engine

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")
logger = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# 定数
# ---------------------------------------------------------------------------
# 県単位だと Overpass API のタイムアウトが発生するため、主要市区町村に分割して取得する
NIIGATA_AREAS = [
    "新潟市, 新潟県, 日本",
    "長岡市, 新潟県, 日本",
    "上越市, 新潟県, 日本",
    "三条市, 新潟県, 日本",
    "柏崎市, 新潟県, 日本",
    "新発田市, 新潟県, 日本",
    "燕市, 新潟県, 日本",
    "村上市, 新潟県, 日本",
    "十日町市, 新潟県, 日本",
    "五泉市, 新潟県, 日本",
    "佐渡市, 新潟県, 日本",
    "南魚沼市, 新潟県, 日本",
    "魚沼市, 新潟県, 日本",
    "糸魚川市, 新潟県, 日本",
    "妙高市, 新潟県, 日本",
    "小千谷市, 新潟県, 日本",
    "加茂市, 新潟県, 日本",
    "見附市, 新潟県, 日本",
    "阿賀野市, 新潟県, 日本",
    "胎内市, 新潟県, 日本",
]

GUNMA_AREAS = [
    "前橋市, 群馬県, 日本",
    "高崎市, 群馬県, 日本",
    "太田市, 群馬県, 日本",
    "伊勢崎市, 群馬県, 日本",
    "桐生市, 群馬県, 日本",
    "館林市, 群馬県, 日本",
    "渋川市, 群馬県, 日本",
    "沼田市, 群馬県, 日本",
    "藤岡市, 群馬県, 日本",
    "富岡市, 群馬県, 日本",
    "安中市, 群馬県, 日本",
    "みどり市, 群馬県, 日本",
]

DEFAULT_AREAS = NIIGATA_AREAS + GUNMA_AREAS
DEFAULT_MAX_EDGE_LENGTH_M = 100.0
DEFAULT_BASE_SAFETY_SCORE = 0.5
MAX_RETRIES = 3
RETRY_WAIT_SECONDS = 30

# OSMnx のグローバル設定
ox.settings.timeout = 300        # Overpass API タイムアウト（秒）
ox.settings.max_query_area_size = 50 * 1000 * 1000 * 1000  # クエリ分割閾値を大きめに


# ---------------------------------------------------------------------------
# 長大エッジの分割
# ---------------------------------------------------------------------------
def split_long_edges(G: nx.MultiDiGraph, max_length_m: float) -> nx.MultiDiGraph:
    """
    max_length_m を超えるエッジを等間隔で分割する。

    分割時に中間ノードを挿入し、元のエッジを削除して
    分割後のエッジ群に置き換える。
    """
    edges_to_split = []
    for u, v, key, data in G.edges(keys=True, data=True):
        length = data.get("length", 0)
        if length > max_length_m:
            edges_to_split.append((u, v, key, data))

    logger.info("分割対象エッジ数: %d (%.0fm超)", len(edges_to_split), max_length_m)

    # 新しいノードID用のカウンタ（既存の最大ノードIDより大きい値から開始）
    max_node_id = max(G.nodes()) if G.nodes() else 0
    next_node_id = max_node_id + 1

    for u, v, key, data in edges_to_split:
        geom = data.get("geometry")
        length = data.get("length", 0)

        if geom is None:
            # geometry がない場合はノード座標から直線を生成
            u_data = G.nodes[u]
            v_data = G.nodes[v]
            geom = LineString([
                (u_data["x"], u_data["y"]),
                (v_data["x"], v_data["y"]),
            ])

        # 分割数を決定（例: 250m → 3分割）
        n_segments = max(2, int(length / max_length_m) + 1)

        # LineString を等間隔で分割
        fractions = [i / n_segments for i in range(n_segments + 1)]
        points = [geom.interpolate(f, normalized=True) for f in fractions]

        # 元のエッジを削除
        G.remove_edge(u, v, key)

        # 分割エッジを追加
        prev_node = u
        for i in range(len(points) - 1):
            if i == len(points) - 2:
                # 最後のセグメント → 元の終点ノード v に接続
                curr_node = v
            else:
                # 中間ノードを作成
                curr_node = next_node_id
                next_node_id += 1
                mid_point = points[i + 1]
                G.add_node(curr_node, x=mid_point.x, y=mid_point.y)

            seg_geom = LineString([points[i], points[i + 1]])
            # 元のエッジ長をセグメント数で等分する（緯度による経度方向の縮みによる計算誤差を防止）
            seg_length = float(length) / n_segments

            # OSMnx のエッジデータを引き継ぎつつ、長さとジオメトリだけ更新
            seg_data = dict(data)
            seg_data["length"] = seg_length
            seg_data["geometry"] = seg_geom
            seg_data.pop("osmid", None)  # 分割後は元のOSM IDを保持しない

            G.add_edge(prev_node, curr_node, **seg_data)
            prev_node = curr_node

    return G


# ---------------------------------------------------------------------------
# DB投入
# ---------------------------------------------------------------------------
def import_to_db(G: nx.MultiDiGraph) -> int:
    """
    NetworkX グラフのエッジを road_edges テーブルに投入する。

    Returns:
        投入されたエッジ数
    """
    # ノードIDを連番にリマッピング（pgRouting 互換）
    node_id_map: dict[int, int] = {}
    counter = 1
    for node in G.nodes():
        node_id_map[node] = counter
        counter += 1

    # INSERT 用のデータを構築
    rows = []
    for u, v, data in G.edges(data=True):
        geom = data.get("geometry")
        # 型エラー（numpy.float64等）を防ぐため、明示的に Python 標準の float/int に変換
        length_val = float(data.get("length", 0))

        if geom is None:
            u_data = G.nodes[u]
            v_data = G.nodes[v]
            geom = LineString([
                (u_data["x"], u_data["y"]),
                (v_data["x"], v_data["y"]),
            ])

        wkt = geom.wkt
        source = int(node_id_map[u])
        target = int(node_id_map[v])

        # OSM ID の取得（分割されたエッジにはない場合がある）
        osm_id_raw = data.get("osmid")
        if isinstance(osm_id_raw, list):
            osm_id_raw = osm_id_raw[0]  # 複数ある場合は最初のものを使う
        osm_id = int(osm_id_raw) if osm_id_raw is not None else None

        base_score = float(DEFAULT_BASE_SAFETY_SCORE)
        routing_cost = float(length_val * (1.0 / base_score))

        rows.append({
            "osm_id": osm_id,
            "source_node": source,
            "target_node": target,
            "length": length_val,
            "geom_wkt": wkt,
            "base_safety_score": base_score,
            "dynamic_safety_score": 0.0,
            "safety_score": base_score,
            "routing_cost": routing_cost,
        })

    logger.info("DB投入開始: %d エッジ", len(rows))

    # バッチ INSERT
    insert_sql = text("""
        INSERT INTO road_edges
            (osm_id, source_node, target_node, length, geom,
             base_safety_score, dynamic_safety_score, safety_score, routing_cost)
        VALUES
            (:osm_id, :source_node, :target_node, :length,
             ST_GeomFromText(:geom_wkt, 4326),
             :base_safety_score, :dynamic_safety_score, :safety_score, :routing_cost)
    """)

    with engine.begin() as conn:
        # 既存データを削除（再インポート時の冪等性を担保）
        conn.execute(text("TRUNCATE TABLE road_edges RESTART IDENTITY CASCADE;"))
        logger.info("既存の road_edges データを削除しました。")

        # バッチサイズごとに INSERT（メモリ節約）
        batch_size = 5000
        for i in range(0, len(rows), batch_size):
            batch = rows[i:i + batch_size]
            conn.execute(insert_sql, batch)
            logger.info("  INSERT %d / %d 完了", min(i + batch_size, len(rows)), len(rows))

    logger.info("DB投入完了: %d エッジ", len(rows))
    return len(rows)


# ---------------------------------------------------------------------------
# 空間インデックスの作成
# ---------------------------------------------------------------------------
def create_spatial_index():
    """road_edges の geom カラムに GIST インデックスを作成する。"""
    with engine.begin() as conn:
        conn.execute(text("""
            CREATE INDEX IF NOT EXISTS idx_road_edges_geom
            ON road_edges USING GIST (geom);
        """))
        # 3857 変換後のインデックスも作成（ST_DWithin のメートル距離計算用）
        conn.execute(text("""
            CREATE INDEX IF NOT EXISTS idx_road_edges_geom_3857
            ON road_edges USING GIST (ST_Transform(geom, 3857));
        """))
        # source_node / target_node のインデックス（pgRouting 用）
        conn.execute(text("""
            CREATE INDEX IF NOT EXISTS idx_road_edges_source
            ON road_edges (source_node);
        """))
        conn.execute(text("""
            CREATE INDEX IF NOT EXISTS idx_road_edges_target
            ON road_edges (target_node);
        """))
    logger.info("空間インデックスを作成しました。")


# ---------------------------------------------------------------------------
# メイン
# ---------------------------------------------------------------------------
def main():
    parser = argparse.ArgumentParser(description="OSM 道路データを road_edges にインポートする")
    parser.add_argument(
        "--area",
        nargs="*",
        default=None,
        help="インポート対象のエリア名（例: '新潟県, 日本'）。未指定時は新潟県+群馬県",
    )
    parser.add_argument(
        "--max-edge-length",
        type=float,
        default=DEFAULT_MAX_EDGE_LENGTH_M,
        help=f"エッジの最大長（メートル）。これを超えるエッジは分割される（デフォルト: {DEFAULT_MAX_EDGE_LENGTH_M}）",
    )
    args = parser.parse_args()

    areas = args.area if args.area else DEFAULT_AREAS
    max_length = args.max_edge_length

    logger.info("=" * 60)
    logger.info("OSM 道路データインポート開始")
    logger.info("対象エリア: %s", areas)
    logger.info("最大エッジ長: %.0fm", max_length)
    logger.info("=" * 60)

    # 1. OSMnx でグラフを取得（エリアごとに取得してマージ）
    graphs = []
    failed_areas = []
    for i, area in enumerate(areas, 1):
        logger.info("[%d/%d] [%s] ダウンロード中...", i, len(areas), area)

        G = None
        for attempt in range(1, MAX_RETRIES + 1):
            try:
                t0 = time.time()
                G = ox.graph_from_place(area, network_type="walk")
                elapsed = time.time() - t0
                logger.info("[%s] 取得完了: %d ノード, %d エッジ (%.1f秒)",
                            area, len(G.nodes), len(G.edges), elapsed)
                break
            except Exception as e:
                logger.warning("[%s] 取得失敗 (試行 %d/%d): %s",
                               area, attempt, MAX_RETRIES, e)
                if attempt < MAX_RETRIES:
                    logger.info("  %d秒後にリトライします...", RETRY_WAIT_SECONDS)
                    time.sleep(RETRY_WAIT_SECONDS)
                else:
                    logger.error("[%s] %d回試行して取得できませんでした。スキップします。",
                                 area, MAX_RETRIES)
                    failed_areas.append(area)

        if G is not None:
            graphs.append(G)

    if failed_areas:
        logger.warning("以下のエリアの取得に失敗しました: %s", failed_areas)

    combined_graph = None
    if graphs:
        logger.info("全 %d エリアのグラフを結合中...", len(graphs))
        combined_graph = nx.compose_all(graphs)

    if combined_graph is None:
        logger.error("グラフの取得に失敗しました。")
        sys.exit(1)

    logger.info("統合グラフ: %d ノード, %d エッジ",
                len(combined_graph.nodes), len(combined_graph.edges))

    # 2. 長大エッジの分割
    logger.info("長大エッジを分割中...")
    combined_graph = split_long_edges(combined_graph, max_length)
    logger.info("分割後: %d ノード, %d エッジ",
                len(combined_graph.nodes), len(combined_graph.edges))

    # 3. DB に投入
    total = import_to_db(combined_graph)

    # 4. 空間インデックスの作成
    create_spatial_index()

    logger.info("=" * 60)
    logger.info("インポート完了: %d エッジを road_edges に投入しました。", total)
    logger.info("=" * 60)


if __name__ == "__main__":
    main()
