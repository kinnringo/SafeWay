"""オブジェクト位置推定サービス

ピンホールカメラモデルとセンサーフュージョンを用いて、
写真に写った物体の実際の GPS 座標を推定する。

前提条件:
  - カメラは標準的なスマートフォンカメラ（単焦点、広角レンズ歪みは無視できる範囲）
  - 対象物体は地面から鉛直に立っているとみなす（街灯・電柱など）
  - pitch 角は ±30° 以内を想定する（それ以上は精度が著しく低下する）

座標系:
  - 方位角: 北=0°、東=90°、時計回り（地図のコンパス表記に準拠）
  - pitch: 上向きが正（+）、下向きが負（-）
  - 画像座標系: 左上が原点、y 軸は下向き正（標準的な画像座標）
"""
import math
import logging
from dataclasses import dataclass
from typing import Optional

from app.core.score_config import (
    DEFAULT_OBJECT_HEIGHT_M,
    FOCAL_LENGTH_35MM_FILM_WIDTH_MM,
    KNOWN_OBJECT_HEIGHTS,
)

logger = logging.getLogger(__name__)


@dataclass
class ObjectPositionEstimate:
    """物体位置推定の結果"""
    lat: float                           # 推定した物体の緯度
    lng: float                           # 推定した物体の経度
    slant_distance_m: float              # 推定した斜距離（カメラ〜物体中心、メートル）
    horizontal_distance_m: float         # 推定した水平距離（地面投影距離、メートル）
    pitch_deg: float                     # 推定したカメラの仰俯角（度）
    horizontal_angle_deg: float          # バウンディングボックス中心の水平オフセット角（度）
    position_accuracy: str               # "high" | "low"


def focal_length_mm_to_px(focal_length_35mm: float, image_width_px: int) -> float:
    """
    35mm 換算焦点距離をピクセル単位の焦点距離に変換する。

    ピンホールカメラモデルでは「焦点距離（px）」が必要。
    EXIF の FocalLengthIn35mmFilm を使い、36mm 基準幅で正規化して変換する。

    Args:
        focal_length_35mm: EXIF の FocalLengthIn35mmFilm 値（mm）
        image_width_px: 画像の横幅（ピクセル）

    Returns:
        焦点距離（ピクセル単位）
    
    例:
        focal_length_35mm=26, image_width_px=4032 → 2912 px（iPhone 標準カメラの代表値）
    """
    if focal_length_35mm <= 0:
        raise ValueError(f"focal_length_35mm must be positive, got {focal_length_35mm}")
    if image_width_px <= 0:
        raise ValueError(f"image_width_px must be positive, got {image_width_px}")

    return (focal_length_35mm / FOCAL_LENGTH_35MM_FILM_WIDTH_MM) * image_width_px


def estimate_object_position(
    user_lat: float,
    user_lng: float,
    bearing_deg: float,
    bbox_x1: float,
    bbox_y1: float,
    bbox_x2: float,
    bbox_y2: float,
    image_width: int,
    image_height: int,
    focal_length_px: float,
    object_label: str,
) -> ObjectPositionEstimate:
    """
    ピンホールカメラモデルを用いて、バウンディングボックスから物体の GPS 座標を推定する。

    計算ステップ:
      Step 1. バウンディングボックスの高さ（px）と物体の既知実高さ（m）から斜距離を推定
      Step 2. バウンディングボックスの垂直中心位置からカメラ仰俯角（pitch）を推定
      Step 3. 斜距離を水平距離に補正（pitch の cos 成分）
      Step 4. バウンディングボックスの水平中心位置から方位角オフセットを計算
      Step 5. コンパス方位角＋水平オフセット角 → 物体への実際の方位角
      Step 6. 方位角＋水平距離を GPS 座標オフセットに変換

    Args:
        user_lat:       撮影者の緯度
        user_lng:       撮影者の経度
        bearing_deg:    コンパス方位角（度、0=北、時計回り）
        bbox_x1/y1/x2/y2: バウンディングボックス（ピクセル座標）
        image_width/height: 画像サイズ（ピクセル）
        focal_length_px:  焦点距離（ピクセル単位、focal_length_mm_to_px() で変換済み）
        object_label:   YOLO 検出ラベル（高さ参照テーブルのキーに使用）

    Returns:
        ObjectPositionEstimate

    Raises:
        ValueError: バウンディングボックスや焦点距離が無効な場合
    """
    bbox_height_px = bbox_y2 - bbox_y1

    if bbox_height_px <= 0:
        raise ValueError(f"Invalid bbox height: {bbox_height_px} (y1={bbox_y1}, y2={bbox_y2})")
    if focal_length_px <= 0:
        raise ValueError(f"Invalid focal_length_px: {focal_length_px}")

    bbox_center_x = (bbox_x1 + bbox_x2) / 2.0
    bbox_center_y = (bbox_y1 + bbox_y2) / 2.0

    # ----------------------------------------------------------------
    # Step 1: 斜距離の推定（相似三角形の原理）
    #
    #   real_height / slant_distance = bbox_height_px / focal_length_px
    #   → slant_distance = real_height × focal_length_px / bbox_height_px
    #
    # 注意: これはバウンディングボックスが物体全体を含んでいることを前提とする。
    # 部分的にフレームアウトしている場合は過大推定になる。
    # ----------------------------------------------------------------
    real_height_m = KNOWN_OBJECT_HEIGHTS.get(object_label.lower(), DEFAULT_OBJECT_HEIGHT_M)

    # 地面レベルの物体（水たまり・クラック等）は実高さが極小で三角測量が機能しない。
    # KNOWN_OBJECT_HEIGHTS で 0.1m 未満が設定されているラベルは距離推定不能として弾く。
    if real_height_m < 0.1:
        raise ValueError(
            f"Object '{object_label}' has near-zero real height ({real_height_m}m). "
            "Triangulation-based distance estimation is not applicable."
        )

    slant_distance_m = (real_height_m * focal_length_px) / bbox_height_px

    logger.debug(
        "Object '%s': real_height=%.1fm, bbox_height=%dpx, focal_length_px=%.0fpx → slant_distance=%.1fm",
        object_label, real_height_m, bbox_height_px, focal_length_px, slant_distance_m,
    )

    # ----------------------------------------------------------------
    # Step 2: カメラ仰俯角（pitch）の推定
    #
    # 画像座標系では y 軸が下向き正なので:
    #   - bbox_center_y < image_height/2 → 物体は画像上半分 → カメラは上向き → pitch > 0
    #   - bbox_center_y > image_height/2 → 物体は画像下半分 → カメラは下向き → pitch < 0
    #
    # pitch_rad = -atan( (bbox_center_y - image_height/2) / focal_length_px )
    # ----------------------------------------------------------------
    y_offset_px = bbox_center_y - (image_height / 2.0)
    pitch_rad = -math.atan(y_offset_px / focal_length_px)
    pitch_deg = math.degrees(pitch_rad)

    # ----------------------------------------------------------------
    # Step 3: 水平距離への補正
    #
    # 斜距離 × cos(pitch) = 水平投影距離
    # pitch が正（上向き）でも負（下向き）でも cos は正なので abs() 不要
    # ----------------------------------------------------------------
    horizontal_distance_m = slant_distance_m * math.cos(pitch_rad)

    logger.debug(
        "pitch=%.1f°, slant_distance=%.1fm → horizontal_distance=%.1fm",
        pitch_deg, slant_distance_m, horizontal_distance_m,
    )

    # ----------------------------------------------------------------
    # Step 4: 水平方向オフセット角の計算
    #
    # バウンディングボックスの水平中心が画像中央からどれだけずれているかを
    # 角度（ラジアン）で表す。
    #   x_offset > 0 → 物体は画像右側 → カメラの正面より右にある
    #   x_offset < 0 → 物体は画像左側 → カメラの正面より左にある
    # ----------------------------------------------------------------
    x_offset_px = bbox_center_x - (image_width / 2.0)
    horizontal_angle_rad = math.atan(x_offset_px / focal_length_px)
    horizontal_angle_deg = math.degrees(horizontal_angle_rad)

    # ----------------------------------------------------------------
    # Step 5: 物体への実際の方位角（ラジアン）
    #
    # コンパス方位角（ラジアン）に水平オフセット角（ラジアン）を加算する。
    # 両者は同じ単位（ラジアン）で演算するため、ここでは変換を統一して行う。
    # ----------------------------------------------------------------
    actual_bearing_rad = math.radians(bearing_deg) + horizontal_angle_rad

    # ----------------------------------------------------------------
    # Step 6: GPS 座標オフセットへの変換
    #
    # 方位角の定義（北=0°、時計回り）に基づく変換:
    #   北方向成分 = horizontal_distance × cos(bearing) → 緯度変化
    #   東方向成分 = horizontal_distance × sin(bearing) → 経度変化
    #
    # 変換係数:
    #   緯度 1° ≈ 111,320 m（地球の子午線曲率から算出、日本国内では十分な精度）
    #   経度 1° ≈ 111,320 × cos(緯度) m（緯度が上がるほど経度 1° の距離は短くなる）
    # ----------------------------------------------------------------
    delta_lat = (horizontal_distance_m * math.cos(actual_bearing_rad)) / 111320.0
    delta_lng = (horizontal_distance_m * math.sin(actual_bearing_rad)) / (
        111320.0 * math.cos(math.radians(user_lat))
    )

    object_lat = user_lat + delta_lat
    object_lng = user_lng + delta_lng

    logger.debug(
        "User: (%.6f, %.6f) → Object: (%.6f, %.6f) [bearing=%.1f°, h_offset=%.1f°]",
        user_lat, user_lng, object_lat, object_lng, bearing_deg, horizontal_angle_deg,
    )

    return ObjectPositionEstimate(
        lat=object_lat,
        lng=object_lng,
        slant_distance_m=slant_distance_m,
        horizontal_distance_m=horizontal_distance_m,
        pitch_deg=pitch_deg,
        horizontal_angle_deg=horizontal_angle_deg,
        position_accuracy="high",
    )
