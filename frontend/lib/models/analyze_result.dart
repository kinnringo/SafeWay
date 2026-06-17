// SafeWay 画像解析 API レスポンスのデータモデル
// バックエンド仕様書 (docs/frontend_analyze_api_spec.md) に準拠。
// bbox はピクセル座標 [x1, y1, x2, y2] のリスト形式。

class BoundingBox {
  /// 画像内のピクセル座標 [x1, y1, x2, y2]
  final double x1;
  final double y1;
  final double x2;
  final double y2;

  const BoundingBox({
    required this.x1,
    required this.y1,
    required this.x2,
    required this.y2,
  });

  factory BoundingBox.fromJson(List<dynamic> json) {
    return BoundingBox(
      x1: (json[0] as num).toDouble(),
      y1: (json[1] as num).toDouble(),
      x2: (json[2] as num).toDouble(),
      y2: (json[3] as num).toDouble(),
    );
  }
}

class Detection {
  /// 検出ラベル（例: "streetlight", "obstacle"）
  final String label;

  /// YOLO の信頼度 (0〜1)
  final double confidence;

  /// 画像内バウンディングボックス [x1, y1, x2, y2]（ピクセル座標）
  final BoundingBox bbox;

  /// 推定したオブジェクトの緯度
  final double objectLat;

  /// 推定したオブジェクトの経度
  final double objectLng;

  /// 推定した水平距離（m）。position_accuracy が "low" の場合は null
  final double? estimatedDistanceM;

  /// 位置推定精度: "high" または "low"
  final String positionAccuracy;

  /// 道路安全スコアへの影響値（正=安全性向上, 負=安全性低下）
  final double scoreModifier;

  const Detection({
    required this.label,
    required this.confidence,
    required this.bbox,
    required this.objectLat,
    required this.objectLng,
    this.estimatedDistanceM,
    required this.positionAccuracy,
    required this.scoreModifier,
  });

  factory Detection.fromJson(Map<String, dynamic> json) {
    return Detection(
      label: json['label'] as String? ?? 'unknown',
      confidence: (json['confidence'] as num?)?.toDouble() ?? 0.0,
      bbox: BoundingBox.fromJson(json['bbox'] as List<dynamic>),
      objectLat: (json['object_lat'] as num?)?.toDouble() ?? 0.0,
      objectLng: (json['object_lng'] as num?)?.toDouble() ?? 0.0,
      estimatedDistanceM: (json['estimated_distance_m'] as num?)?.toDouble(),
      positionAccuracy: json['position_accuracy'] as String? ?? 'low',
      scoreModifier: (json['score_modifier'] as num?)?.toDouble() ?? 0.0,
    );
  }
}

class AnalyzeResponse {
  /// 撮影者の緯度（Form または EXIF から取得）
  final double userLat;

  /// 撮影者の経度（Form または EXIF から取得）
  final double userLng;

  /// 暫定の安全スコア更新値（参考値, 0〜1）
  final double updatedScore;

  /// 検出された各オブジェクトのリスト
  final List<Detection> detections;

  const AnalyzeResponse({
    required this.userLat,
    required this.userLng,
    required this.updatedScore,
    required this.detections,
  });

  factory AnalyzeResponse.fromJson(Map<String, dynamic> json) {
    final list = json['detections'] as List<dynamic>? ?? [];
    return AnalyzeResponse(
      userLat: (json['user_lat'] as num?)?.toDouble() ?? 0.0,
      userLng: (json['user_lng'] as num?)?.toDouble() ?? 0.0,
      updatedScore: (json['updated_score'] as num?)?.toDouble() ?? 0.5,
      detections: list
          .map((e) => Detection.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }
}
