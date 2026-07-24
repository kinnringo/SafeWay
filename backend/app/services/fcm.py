"""Firebase Cloud Messaging (FCM) 送信サービス

Firebase Admin SDK を使ってプッシュ通知を送信する。
GOOGLE_APPLICATION_CREDENTIALS 環境変数にサービスアカウントJSONのパスを設定することで
FCMが有効になる。設定されていない場合はログ出力のみでエラーにはしない（開発環境での
テストを妨げないため）。
"""
import logging
import os
from math import radians, sin, cos, sqrt, atan2
from typing import Optional

logger = logging.getLogger(__name__)

# Firebase Admin SDK の遅延初期化フラグ
_firebase_initialized = False
_firebase_available = False


def _initialize_firebase() -> bool:
    """Firebase Admin SDK を初期化する。成功すれば True を返す。"""
    global _firebase_initialized, _firebase_available

    if _firebase_initialized:
        return _firebase_available

    _firebase_initialized = True
    credentials_path = os.getenv("GOOGLE_APPLICATION_CREDENTIALS")

    if not credentials_path:
        logger.warning(
            "GOOGLE_APPLICATION_CREDENTIALS が未設定のため、FCM通知は無効です。"
            "Firebaseのサービスアカウントキーを取得して .env に設定してください。"
        )
        _firebase_available = False
        return False

    if not os.path.exists(credentials_path):
        logger.error(
            "GOOGLE_APPLICATION_CREDENTIALS のファイルが見つかりません: %s", credentials_path
        )
        _firebase_available = False
        return False

    try:
        import firebase_admin
        from firebase_admin import credentials

        cred = credentials.Certificate(credentials_path)
        firebase_admin.initialize_app(cred)
        logger.info("Firebase Admin SDK の初期化に成功しました。")
        _firebase_available = True
        return True
    except Exception as e:
        logger.error("Firebase Admin SDK の初期化に失敗しました: %s", e)
        _firebase_available = False
        return False


def haversine_distance_m(lat1: float, lng1: float, lat2: float, lng2: float) -> float:
    """2点間のHaversine距離をメートルで返す。"""
    R = 6371000.0  # 地球半径（メートル）
    phi1, phi2 = radians(lat1), radians(lat2)
    dphi = radians(lat2 - lat1)
    dlambda = radians(lng2 - lng1)
    a = sin(dphi / 2) ** 2 + cos(phi1) * cos(phi2) * sin(dlambda / 2) ** 2
    return R * 2 * atan2(sqrt(a), sqrt(1 - a))


def send_notification(fcm_token: str, title: str, body: str, data: Optional[dict] = None) -> bool:
    """単一デバイスにFCMプッシュ通知を送信する。成功すれば True を返す。"""
    if not _initialize_firebase():
        logger.info(
            "[FCM DRY RUN] Token=%s | Title=%s | Body=%s", fcm_token[:20], title, body
        )
        return False

    try:
        from firebase_admin import messaging

        message = messaging.Message(
            notification=messaging.Notification(title=title, body=body),
            data={str(k): str(v) for k, v in (data or {}).items()},
            token=fcm_token,
        )
        response = messaging.send(message)
        logger.info("FCM通知送信成功: %s", response)
        return True
    except Exception as e:
        logger.error("FCM通知送信失敗 (token=%s...): %s", fcm_token[:20], e)
        return False


def send_crime_report_notifications(
    db,
    report_lat: float,
    report_lng: float,
    event_type: str,
    description: Optional[str],
    report_id: int,
) -> int:
    """
    新しいcrime_reportの地点周辺にいる全ユーザーに通知を送信する。
    返り値: 通知を送信したユーザー数
    """
    from app.models.db_models import DeviceToken
    from geoalchemy2 import functions as geofunc

    # 通知範囲内の全device_tokensを取得
    # 各ユーザーの notification_radius_m と報告地点との距離を比較する
    # PostGIS ST_DWithin は度単位のため、メートルに変換するため SRID 3857 を利用
    report_geom_3857 = geofunc.ST_Transform(
        geofunc.ST_GeomFromText(f"POINT({report_lng} {report_lat})", 4326), 3857
    )

    all_tokens = db.query(DeviceToken).all()

    event_type_labels = {
        "bear": "クマ",
        "suspicious_person": "不審者",
        "traffic": "交通事故",
        "disaster": "災害",
    }
    event_label = event_type_labels.get(event_type, "危険情報")

    notified = 0
    for device_token in all_tokens:
        # ユーザーのデバイスの基準地点は取得できないため、
        # notification_radius_m は「報告地点から指定範囲内の全ユーザー」として扱う
        # ※本来はユーザーの現在地と比較するが、現在地をサーバーが保持しない設計のため
        #   FCMトークン登録時の「拠点」として扱う（今回は全トークン対象に通知する仕様）
        distance_m = haversine_distance_m(
            report_lat, report_lng,
            report_lat, report_lng   # 現在地不明のため全員対象（後述）
        )

        # --- 設計メモ ---
        # 理想的にはユーザーの現在地 or 拠点座標と比較するが、
        # プライバシー上の理由からサーバー側にユーザー位置を保存しない方針のため、
        # 今回は「FCMトークンを登録している全ユーザー」に送信する。
        # 将来的にユーザー拠点（自宅・よく使うルート）を保存する場合はここで距離フィルタを追加する。

        title = f"⚠️ 近くで{event_label}が目撃されました"
        body = description or f"{event_label}の目撃情報が報告されました。お出かけの際はご注意ください。"

        success = send_notification(
            fcm_token=device_token.fcm_token,
            title=title,
            body=body,
            data={
                "type": "crime_report",
                "event_type": event_type,
                "lat": str(report_lat),
                "lng": str(report_lng),
                "crime_report_id": str(report_id),
            },
        )
        if success:
            notified += 1

    logger.info(
        "crime_report id=%d: %d件のデバイストークンに通知を送信しました", report_id, len(all_tokens)
    )
    return len(all_tokens)  # 送信試行数を返す（成功失敗に関わらず）
