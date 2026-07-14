Viewed api_specification.md:156-193

フロントエンドにおける「経路探索（ルーティング）表示機能」の実装に向けて、既存の `POST /api/route` API 仕様に準拠した**「フロントエンド専用 経路探索・描画 設計書」**を作成しました。

この設計書は、バックエンド側の実装やデータ構造（GeoJSON）、地図ライセンス設計指針の内容を忠実に反映した、実用的な設計となっています。

---

# 🗺️ フロントエンド専用 経路探索・描画 設計書 (仕様書)

## 1. GeoJSONパース & データ構造の設計

バックエンドの `POST /api/route` から返されるレスポンスをパースし、Flutter側で利用しやすいオブジェクトにマッピングするためのデータ構造モデルです。

### 1.1 モデルクラス設計 (`route_models.dart`)

GeoJSON の座標仕様 `[lng, lat]` を、Google Maps Flutter プラグインが解釈できる `LatLng(lat, lng)` に正しく反転・変換するロジックをクラス内に実装します。

```dart
import 'package:google_maps_flutter/google_maps_flutter.dart';

/// ルーティングレスポンスのルートモデル
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
      safeRoute: RouteInfo.fromJson(json['safe_route'] as Map<String, dynamic>),
      shortestRoute: RouteInfo.fromJson(json['shortest_route'] as Map<String, dynamic>),
      nearbyHazards: (json['nearby_hazards'] as List<dynamic>?)
              ?.map((e) => HazardPoint.fromJson(e as Map<String, dynamic>))
              .toList() ?? [],
    );
  }
}

/// 各ルートの詳細情報
class RouteInfo {
  final double distanceM;
  final double safetyScore;
  final List<RouteFeature> features; // GeoJSONのLineString群

  RouteInfo({
    required this.distanceM,
    required this.safetyScore,
    required this.features,
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

  /// 全ての区間の座標を一本に結合した緯度経度リストを取得する
  List<LatLng> get allPoints {
    final List<LatLng> points = [];
    for (var feature in features) {
      points.addAll(feature.points);
    }
    return points;
  }
}

/// GeoJSON の各 Feature (道路の1区間)
class RouteFeature {
  final List<LatLng> points;
  final double safetyScore;

  RouteFeature({
    required this.points,
    required this.safetyScore,
  });

  factory RouteFeature.fromJson(Map<String, dynamic> json) {
    final geometry = json['geometry'] as Map<String, dynamic>? ?? {};
    final coordinates = geometry['coordinates'] as List<dynamic>? ?? [];
    final properties = json['properties'] as Map<String, dynamic>? ?? {};

    // [lng, lat] から LatLng(lat, lng) への反転マッピング処理
    final List<LatLng> mappedPoints = coordinates.map((coord) {
      final double lng = (coord[0] as num).toDouble();
      final double lat = (coord[1] as num).toDouble();
      return LatLng(lat, lng);
    }).toList();

    return RouteFeature(
      points: mappedPoints,
      safetyScore: (properties['safety_score'] as num?)?.toDouble() ?? 0.5,
    );
  }
}

/// 沿道のハザードポイント情報
class HazardPoint {
  final int id;
  final double lat;
  final double lng;
  final String sourceType;
  final double scoreModifier;
  final String? label;

  HazardPoint({
    required this.id,
    required this.lat,
    required this.lng,
    required this.sourceType,
    required this.scoreModifier,
    this.label,
  });

  factory HazardPoint.fromJson(Map<String, dynamic> json) {
    return HazardPoint(
      id: json['id'] as int? ?? 0,
      lat: (json['lat'] as num?)?.toDouble() ?? 0.0,
      lng: (json['lng'] as num?)?.toDouble() ?? 0.0,
      sourceType: json['source_type'] as String? ?? '',
      scoreModifier: (json['score_modifier'] as num?)?.toDouble() ?? 0.0,
      label: json['label'] as String?,
    );
  }
}
```

---

## 2. Polyline（ルート線）の描き分けと状態管理設計

地図ライセンス設計指針やUX上の要件（並列表示時の視認性）に基づき、Google Map上のルート線を視覚的に描き分けます。

### 2.1 UI/デザイン設計
2本のルートを重ねて表示するため、色・太さ・描画優先度（Z-index）に明確なコントラストを設けます。

| ルート種別 | 線の色 | 太さ (`width`) | Z-Index | パターン |
|---|---|---|---|---|
| **安全優先ルート** | 緑系 (`Colors.emerald`/`0xFF2ECC71`) | 6 | 10 (上位) | 実線 |
| **最短距離ルート** | 青系 (`Colors.blue`/`0xFF3498DB`) | 4 | 5 (下位) | 実線 |

### 2.2 `map_screen.dart` 上の状態管理実装設計

```dart
// _MapScreenState クラス内の実装イメージ

Set<Polyline> _polylines = {};
RouteResponse? _currentRouteResponse;

/// ルート探索結果を Polyline セットに変換する処理
void _updateRoutePolylines(RouteResponse response) {
  final Set<Polyline> newPolylines = {};

  // 1. 安全優先ルートの描画 (緑線)
  newPolylines.add(
    Polyline(
      polylineId: const PolylineId('safe_route'),
      points: response.safeRoute.allPoints,
      color: const Color(0xFF2ECC71), // エメラルドグリーン
      width: 6,
      zIndex: 10,
      startCap: Cap.roundCap,
      endCap: Cap.roundCap,
    ),
  );

  // 2. 最短距離ルートの描画 (青線)
  newPolylines.add(
    Polyline(
      polylineId: const PolylineId('shortest_route'),
      points: response.shortestRoute.allPoints,
      color: const Color(0xFF3498DB), // スカイブルー
      width: 4,
      zIndex: 5,
      startCap: Cap.roundCap,
      endCap: Cap.roundCap,
    ),
  );

  setState(() {
    _currentRouteResponse = response;
    _polylines = newPolylines;
  });
}
```

---

## 3. カメラの自動フィット制御設計

ルート全体が画面内に綺麗に収まり、出発地と目的地のピンが切れないように、`LatLngBounds` を計算してカメラの表示範囲を自動調整します。

```dart
/// ルート全体が画面に収まるようにカメラを移動させる
Future<void> _fitRouteBounds(RouteResponse response) async {
  if (widget.mapController == null) return;

  final allPoints = [
    ...response.safeRoute.allPoints,
    ...response.shortestRoute.allPoints,
  ];
  if (allPoints.isEmpty) return;

  // 境界ボックス (LatLngBounds) を算出
  double minLat = allPoints.first.latitude;
  double minLng = allPoints.first.longitude;
  double maxLat = allPoints.first.latitude;
  double maxLng = allPoints.first.longitude;

  for (var point in allPoints) {
    if (point.latitude < minLat) minLat = point.latitude;
    if (point.latitude > maxLat) maxLat = point.latitude;
    if (point.longitude < minLng) minLng = point.longitude;
    if (point.longitude > maxLng) maxLng = point.longitude;
  }

  final bounds = LatLngBounds(
    southwest: LatLng(minLat, minLng),
    northeast: LatLng(maxLat, maxLng),
  );

  // マップ外周に十分な余白 (padding) を持たせてフィットさせる
  await widget.mapController!.animateCamera(
    CameraUpdate.newLatLngBounds(bounds, 80.0), // 80pxのパディング
  );
}
```

---

## 4. ルート比較UI & 帰属表示の設計

画面下部に、2つのルートの指標（距離・安全度）をカード形式で比較できるようにするUI案です。

```
+-------------------------------------------------------------+
| 🧭 ルート比較                                              |
|                                                             |
| 🟢 [安全ルート優先]        🔵 [最短ルート優先]              |
|  ・安全スコア: 0.92        ・安全スコア: 0.50               |
|  ・距離: 1.2 km            ・距離: 0.9 km                   |
|                                                             |
| ----------------------------------------------------------- |
| ℹ️ 経路情報: OpenStreetMap                                 |
+-------------------------------------------------------------+
```

### 4.1 UI実装設計例（Widgetツリー構成）
```dart
Widget _buildRouteCompareCard() {
  if (_currentRouteResponse == null) return const SizedBox.shrink();

  final safe = _currentRouteResponse!.safeRoute;
  final shortest = _currentRouteResponse!.shortestRoute;

  return Positioned(
    bottom: 24,
    left: 12,
    right: 12,
    child: Card(
      elevation: 6,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                // 安全優先ルートの情報
                _buildRouteInfoColumn(
                  title: '安全優先ルート',
                  color: const Color(0xFF2ECC71),
                  distance: safe.distanceM,
                  score: safe.safetyScore,
                ),
                const VerticalDivider(width: 20, thickness: 1),
                // 最短ルートの情報
                _buildRouteInfoColumn(
                  title: '最短距離ルート',
                  color: const Color(0xFF3498DB),
                  distance: shortest.distanceM,
                  score: shortest.safetyScore,
                ),
              ],
            ),
            const Divider(height: 24),
            // ★ライセンス指針 2.3 に基づく帰属表記
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.info_outline, size: 12, color: Colors.grey.shade600),
                const SizedBox(width: 4),
                Text(
                  '経路データ提供: OpenStreetMap コントリビューター',
                  style: TextStyle(fontSize: 10, color: Colors.grey.shade600),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
}

Widget _buildRouteInfoColumn({
  required String title,
  required Color color,
  required double distance,
  required double score,
}) {
  return Column(
    children: [
      Row(
        children: [
          Container(width: 8, height: 8, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
          const SizedBox(width: 6),
          Text(title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
        ],
      ),
      const SizedBox(height: 8),
      Text('${(distance / 1000).toStringAsFixed(1)} km', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
      const SizedBox(height: 2),
      Text('安全スコア: ${(score * 100).toStringAsFixed(0)}%', style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
    ],
  );
}
```