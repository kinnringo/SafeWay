"""Roads API Snap to Roads サービス

OSM で計算した安全経路の座標列を Google Roads API（Snap to Roads）に通し、
Google Maps の道路形状にスナップさせる。

設計上の重要な考慮点:
- 1リクエスト最大100点制限 → チャンク分割で対応
- Roads API は originalIndex を返す → スナップ後も per-segment safety_score を維持できる
- 重複する接合点の座標を事前に排除して Roads API に送ることで、スナップ後の連続性と正確な区間割り当てを保証
- API が一部の中間座標点（交差点など）の出力を省略した場合でも、インデックスのギャップを自動で検知して線形補間し、隙間のない正確な経路を再構築
- API 失敗時は元の RouteInfo をそのまま返すフォールバックあり
"""

import logging
import urllib.request
import urllib.parse
import json
import math
from app.core.config import settings
from app.models.schemas import RouteInfo

logger = logging.getLogger(__name__)

# Roads API エンドポイント
_SNAP_TO_ROADS_URL = "https://roads.googleapis.com/v1/snapToRoads"

# 1リクエストあたりの最大座標点数（API制限）
_CHUNK_SIZE = 100


def _calculate_distance_m(features: list[dict]) -> float:
    """
    Feature リストからすべての線分の総距離（メートル）をハバーサイン公式で計算する。
    """
    total = 0.0
    r = 6371000.0  # 地球の半径（メートル）
    
    for feature in features:
        coords = feature.get("geometry", {}).get("coordinates", [])
        for i in range(len(coords) - 1):
            lng1, lat1 = coords[i]
            lng2, lat2 = coords[i+1]
            
            r_lat1 = math.radians(lat1)
            r_lat2 = math.radians(lat2)
            d_lat = r_lat2 - r_lat1
            d_lng = math.radians(lng2 - lng1)
            
            a = (math.sin(d_lat / 2) ** 2 +
                 math.cos(r_lat1) * math.cos(r_lat2) * math.sin(d_lng / 2) ** 2)
            c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a))
            total += r * c
            
    return total


def snap_route_to_roads(route_info: RouteInfo) -> RouteInfo:
    """
    RouteInfo 内の全 Feature の座標を Roads API でスナップし、
    per-segment safety_score を維持した新しい RouteInfo を返す。

    失敗時（APIキー未設定・通信エラー等）は元の RouteInfo をそのまま返す。
    """
    if not settings.GOOGLE_MAPS_API_KEY:
        logger.warning("GOOGLE_MAPS_API_KEY が未設定のためスナップをスキップします。")
        return route_info

    features = route_info.route.get("features", [])
    if not features:
        return route_info

    try:
        # 全 Feature の座標を接合点の重複を除去して平坦化
        all_coords, feature_coord_indices = _flatten_features(features)

        if len(all_coords) < 2:
            return route_info

        # Roads API を呼び出してスナップ済み座標を取得
        snapped_points = _call_snap_api(all_coords)

        if not snapped_points:
            logger.warning("Roads API が空のレスポンスを返しました。元のルートを使用します。")
            return route_info

        # スナップ済み座標を元の Feature 構造に再割り当て
        new_features = _rebuild_features(snapped_points, feature_coord_indices, features)

        new_geojson = {
            "type": "FeatureCollection",
            "features": new_features,
        }

        # スナップ後の正確な距離を再計算
        actual_distance = _calculate_distance_m(new_features)

        return RouteInfo(
            route=new_geojson,
            distance_m=actual_distance,
            safety_score=route_info.safety_score,
        )

    except Exception as e:
        logger.error("Roads API スナップ処理中にエラーが発生しました: %s", e, exc_info=True)
        logger.warning("フォールバック: 元のOSMルートを返します。")
        return route_info


def _flatten_features(features: list[dict]) -> tuple[list[list[float]], list[list[int]]]:
    """
    全 Feature の座標を重複なしで1つのリストに連結し、
    各 Feature の座標が unique_coords のどのインデックスに対応するかを返す。

    Returns:
        unique_coords:         [[lng, lat], ...] の重複なし座標リスト
        feature_coord_indices: 各 Feature の座標インデックスリスト
    """
    unique_coords: list[list[float]] = []
    feature_coord_indices: list[list[int]] = []

    for feature in features:
        coords = feature.get("geometry", {}).get("coordinates", [])
        indices = []
        for c in coords:
            # 直前の座標と完全に同一なら追加せず、そのインデックスを再利用する（接合点の重複排除）
            if unique_coords and unique_coords[-1] == c:
                idx = len(unique_coords) - 1
            else:
                idx = len(unique_coords)
                unique_coords.append(c)
            indices.append(idx)
        feature_coord_indices.append(indices)

    return unique_coords, feature_coord_indices


def _call_snap_api(all_coords: list[list[float]]) -> list[dict]:
    """
    座標リストを100点チャンクに分割して Roads API を呼び出し、
    全スナップ済み点を結合したリストを返す。

    チャンク境界の重複点は次チャンクの先頭に含めて連続性を保証する。
    """
    all_snapped: list[dict] = []

    # チャンクに分割（前チャンクの最後1点を次チャンクの先頭に重複させる）
    chunks = []
    for i in range(0, len(all_coords), _CHUNK_SIZE - 1):
        chunk = all_coords[i:i + _CHUNK_SIZE]
        if len(chunk) < 2:
            break
        chunks.append((i, chunk))  # (開始インデックス, チャンク座標)

    for chunk_start, chunk in chunks:
        path_param = "|".join(f"{c[1]},{c[0]}" for c in chunk)  # lat,lng 形式
        params = {
            "path": path_param,
            "interpolate": "false",
            "key": settings.GOOGLE_MAPS_API_KEY,
        }
        url = f"{_SNAP_TO_ROADS_URL}?{urllib.parse.urlencode(params)}"

        try:
            with urllib.request.urlopen(url, timeout=10) as response:
                data = json.loads(response.read())
        except Exception as e:
            logger.error("Roads API チャンク呼び出し失敗（開始インデックス=%d）: %s", chunk_start, e)
            raise

        snapped_points = data.get("snappedPoints", [])
        if not snapped_points:
            logger.warning("Roads API が空の snappedPoints を返しました（開始インデックス=%d）", chunk_start)
            raise ValueError("Empty snappedPoints from Roads API")

        # originalIndex をチャンク内ローカル値からグローバル値に変換する
        # （補間点は None のまま維持する）
        for sp in snapped_points:
            local_idx = sp.get("originalIndex")
            if local_idx is not None:
                sp["originalIndex"] = chunk_start + local_idx

        # 最初のチャンク以外は先頭（重複点）の重複を判定して除去して結合
        if all_snapped and snapped_points:
            last_orig = all_snapped[-1].get("originalIndex")
            first_orig = snapped_points[0].get("originalIndex")
            if last_orig is not None and first_orig is not None and last_orig == first_orig:
                snapped_points = snapped_points[1:]

        all_snapped.extend(snapped_points)

    return all_snapped


def _point_distance_m(p1: list[float], p2: list[float]) -> float:
    """[lng, lat] 形式の2点間の距離（メートル）をハバーサイン公式で計算する"""
    lng1, lat1 = p1
    lng2, lat2 = p2
    r_lat1 = math.radians(lat1)
    r_lat2 = math.radians(lat2)
    d_lat = r_lat2 - r_lat1
    d_lng = math.radians(lng2 - lng1)
    
    a = (math.sin(d_lat / 2) ** 2 +
         math.cos(r_lat1) * math.cos(r_lat2) * math.sin(d_lng / 2) ** 2)
    c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a))
    return 6371000.0 * c


def _rebuild_features(
    snapped_points: list[dict],
    feature_coord_indices: list[list[int]],
    original_features: list[dict],
) -> list[dict]:
    """
    スナップ済み座標を元の Feature 構造に再割り当てして Feature リストを再構築する。

    各 Feature の coordinate indices を直接参照し、スナップ成功点はスナップ座標を、
    スナップ失敗点（未登録道路など）は元のOSM座標を使い、各 Feature の座標列を個別に構築する。
    この直接構築アプローチにより、セグメント割り当てや線形補間に起因する
    二重描画・道路外直線問題を根本的に解消する。
    """
    # 全元の座標をインデックスごとにマップ化
    all_coords_map: dict[int, list[float]] = {}
    for f_idx, indices in enumerate(feature_coord_indices):
        feat_coords = original_features[f_idx].get("geometry", {}).get("coordinates", [])
        for local_i, global_i in enumerate(indices):
            if local_i < len(feat_coords):
                all_coords_map[global_i] = feat_coords[local_i]

    # スナップ成功点をインデックスマップに格納。
    # 元の座標から30m以上離れた異常なスナップは誤スナップとして除外し、
    # その場合は all_coords_map のOSM座標がフォールバックとして使われる。
    idx_to_snap: dict[int, list[float]] = {}
    last_idx = 0
    for sp in snapped_points:
        location = sp.get("location", {})
        lat = location.get("latitude")
        lng = location.get("longitude")
        if lat is None or lng is None:
            continue
        idx = sp.get("originalIndex")
        if idx is not None:
            last_idx = idx
        else:
            idx = last_idx

        if idx in all_coords_map:
            orig_coord = all_coords_map[idx]
            snap_coord = [lng, lat]
            dist = _point_distance_m(orig_coord, snap_coord)
            if dist < 30.0:
                idx_to_snap[idx] = snap_coord
            else:
                logger.debug("Index %d のスナップ距離がしきい値を超えました(%.1fm)。OSM座標を採用します。", idx, dist)
        else:
            idx_to_snap[idx] = [lng, lat]

    # 全スナップ成功 global index をセットとして保持（O(1) ルックアップ用）
    snapped_set: set[int] = set(idx_to_snap.keys())

    # 各 Feature の座標列を indices から直接構築
    new_features = []
    for f_idx, (indices, orig_feat) in enumerate(zip(feature_coord_indices, original_features)):
        coords: list[list[float]] = []
        for global_i in indices:
            if global_i in idx_to_snap:
                # スナップ成功点
                coords.append(idx_to_snap[global_i])
            elif (global_i - 1) in snapped_set and (global_i + 1) in snapped_set:
                # 両隣のグローバル点がスナップ成功 → 孤立した失敗点（交差点省略など）
                # Feature境界をまたいでいても正しく補間できる
                p_left = idx_to_snap[global_i - 1]
                p_right = idx_to_snap[global_i + 1]
                coords.append([
                    (p_left[0] + p_right[0]) / 2.0,
                    (p_left[1] + p_right[1]) / 2.0,
                ])
            elif global_i in all_coords_map:
                # 先頭/末尾の未スナップ区間 or 連続したスナップ失敗区間
                # （Google未登録道路など）→ OSM座標をそのまま採用
                coords.append(all_coords_map[global_i])

        # 隣接する重複点を除去
        deduped: list[list[float]] = []
        for c in coords:
            if not deduped or deduped[-1] != c:
                deduped.append(c)

        if len(deduped) < 2:
            # スナップ後の座標が不足した場合は元のFeatureをそのまま使用
            new_features.append(orig_feat)
            continue

        original_score = (
            orig_feat
            .get("properties", {})
            .get("safety_score", 0.5)
        )

        new_features.append({
            "type": "Feature",
            "geometry": {
                "type": "LineString",
                "coordinates": deduped,
            },
            "properties": {
                "safety_score": original_score,
            },
        })

    return new_features
