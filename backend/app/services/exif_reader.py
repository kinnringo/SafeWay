"""EXIF データ読み取りサービス

アップロードされた画像から Pillow を使用して EXIF メタデータを抽出する。
PIL/_getexif() を使用し、GPS・焦点距離・方位角を取得する。

対応する EXIF タグ:
  - GPSLatitude / GPSLatitudeRef  → 緯度（10進数変換）
  - GPSLongitude / GPSLongitudeRef → 経度（10進数変換）
  - GPSImgDirection / GPSImgDirectionRef → コンパス方位角
  - FocalLengthIn35mmFilm → 35mm換算焦点距離
"""
import io
import logging
from dataclasses import dataclass
from typing import Optional

from PIL import Image
from PIL.ExifTags import GPSTAGS, TAGS

logger = logging.getLogger(__name__)


@dataclass
class ExifMetadata:
    """EXIF から抽出した位置・カメラメタデータ"""
    lat: Optional[float] = None                   # 緯度（10進数）
    lng: Optional[float] = None                   # 経度（10進数）
    bearing_deg: Optional[float] = None           # コンパス方位角（度、0=北、時計回り）
    focal_length_35mm: Optional[float] = None     # 35mm換算焦点距離（mm）
    has_gps: bool = False                         # GPS タグが存在するか
    has_bearing: bool = False                     # GPSImgDirection が存在するか


def _to_float(value) -> float:
    """
    EXIF の有理数値を float に変換する。
    Pillow のバージョンによって IFDRational オブジェクトまたは (分子, 分母) タプルが
    返ってくるため、両方に対応する。
    """
    try:
        return float(value)  # IFDRational は __float__ をサポート
    except (TypeError, ValueError):
        pass
    if isinstance(value, tuple) and len(value) == 2:
        denominator = value[1]
        return float(value[0]) / float(denominator) if denominator != 0 else 0.0
    return 0.0


def _dms_to_decimal(dms_tuple: tuple, ref: str) -> float:
    """
    EXIF の度分秒（DMS）形式を10進数度に変換する。

    Args:
        dms_tuple: (degrees, minutes, seconds) の各値が有理数形式のタプル
        ref: 方向参照文字 ('N', 'S', 'E', 'W')

    Returns:
        10進数の緯度または経度（南/西の場合は負値）
    """
    if len(dms_tuple) != 3:
        raise ValueError(f"DMS tuple must have 3 elements, got {len(dms_tuple)}")

    degrees = _to_float(dms_tuple[0])
    minutes = _to_float(dms_tuple[1])
    seconds = _to_float(dms_tuple[2])

    decimal = degrees + minutes / 60.0 + seconds / 3600.0

    if ref in ('S', 'W'):
        decimal = -decimal

    return decimal


def _parse_gps_info(gps_raw: dict) -> tuple[Optional[float], Optional[float], Optional[float], bool, bool]:
    """
    GPSInfo サブ IFD の辞書を解析し、緯度・経度・方位角を返す。

    Returns:
        (lat, lng, bearing_deg, has_gps, has_bearing)
    """
    gps_named: dict = {}
    for tag_id, value in gps_raw.items():
        tag_name = GPSTAGS.get(tag_id, f"GPSTag_{tag_id}")
        gps_named[tag_name] = value

    lat: Optional[float] = None
    lng: Optional[float] = None
    bearing_deg: Optional[float] = None
    has_gps = False
    has_bearing = False

    # --- 緯度 ---
    if "GPSLatitude" in gps_named and "GPSLatitudeRef" in gps_named:
        try:
            lat = _dms_to_decimal(gps_named["GPSLatitude"], gps_named["GPSLatitudeRef"])
            has_gps = True
        except Exception as e:
            logger.warning("Failed to parse GPSLatitude: %s", e)

    # --- 経度 ---
    if "GPSLongitude" in gps_named and "GPSLongitudeRef" in gps_named:
        try:
            lng = _dms_to_decimal(gps_named["GPSLongitude"], gps_named["GPSLongitudeRef"])
        except Exception as e:
            logger.warning("Failed to parse GPSLongitude: %s", e)
            lat = None  # 経度が取れなければ緯度も無効
            has_gps = False

    # --- コンパス方位角 ---
    # GPSImgDirection: 写真撮影時にカメラが向いていた方向（0〜360°、北基準時計回り）
    # iOS: 撮影時に Location Services が ON の場合は自動記録される
    # Android: カメラアプリ・端末依存のため存在しない場合がある
    if "GPSImgDirection" in gps_named:
        try:
            raw_bearing = _to_float(gps_named["GPSImgDirection"])
            if 0.0 <= raw_bearing <= 360.0:
                bearing_deg = raw_bearing
                has_bearing = True
                # GPSImgDirectionRef: 'T'=真北, 'M'=磁北
                # 日本では磁気偏角が約7〜9°あるが、GPS座標との誤差に比べ軽微なため補正省略
                direction_ref = gps_named.get("GPSImgDirectionRef", "T")
                if direction_ref == "M":
                    logger.debug("GPSImgDirectionRef is Magnetic North; using as-is.")
        except Exception as e:
            logger.warning("Failed to parse GPSImgDirection: %s", e)

    return lat, lng, bearing_deg, has_gps, has_bearing


def extract_from_image(img: Image.Image) -> ExifMetadata:
    """
    PIL Image オブジェクトから EXIF メタデータを抽出する。

    Args:
        img: PIL Image オブジェクト（既に open() 済み）

    Returns:
        ExifMetadata: 取得できたフィールドのみ値が入ったデータクラス
    """
    result = ExifMetadata()

    try:
        raw_exif = img._getexif()
        if raw_exif is None:
            logger.debug("No EXIF data found in image.")
            return result

        # タグ ID → 名前 の辞書に変換
        named_exif: dict = {}
        for tag_id, value in raw_exif.items():
            tag_name = TAGS.get(tag_id, f"Tag_{tag_id}")
            named_exif[tag_name] = value

        # --- GPS 情報 ---
        if "GPSInfo" in named_exif:
            lat, lng, bearing, has_gps, has_bearing = _parse_gps_info(named_exif["GPSInfo"])
            result.lat = lat
            result.lng = lng
            result.bearing_deg = bearing
            result.has_gps = has_gps
            result.has_bearing = has_bearing

        # --- 35mm 換算焦点距離 ---
        # FocalLengthIn35mmFilm: センサーサイズの違いを吸収した換算値（mm）
        # FocalLength（実焦点距離）はセンサー幅がないと pixel 換算できないため使用しない
        if "FocalLengthIn35mmFilm" in named_exif:
            try:
                fl = _to_float(named_exif["FocalLengthIn35mmFilm"])
                if fl > 0:
                    result.focal_length_35mm = fl
            except Exception as e:
                logger.warning("Failed to parse FocalLengthIn35mmFilm: %s", e)

    except Exception as e:
        logger.warning("Unexpected error reading EXIF: %s", e)

    return result


def extract_from_bytes(image_bytes: bytes) -> ExifMetadata:
    """
    画像のバイト列から EXIF メタデータを抽出する。
    画像を open する前処理を含む便利関数。

    Args:
        image_bytes: アップロードされた画像のバイト列

    Returns:
        ExifMetadata
    """
    try:
        img = Image.open(io.BytesIO(image_bytes))
        return extract_from_image(img)
    except Exception as e:
        logger.warning("Failed to open image for EXIF extraction: %s", e)
        return ExifMetadata()
