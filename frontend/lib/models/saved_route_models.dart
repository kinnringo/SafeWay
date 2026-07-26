/// 保存ルートのモデル
/// POST /api/saved-routes のリクエスト・GET レスポンスに対応
class SavedRoute {
  final int id;
  final int userId;
  final double startLat;
  final double startLng;
  final double endLat;
  final double endLng;
  final String routeType; // "safe" or "shortest"
  final double notificationRadiusM;
  final String? name;
  final String createdAt;

  SavedRoute({
    required this.id,
    required this.userId,
    required this.startLat,
    required this.startLng,
    required this.endLat,
    required this.endLng,
    required this.routeType,
    required this.notificationRadiusM,
    this.name,
    required this.createdAt,
  });

  factory SavedRoute.fromJson(Map<String, dynamic> json) {
    return SavedRoute(
      id: json['id'] as int,
      userId: json['user_id'] as int,
      startLat: (json['start_lat'] as num).toDouble(),
      startLng: (json['start_lng'] as num).toDouble(),
      endLat: (json['end_lat'] as num).toDouble(),
      endLng: (json['end_lng'] as num).toDouble(),
      routeType: json['route_type'] as String? ?? 'safe',
      notificationRadiusM: (json['notification_radius_m'] as num?)?.toDouble() ?? 500.0,
      name: json['name'] as String?,
      createdAt: json['created_at'] as String? ?? '',
    );
  }

  Map<String, dynamic> toJson() => {
        'start_lat': startLat,
        'start_lng': startLng,
        'end_lat': endLat,
        'end_lng': endLng,
        'route_type': routeType,
        'notification_radius_m': notificationRadiusM,
        if (name != null) 'name': name,
      };
}

/// 保存ルート沿いの危険情報アラートモデル
/// GET /api/saved-routes/alerts のレスポンスに対応
class RouteAlert {
  final int id;
  final int savedRouteId;
  final int crimeReportId;
  final String eventType;
  final String? description;
  final double reportLat;
  final double reportLng;
  final String occurredAt;
  final String createdAt;

  RouteAlert({
    required this.id,
    required this.savedRouteId,
    required this.crimeReportId,
    required this.eventType,
    this.description,
    required this.reportLat,
    required this.reportLng,
    required this.occurredAt,
    required this.createdAt,
  });

  factory RouteAlert.fromJson(Map<String, dynamic> json) {
    return RouteAlert(
      id: json['id'] as int,
      savedRouteId: json['saved_route_id'] as int,
      crimeReportId: json['crime_report_id'] as int,
      eventType: json['event_type'] as String? ?? 'unknown',
      description: json['description'] as String?,
      reportLat: (json['report_lat'] as num).toDouble(),
      reportLng: (json['report_lng'] as num).toDouble(),
      occurredAt: json['occurred_at'] as String? ?? '',
      createdAt: json['created_at'] as String? ?? '',
    );
  }
}
