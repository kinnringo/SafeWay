"""ルーティングサービス

ルーティングエンジン（osmnx + networkx or Valhalla）を呼び出し、
安全スコアベースの最適経路を計算するビジネスロジック。
"""

# TODO: ルーティングエンジン確定後に実装


async def find_safe_route(
    start_lat: float,
    start_lng: float,
    end_lat: float,
    end_lng: float,
) -> dict:
    """安全スコアベースの最適ルートを計算して GeoJSON で返す。"""
    raise NotImplementedError("ルーティングエンジン未実装")
