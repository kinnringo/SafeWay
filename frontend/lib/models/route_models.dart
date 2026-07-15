import 'package:google_maps_flutter/google_maps_flutter.dart';

/// POST /api/route のレスポンス全体
class RouteResponse {
  final RouteInfo safeRoute;
  final RouteInfo shortestRoute;
  final List<HazardPoint> nearbyHazards;

  RouteResponse({
    required this.safeRoute,
    required this.shortestRoute,
    required this.nearbyHazards,
  });

  factory RouteResponse.fromJson(Map<String, dynamic> json) {
    return RouteResponse(
      safeRoute:
          RouteInfo.fromJson(json['safe_route'] as Map<String, dynamic>),
      shortestRoute:
          RouteInfo.fromJson(json['shortest_route'] as Map<String, dynamic>),
      nearbyHazards: (json['nearby_hazards'] as List<dynamic>? ?? [])
          .map((e) => HazardPoint.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }
}

/// ルート全体の情報（safe_route / shortest_route 共通）
class RouteInfo {
  /// GeoJSON FeatureCollection 内の道路区間ごとの Feature リスト
  final List<RouteFeature> features;

  /// ルートの総距離（メートル）
  final double distanceM;

  /// ルート全体の安全スコア（エッジ長加重平均, 0.01〜1.0）
  final double safetyScore;

  RouteInfo({
    required this.features,
    required this.distanceM,
    required this.safetyScore,
  });

  factory RouteInfo.fromJson(Map<String, dynamic> json) {
    final routeGeoJson = json['route'] as Map<String, dynamic>? ?? {};
    final featuresList = routeGeoJson['features'] as List<dynamic>? ?? [];

    return RouteInfo(
      distanceM: (json['distance_m'] as num?)?.toDouble() ?? 0.0,
      safetyScore: (json['safety_score'] as num?)?.toDouble() ?? 0.5,
      features: featuresList
          .map((e) => RouteFeature.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }

  /// 全区間の座標を一本に結合した LatLng リストを返す（最短ルート描画用）
  List<LatLng> get allPoints {
    final List<LatLng> points = [];
    for (final feature in features) {
      points.addAll(feature.points);
    }
    return points;
  }
}

/// GeoJSON の各 Feature（1道路区間 = 1エッジ）
class RouteFeature {
  /// 区間の座標列（GeoJSON の [lng, lat] を LatLng(lat, lng) に変換済み）
  final List<LatLng> points;

  /// この区間の安全スコア（0.01〜1.0）
  final double safetyScore;

  RouteFeature({
    required this.points,
    required this.safetyScore,
  });

  factory RouteFeature.fromJson(Map<String, dynamic> json) {
    final geometry = json['geometry'] as Map<String, dynamic>? ?? {};
    final coordinates = geometry['coordinates'] as List<dynamic>? ?? [];
    final properties = json['properties'] as Map<String, dynamic>? ?? {};

    // GeoJSON 座標は [lng, lat] 順のため、LatLng(lat, lng) に反転してマッピング
    final List<LatLng> mappedPoints = coordinates.map((coord) {
      final c = coord as List<dynamic>;
      final double lng = (c[0] as num).toDouble();
      final double lat = (c[1] as num).toDouble();
      return LatLng(lat, lng);
    }).toList();

    return RouteFeature(
      points: mappedPoints,
      safetyScore: (properties['safety_score'] as num?)?.toDouble() ?? 0.5,
    );
  }
}

/// ルート沿い 100m 以内のエリア型ハザードポイント
class HazardPoint {
  final int id;
  final double lat;
  final double lng;
  final String sourceType;
  final double scoreModifier;
  final String? label;
  final double? confidence;
  final String updatedAt;

  HazardPoint({
    required this.id,
    required this.lat,
    required this.lng,
    required this.sourceType,
    required this.scoreModifier,
    this.label,
    this.confidence,
    required this.updatedAt,
  });

  factory HazardPoint.fromJson(Map<String, dynamic> json) {
    return HazardPoint(
      id: json['id'] as int? ?? 0,
      lat: (json['lat'] as num?)?.toDouble() ?? 0.0,
      lng: (json['lng'] as num?)?.toDouble() ?? 0.0,
      sourceType: json['source_type'] as String? ?? '',
      scoreModifier: (json['score_modifier'] as num?)?.toDouble() ?? 0.0,
      label: json['label'] as String?,
      confidence: (json['confidence'] as num?)?.toDouble(),
      updatedAt: json['updated_at'] as String? ?? '',
    );
  }
}
