"""画像解析API

アップロードされた画像から YOLO で物体を検出し、
センサーフュージョン（GPS + コンパス + 焦点距離）または EXIF データを用いて
物体の実際の GPS 位置を推定し、DB に保存する。

対応する2種類のアップロード方式:
  1. ライブカメラ撮影:
       Flutter がリアルタイムでセンサー値（GPS・コンパス・焦点距離）を取得し、
       画像と一緒に Form フィールドとして送信する。
       EXIF に GPS 情報が埋め込まれていない場合もあるため、Form 値を最優先で使用する。

  2. 過去写真のアップロード:
       ユーザーが同一端末で撮影した無加工の EXIF 付き写真。
       Flutter は画像ファイルのみ送信し、バックエンドが EXIF から
       GPS・方位角・焦点距離を自動抽出する。

パラメータ優先順位（高→低）:
  Form フィールドの値 > EXIF から抽出した値 > エラーまたはフォールバック
"""
import io
import logging
from datetime import datetime
from typing import Optional

from fastapi import APIRouter, Depends, File, Form, HTTPException, UploadFile
from geoalchemy2 import functions as geofunc
from PIL import Image
from sqlalchemy.orm import Session

from app.core.database import get_db
from app.core.auth import get_current_user_optional
from app.core.score_config import (
    DEFAULT_SCORE_MODIFIER,
    SCORE_MODIFIERS,
    INFLUENCE_RADIUS_M,
)
from app.models.db_models import Detection, SafetyPoint, User, CoinTransaction
from app.models.schemas import AnalyzeResponse, DetectionResult
from app.services.detection import detect_objects
from app.services.exif_reader import extract_from_image
from app.services.geo_estimation import estimate_object_position, focal_length_mm_to_px
from app.services.scoring import update_edge_scores_near_point
from app.services.coverage import update_coverage_cells

logger = logging.getLogger(__name__)
router = APIRouter()


@router.post("/analyze", response_model=AnalyzeResponse)
async def analyze_image(
    image: UploadFile = File(..., description="解析する画像ファイル（JPEG/PNG）"),
    # --- カメラ用フィールド（省略可能; EXIF で補完される）---
    bearing: Optional[float] = Form(
        None,
        description=(
            "コンパス方位角（度、0=北、時計回り）。"
            "省略時は EXIF の GPSImgDirection から自動抽出する。"
            "どちらも存在しない場合は position_accuracy が 'low' になる。"
        ),
    ),
    focal_length_35mm: Optional[float] = Form(
        None,
        description=(
            "35mm 換算焦点距離（mm）。"
            "省略時は EXIF の FocalLengthIn35mmFilm から自動抽出する。"
            "どちらも存在しない場合は距離推定できず position_accuracy が 'low' になる。"
        ),
    ),
    test_mode: Optional[bool] = Form(
        False,
        description="Trueの場合、YOLOが何も検出しなくてもダミーの街灯検出を1つ注入します（デバッグ・テスト用）。",
    ),
    db: Session = Depends(get_db),
    current_user: Optional[User] = Depends(get_current_user_optional),
):
    """
    画像を受け取り、YOLO 推論 → 物体位置推定 → DB 保存を行い、
    検出結果と推定された物体位置を返す。
    ※ 撮影位置は画像に埋め込まれた EXIF(GPS) 情報のみを使用する。
    """
    # ----------------------------------------------------------------
    # 1. 画像を読み込み、PIL Image オブジェクトを生成する
    # ----------------------------------------------------------------
    image_bytes = await image.read()
    try:
        img = Image.open(io.BytesIO(image_bytes))
        img_width, img_height = img.size
    except Exception as e:
        raise HTTPException(status_code=400, detail=f"Invalid image file: {e}")

    # ----------------------------------------------------------------
    # 2. EXIF からメタデータを抽出する（過去写真のアップロード対応）
    # ----------------------------------------------------------------
    exif = extract_from_image(img)
    logger.info(
        "EXIF extracted: has_gps=%s, has_bearing=%s, focal_35mm=%s",
        exif.has_gps, exif.has_bearing, exif.focal_length_35mm,
    )

    # ----------------------------------------------------------------
    # 3. 座標は EXIF のみを使用し、他のパラメータはマージする
    # ----------------------------------------------------------------
    final_lat: Optional[float] = exif.lat
    final_lng: Optional[float] = exif.lng
    final_bearing: Optional[float] = bearing if bearing is not None else exif.bearing_deg
    final_focal_35mm: Optional[float] = (
        focal_length_35mm if focal_length_35mm is not None else exif.focal_length_35mm
    )

    # lat/lng は EXIF 情報から取得必須
    if final_lat is None or final_lng is None:
        raise HTTPException(
            status_code=400,
            detail=(
                "GPS coordinates are missing. "
                "Uploaded images must contain GPS EXIF data "
                "to determine the correct location."
            ),
        )

    # ----------------------------------------------------------------
    # 4. 焦点距離をピクセル単位に変換する（位置推定に使用）
    # ----------------------------------------------------------------
    focal_length_px: Optional[float] = None
    if final_focal_35mm is not None:
        try:
            focal_length_px = focal_length_mm_to_px(final_focal_35mm, img_width)
        except ValueError as e:
            logger.warning("Failed to convert focal length: %s", e)

    # 位置推定に必要な情報が揃っているか判定する
    can_estimate_position = (final_bearing is not None) and (focal_length_px is not None)

    if not can_estimate_position:
        logger.warning(
            "Cannot estimate object position: bearing=%s, focal_length_px=%s. "
            "Will use user position as fallback (accuracy=low).",
            final_bearing, focal_length_px,
        )

    # ----------------------------------------------------------------
    # 5. YOLO 推論を実行する
    # ----------------------------------------------------------------
    raw_detections = await detect_objects(image_bytes)
    logger.info("YOLO detected %d objects", len(raw_detections))

    if not raw_detections and test_mode:
        logger.info("Test mode enabled and no objects detected. Injecting mock streetlight detection.")
        raw_detections.append({
            "label": "streetlight",
            "confidence": 0.95,
            "bbox": [img_width * 0.4, img_height * 0.2, img_width * 0.6, img_height * 0.8]
        })

    # ----------------------------------------------------------------
    # 6. 各検出結果について物体の GPS 位置を推定し、DB に保存する
    # ----------------------------------------------------------------
    detection_results: list[DetectionResult] = []

    for d in raw_detections:
        # --- 6a. 物体位置の推定 ---
        if can_estimate_position:
            try:
                estimate = estimate_object_position(
                    user_lat=final_lat,
                    user_lng=final_lng,
                    bearing_deg=final_bearing,
                    bbox_x1=d["bbox"][0],
                    bbox_y1=d["bbox"][1],
                    bbox_x2=d["bbox"][2],
                    bbox_y2=d["bbox"][3],
                    image_width=img_width,
                    image_height=img_height,
                    focal_length_px=focal_length_px,
                    object_label=d["label"],
                )
                obj_lat = estimate.lat
                obj_lng = estimate.lng
                obj_distance = estimate.horizontal_distance_m
                accuracy = "high"
            except (ValueError, ZeroDivisionError) as e:
                logger.warning("Position estimation failed for '%s': %s. Falling back.", d["label"], e)
                obj_lat = final_lat
                obj_lng = final_lng
                obj_distance = None
                accuracy = "low"
        else:
            # 方位角または焦点距離が不明 → 撮影者位置をフォールバックとして使用
            obj_lat = final_lat
            obj_lng = final_lng
            obj_distance = None
            accuracy = "low"

        # PostGIS 用の WKT 形式（経度, 緯度の順）
        obj_geom = f"SRID=4326;POINT({obj_lng} {obj_lat})"

        # --- 6b. detections テーブルへ保存 ---
        db_detection = Detection(
            user_id=current_user.id if current_user else None,
            label=d["label"],
            confidence=d["confidence"],
            image_path=None,       # 将来的にストレージ保存パスを設定
            geom=obj_geom,
            position_accuracy=accuracy,
            estimated_distance_m=obj_distance,
        )
        db.add(db_detection)
        db.flush()  # id を生成するために flush する

        # --- 6c. safety_points テーブルへ保存 (重複排除ロジックの適用) ---
        score_modifier = SCORE_MODIFIERS.get(d["label"].lower(), DEFAULT_SCORE_MODIFIER)

        # 5m以内に同じlabelの既存の SafetyPoint があるかを検索 (SRID 3857に変換して距離判定)
        # 注意: 今リクエストで追加したばかりの detection（flush済み・未コミット）は
        #       自分自身を重複と誤判定しないよう、detection_id の除外条件を加える
        new_geom_3857 = geofunc.ST_Transform(geofunc.ST_GeomFromText(f"POINT({obj_lng} {obj_lat})", 4326), 3857)
        existing_sp = db.query(SafetyPoint).join(
            Detection, SafetyPoint.detection_id == Detection.id
        ).filter(
            SafetyPoint.source_type == "detections",
            Detection.label.ilike(d["label"]),
            Detection.id != db_detection.id,  # 今追加した自分自身を除外
            geofunc.ST_DWithin(
                geofunc.ST_Transform(SafetyPoint.geom, 3857),
                new_geom_3857,
                5.0  # 5メートル以内
            )
        ).first()

        if existing_sp:
            # 重複がある場合：新規作成はせず、最新の検出結果へリンクを更新し、最終更新日時を更新する
            # また、座標を最新の推定位置に更新する
            logger.info("Duplicate safety point found for label '%s'. Updating existing point.", d["label"])
            existing_sp.detection_id = db_detection.id
            existing_sp.updated_at = datetime.utcnow()
            existing_sp.geom = obj_geom
        else:
            # 重複がない場合：新規に作成する
            db_safety_point = SafetyPoint(
                source_type="detections",
                detection_id=db_detection.id,
                score_modifier=score_modifier,
                influence_radius_m=INFLUENCE_RADIUS_M,
                is_road_attribute=True,
                geom=obj_geom,
                is_visible=True,
                updated_at=datetime.utcnow()
            )
            db.add(db_safety_point)

        # ※カバレッジセルの計算および反映は detections テーブルの PostGIS トリガーが自動執行



        detection_results.append(
            DetectionResult(
                label=d["label"],
                confidence=d["confidence"],
                bbox=d["bbox"],
                object_lat=obj_lat,
                object_lng=obj_lng,
                estimated_distance_m=obj_distance,
                position_accuracy=accuracy,
                score_modifier=score_modifier,
            )
        )

    # ----------------------------------------------------------------
    # 7. ユーザーへのリワード付与とコミット
    # ----------------------------------------------------------------
    earned_coins = 0
    if current_user:
        earned_coins = 10
        current_user.coins += earned_coins
        db.add(CoinTransaction(
            user_id=current_user.id,
            amount=earned_coins,
            reason="画像投稿リワード",
            created_at=datetime.utcnow()
        ))
    
    db.commit()

    # ----------------------------------------------------------------
    # 8. 精度が高い検出結果について、周辺 edges のスコアを更新する
    #    edges テーブルが空の場合は更新なし（OSM インポート後に有効になる）
    #    ここは独立したトランザクションとして実行し、失敗しても
    #    上の detection/safety_points の保存には影響しない。
    # ----------------------------------------------------------------
    for result in detection_results:
        if result.position_accuracy == "high":
            try:
                updated = update_edge_scores_near_point(db, result.object_lng, result.object_lat)
                if updated > 0:
                    logger.info("Updated %d edges near detected '%s'", updated, result.label)
                db.commit()
            except Exception as e:
                # edges テーブルが空・未作成などの理由でエラーが起きても処理を継続する。
                # ただし PostgreSQL はエラー後にトランザクションをアボートするため、
                # 必ず rollback して次のクエリが実行できる状態に戻す。
                logger.warning("Edge score update skipped: %s", e)
                db.rollback()

    # ----------------------------------------------------------------
    # 9. レスポンスを返す
    #    updated_score は暫定の計算値（将来的には当該エリアの edge スコアを集計する）
    # ----------------------------------------------------------------
    base_score = 0.5
    positive_detections = sum(1 for r in detection_results if r.score_modifier > 0)
    updated_score = min(1.0, base_score + positive_detections * 0.1)

    return AnalyzeResponse(
        detections=detection_results,
        user_lat=final_lat,
        user_lng=final_lng,
        updated_score=updated_score,
        earned_coins=earned_coins,
    )
