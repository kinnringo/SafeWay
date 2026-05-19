"""YOLO 推論サービス

アップロードされた画像に対して YOLO v26 による物体検出を実行し、
街灯・歩道・路面状況等の検出結果を返すビジネスロジック。
"""

# TODO: YOLO モデルの読み込みと推論処理を実装


async def detect_objects(image_bytes: bytes) -> list[dict]:
    """画像バイト列を受け取り、検出結果のリストを返す。"""
    raise NotImplementedError("YOLO推論未実装")
