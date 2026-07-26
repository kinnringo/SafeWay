import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:geocoding/geocoding.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:pointer_interceptor/pointer_interceptor.dart';
import '../providers/image_provider.dart';
import '../providers/hazard_provider.dart';
import '../providers/coverage_provider.dart';
import '../providers/map_theme_provider.dart';
import '../core/theme.dart';
import '../core/map_styles.dart';
import '../widgets/image_preview_card.dart';
import '../widgets/action_buttons.dart';
import '../widgets/search_bar_widget.dart';
import '../widgets/post_bottom_sheet.dart';
import '../utils/marker_helper.dart';
import '../widgets/place_info_sheet.dart';
import '../widgets/origin_search_sheet.dart';
import '../models/route_models.dart';
import '../services/api_service.dart';

/// 選択中のルート種別
enum _RouteType { safe, shortest }

class MapScreen extends ConsumerStatefulWidget {
  const MapScreen({super.key});

  @override
  ConsumerState<MapScreen> createState() => _MapScreenState();
}

class _DetectedPoi {
  final LatLng latLng;
  final String placeId;
  _DetectedPoi({required this.latLng, required this.placeId});
}

class _MapScreenState extends ConsumerState<MapScreen> {
  GoogleMapController? _mapController;
  StreamSubscription<Position>? _positionStream;

  LatLng? _currentPosition;
  bool _isLoadingGps = true;
  bool _hasMovedToCurrentLocation = false;
  bool _isProcessingTap = false; // タップ連打・多重実行防止フラグ
  Timer? _mapTapDebounceTimer; // ダブルタップ誤爆防止用タイマー

  // 危険情報アラート ポーリング用
  int? _lastKnownReportId;
  Timer? _pollingTimer;

  // カスタムピン用
  LatLng? _customPinLocation;
  String? _customPinAddress;

  /// 地図上に立っているマーカー（目的地ピン等）
  Set<Marker> _markers = {};

  bool _isSatelliteMode = false; // 航空写真モードのトグル

  /// ハザード情報表示用のマーカー
  Set<Marker> _hazardMarkers = {};
  BitmapDescriptor? _bearMarkerSmall;
  BitmapDescriptor? _bearMarkerMedium;
  BitmapDescriptor? _bearMarkerLarge;

  /// ルート描画用のポリラインセット
  Set<Polyline> _polylines = {};

  /// 現在表示中のルートデータ（比較カード・ナビ用）
  RouteResponse? _currentRouteResponse;

  /// ルート探索中フラグ
  bool _isLoadingRoute = false;

  /// サジェストリストが表示中の場合 true（地図タップを無効化する）
  bool _isSuggestionsVisible = false;

  /// 選択中のルート種別（比較カードでユーザーが選択）
  _RouteType? _selectedRouteType;

  /// ナビ案内中フラグ
  bool _isNavigating = false;

  // ─────────────────────────────────────────────────────────────────────
  // ルート出発地（Origin）任意設定用状態
  // ─────────────────────────────────────────────────────────────────────
  bool _isRoutePlanning = false;
  LatLng? _originLocation;
  String? _originName;
  LatLng? _destinationLocation;
  String? _destinationName;

  /// ボトムシートが現在表示中かどうかを示すフラグ
  ///
  /// onTap での安全な Navigator.pop を実現するために使用する。
  /// ボトムシートが表示されていない状態で誤って地図画面自体がポップしないよう防衛する。
  bool _isPlaceSheetOpen = false;

  /// 現在のカメラズームレベル（14.5以上で wildlife マーカーを非表示にする）
  double _currentZoom = 14.0;

  static const LatLng _defaultCenter = LatLng(36.3895, 139.0634); // 前橋駅

  // ─────────────────────────────────────────────────────────────────────
  // ルートの色・描画ロジック
  // ─────────────────────────────────────────────────────────────────────

  /// 安全スコアから区間の色を返す
  Color _safetyScoreToColor(double score) {
    if (score >= 0.7) {
      return const Color(0xFF2ECC71); // 緑: 安全
    } else if (score >= 0.4) {
      return const Color(0xFFF39C12); // オレンジ: やや危険
    } else {
      return const Color(0xFFE74C3C); // 赤: 危険
    }
  }

  /// ルートのポリラインを生成して地図に反映する
  void _updateRoutePolylines(RouteResponse response) {
    _currentRouteResponse = response;
    _selectedRouteType = null; // 初期値は未選択（両方表示）
    _refreshPolylines();
  }

  /// 選択状態に応じてポリラインを再生成する
  void _refreshPolylines() {
    if (_currentRouteResponse == null) return;
    final response = _currentRouteResponse!;
    final Set<Polyline> newPolylines = {};

    // 1. 安全優先ルート
    if (_selectedRouteType == null || _selectedRouteType == _RouteType.safe) {
      for (var i = 0; i < response.safeRoute.features.length; i++) {
        final feature = response.safeRoute.features[i];
        if (feature.points.length < 2) continue;
        newPolylines.add(
          Polyline(
            polylineId: PolylineId('safe_route_segment_$i'),
            points: feature.points,
            color: _safetyScoreToColor(feature.safetyScore),
            width: 6,
            zIndex: 10,
            startCap: Cap.roundCap,
            endCap: Cap.roundCap,
            jointType: JointType.round,
          ),
        );
      }
    }

    // 2. 最短距離ルート
    if (_selectedRouteType == null || _selectedRouteType == _RouteType.shortest) {
      for (var i = 0; i < response.shortestRoute.features.length; i++) {
        final feature = response.shortestRoute.features[i];
        if (feature.points.length < 2) continue;
        newPolylines.add(
          Polyline(
            polylineId: PolylineId('shortest_route_segment_$i'),
            points: feature.points,
            // 未選択時（両方表示）は青の半透明で区別、単独表示時はスコア色
            color: _selectedRouteType == null
                ? Colors.blue.withValues(alpha: 0.7)
                : _safetyScoreToColor(feature.safetyScore),
            // 未選択時は少し細め
            width: _selectedRouteType == null ? 4 : 6,
            zIndex: _selectedRouteType == null ? 5 : 10,
            startCap: Cap.roundCap,
            endCap: Cap.roundCap,
            jointType: JointType.round,
          ),
        );
      }
    }

    setState(() {
      _polylines = newPolylines;
    });
  }

  // ─────────────────────────────────────────────────────────────────────
  // カメラ操作
  // ─────────────────────────────────────────────────────────────────────

  /// ルート全体が画面に収まるようにカメラをフィットする
  Future<void> _fitRouteBounds(RouteResponse response) async {
    if (_mapController == null) return;

    final allPoints = [
      ...response.safeRoute.allPoints,
      ...response.shortestRoute.allPoints,
    ];
    if (allPoints.isEmpty) return;

    double minLat = allPoints.first.latitude;
    double minLng = allPoints.first.longitude;
    double maxLat = allPoints.first.latitude;
    double maxLng = allPoints.first.longitude;

    for (final point in allPoints) {
      if (point.latitude < minLat) minLat = point.latitude;
      if (point.latitude > maxLat) maxLat = point.latitude;
      if (point.longitude < minLng) minLng = point.longitude;
      if (point.longitude > maxLng) maxLng = point.longitude;
    }

    final bounds = LatLngBounds(
      southwest: LatLng(minLat, minLng),
      northeast: LatLng(maxLat, maxLng),
    );

    await _mapController!.animateCamera(
      CameraUpdate.newLatLngBounds(bounds, 80.0),
    );
  }

  // ─────────────────────────────────────────────────────────────────────
  // ルート探索
  // ─────────────────────────────────────────────────────────────────────

  /// ルートボタンまたは外部からルート探索を実行するエントリポイント
  Future<void> fetchAndDrawRoute({
    required LatLng start,
    required LatLng end,
  }) async {
    if (_isLoadingRoute) return;
    setState(() => _isLoadingRoute = true);

    try {
      final apiService = ref.read(apiServiceProvider);
      final hazardRadius = ref.read(hazardProvider).routingRadius;
      
      final response = await apiService.fetchRoute(
        startLat: start.latitude,
        startLng: start.longitude,
        endLat: end.latitude,
        endLng: end.longitude,
        hazardRadiusM: hazardRadius,
      );
      
      _updateRoutePolylines(response);
      
      // ハザードマーカーの生成
      final newHazardMarkers = response.nearbyHazards.map(_createHazardMarker).whereType<Marker>().toSet();
      setState(() {
        _hazardMarkers = newHazardMarkers;
      });
      
      await _fitRouteBounds(response);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('ルート探索に失敗しました: $e'),
            backgroundColor: Colors.red.shade700,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoadingRoute = false);
    }
  }

  /// ルートと関連状態をすべてクリアする
  void _clearRoute() {
    setState(() {
      _polylines = {};
      _currentRouteResponse = null;
      _isNavigating = false;
      _isRoutePlanning = false;
      _originLocation = null;
      _originName = null;
      _destinationLocation = null;
      _destinationName = null;
      _markers = {};
      _hazardMarkers = {};
    });
  }

  // ─────────────────────────────────────────────────────────────────────
  // ナビ開始・終了
  // ─────────────────────────────────────────────────────────────────────

  /// 「案内を開始」ボタン押下時の処理
  void _startNavigation() {
    if (_currentPosition == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('現在地を取得中です。しばらくお待ちください。')),
      );
      return;
    }

    setState(() {
      if (_selectedRouteType == null) {
        _selectedRouteType = _RouteType.safe; // デフォルトは安全優先
        _refreshPolylines();
      }
      _isNavigating = true;
    });

    _mapController?.animateCamera(
      CameraUpdate.newLatLngZoom(_currentPosition!, 17.0),
    );
  }

  /// 「案内を終了」ボタン押下時の処理
  void _stopNavigation() {
    _clearRoute();
  }

  // ─────────────────────────────────────────────────────────────────────
  // スポット表示の共通ヘルパー
  // ─────────────────────────────────────────────────────────────────────

  /// POI タップ・長押しで呼ばれる、マーカー設置とボトムシート表示の共通処理。
  ///
  /// [point]   地図上の座標
  /// [placeId] POI タップ時のみ存在する Google Place ID
  ///
  /// マーカーには Web 互換性の高い `BitmapDescriptor.defaultMarker`（赤ピン）を使用する。
  void _showSpotDetails({required LatLng point, String? placeId}) {
    setState(() {
      _isPlaceSheetOpen = true;
      _markers = {
        Marker(
          markerId: MarkerId(placeId ?? 'selected_location'),
          position: point,
          // BitmapDescriptor.defaultMarker: Web / iOS / Android すべてで確実に動作する赤ピン
          icon: BitmapDescriptor.defaultMarker,
        ),
      };
    });

    showPlaceInfoSheet(
      context: context,
      tappedPoint: point,
      placeId: placeId,
      onRouteRequested: (LatLng destination, String destinationName) {
        // 1. 現在地チェック（出発地が未設定、かつGPSも未取得の場合のブロック）
        final effectiveStart = _originLocation ?? _currentPosition;
        if (effectiveStart == null) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('現在地が取得できていません。GPS を確認してください。'),
            ),
          );
          return;
        }

        // 2. 状態の更新（既存の出発地があれば維持する）
        setState(() {
          if (!_isRoutePlanning) {
            // 新規でルート検索を始める場合のみ、出発地をクリア（現在地）にする
            _originLocation = null;
            _originName = null;
          }
          _isRoutePlanning = true;
          _destinationLocation = destination;
          _destinationName = destinationName;
        });

        // 3. ルート再検索（維持された出発地、または現在地を使用）
        final startPoint = _originLocation ?? _currentPosition!;
        fetchAndDrawRoute(start: startPoint, end: destination);
      },
    ).then((_) {
      Future.delayed(const Duration(milliseconds: 300), () {
        if (mounted) {
          setState(() {
            _isPlaceSheetOpen = false;
            // ナビ中でなければ、目的地マーカーをクリア
            if (!_isNavigating) {
              _markers = {};
            }
          });
        }
      });
    });
  }

  // ─────────────────────────────────────────────────────────────────────
  // ハザード情報関連
  // ─────────────────────────────────────────────────────────────────────

  Future<void> _onCameraIdle() async {
    // 既存のハザード情報再取得
    _fetchHazards();

    // カバレッジ情報の再取得
    final coverageState = ref.read(coverageProvider);
    if (coverageState.isVisible && _mapController != null) {
      final zoom = await _mapController!.getZoomLevel();
      if (zoom >= 8.0) {
        final bounds = await _mapController!.getVisibleRegion();
        ref.read(coverageProvider.notifier).fetchCoverage(
              minLat: bounds.southwest.latitude,
              minLng: bounds.southwest.longitude,
              maxLat: bounds.northeast.latitude,
              maxLng: bounds.northeast.longitude,
              zoom: zoom,
            );
      }
    }
  }

  Set<Polygon> _buildCoveragePolygons(CoverageState coverageState) {
    if (!coverageState.isVisible) return {};
    
    debugPrint('Coverage Cells to draw: ${coverageState.cells.length}');
    
    final Set<Polygon> polygons = {};
    final cellSize = coverageState.cellSize;
    
    // 1. 背景ポリゴン（地球全体を4分割）
    final bgColor = Colors.grey.withValues(alpha: 0.5);
    polygons.addAll([
      Polygon(
        polygonId: const PolygonId('coverage_bg_nw'),
        points: const [
          LatLng(89.9, -179.9),
          LatLng(89.9, 0),
          LatLng(0, 0),
          LatLng(0, -179.9),
        ],
        fillColor: bgColor,
        strokeWidth: 0,
        zIndex: 0,
      ),
      Polygon(
        polygonId: const PolygonId('coverage_bg_ne'),
        points: const [
          LatLng(89.9, 0),
          LatLng(89.9, 179.9),
          LatLng(0, 179.9),
          LatLng(0, 0),
        ],
        fillColor: bgColor,
        strokeWidth: 0,
        zIndex: 0,
      ),
      Polygon(
        polygonId: const PolygonId('coverage_bg_sw'),
        points: const [
          LatLng(0, -179.9),
          LatLng(0, 0),
          LatLng(-89.9, 0),
          LatLng(-89.9, -179.9),
        ],
        fillColor: bgColor,
        strokeWidth: 0,
        zIndex: 0,
      ),
      Polygon(
        polygonId: const PolygonId('coverage_bg_se'),
        points: const [
          LatLng(0, 0),
          LatLng(0, 179.9),
          LatLng(-89.9, 179.9),
          LatLng(-89.9, 0),
        ],
        fillColor: bgColor,
        strokeWidth: 0,
        zIndex: 0,
      ),
    ]);

    // 2. データセルポリゴン（緑色）
    for (int i = 0; i < coverageState.cells.length; i++) {
      final cell = coverageState.cells[i];
      final sw = LatLng(cell.lat, cell.lng);
      final nw = LatLng(cell.lat + cellSize, cell.lng);
      final ne = LatLng(cell.lat + cellSize, cell.lng + cellSize);
      final se = LatLng(cell.lat, cell.lng + cellSize);
      
      Color cellColor;
      if (cell.count <= 2) {
        cellColor = Colors.lightGreen.withValues(alpha: 0.4);
      } else if (cell.count <= 4) {
        cellColor = Colors.green.withValues(alpha: 0.6);
      } else {
        cellColor = Colors.green[800]!.withValues(alpha: 0.8);
      }
      
      polygons.add(
        Polygon(
          polygonId: PolygonId('coverage_cell_$i'),
          points: [sw, nw, ne, se],
          fillColor: cellColor,
          strokeWidth: 0,
          zIndex: 10,
        ),
      );
    }
    
    return polygons;
  }

  /// 周辺のハザード情報を取得してマーカーを更新
  Future<void> _fetchHazards() async {
    final hazardState = ref.read(hazardProvider);
    if (!hazardState.isVisible || _mapController == null) {
      if (_hazardMarkers.isNotEmpty) {
        setState(() => _hazardMarkers = {});
      }
      return;
    }

    try {
      final bounds = await _mapController!.getVisibleRegion();
      final apiService = ref.read(apiServiceProvider);
      final hazards = await apiService.getHazards(
        minLat: bounds.southwest.latitude,
        minLng: bounds.southwest.longitude,
        maxLat: bounds.northeast.latitude,
        maxLng: bounds.northeast.longitude,
      );

      // ズームが 14.5 以上の場合、野生動物（wildlife）マーカーを除外
      final filteredHazards = hazards.where((hazard) {
        final isWildlife = hazard.eventType == 'wildlife' || hazard.label == 'wildlife';
        return !(_currentZoom >= 14.5 && isWildlife);
      }).toList();

      final newHazardMarkers = filteredHazards.map(_createHazardMarker).whereType<Marker>().toSet();
      if (mounted) {
        setState(() {
          _hazardMarkers = newHazardMarkers;
        });
      }
    } catch (e) {
      debugPrint('ハザード取得エラー: $e');
    }
  }

  /// ハザード情報からマーカーを生成
  Marker? _createHazardMarker(HazardPoint hazard) {
    debugPrint('Hazard Info - eventType: ${hazard.eventType}, sourceType: ${hazard.sourceType}, label:${hazard.label}');
    
    final isBear = hazard.sourceType.toLowerCase() == 'bear' ||
                   hazard.eventType?.toLowerCase() == 'bear' ||
                   (hazard.label?.toLowerCase().contains('bear') ?? false) ||
                   (hazard.label?.contains('クマ') ?? false) ||
                   (hazard.label?.contains('熊') ?? false);

    if (isBear && _currentZoom >= 15.0) {
      return null;
    }

    BitmapDescriptor? bearIcon;
    if (isBear) {
      if (_currentZoom < 8.0) {
        bearIcon = _bearMarkerSmall;
      } else if (_currentZoom < 12.0) {
        bearIcon = _bearMarkerMedium;
      } else {
        bearIcon = _bearMarkerLarge;
      }
    }

    return Marker(
      markerId: MarkerId('hazard_${hazard.id}'),
      position: LatLng(hazard.lat, hazard.lng),
      icon: (isBear && bearIcon != null)
          ? bearIcon
          : BitmapDescriptor.defaultMarkerWithHue(
              isBear ? BitmapDescriptor.hueOrange : BitmapDescriptor.hueRed,
            ),
      onTap: () => _showHazardDetailsSheet(hazard),
    );
  }

  void _showHazardDetailsSheet(HazardPoint hazard) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return Consumer(
          builder: (context, ref, child) {
            final isDark = ref.watch(mapThemeProvider);
            final bgColor = isDark ? AppColors.darkSurface : Colors.white;
            final textColor = isDark ? AppColors.darkTextPrimary : Colors.black87;
            final subTextColor = isDark ? AppColors.darkTextSecondary : Colors.black54;

            return PointerInterceptor(
              child: Container(
                decoration: BoxDecoration(
                  color: bgColor,
                  borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
                ),
                child: SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.all(20.0),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(
                              hazard.eventType == 'wildlife' ? Icons.pets : Icons.warning_amber,
                              color: hazard.eventType == 'wildlife' ? Colors.orange : Colors.yellow.shade700,
                              size: 28,
                            ),
                            const SizedBox(width: 8),
                            Text(
                              hazard.label ?? '危険情報',
                              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: textColor),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        Text('種類: ${hazard.sourceType}', style: TextStyle(color: subTextColor)),
                        Text('更新日時: ${hazard.updatedAt}', style: TextStyle(color: subTextColor)),
                        if (hazard.confidence != null)
                          Text('信頼度: ${(hazard.confidence! * 100).toStringAsFixed(1)}%', style: TextStyle(color: subTextColor)),
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  void _showHazardSettingsDialog() {
    showDialog(
      context: context,
      builder: (context) {
        return Consumer(
          builder: (context, ref, child) {
            final hazardState = ref.watch(hazardProvider);
            final isDark = ref.watch(mapThemeProvider);
            final bgColor = isDark ? AppColors.darkSurface : Colors.white;
            final textColor = isDark ? AppColors.darkTextPrimary : Colors.black87;
            final subTextColor = isDark ? AppColors.darkTextSecondary : Colors.black54;

            return PointerInterceptor(
              child: AlertDialog(
                backgroundColor: bgColor,
                title: Text('ハザード表示設定', style: TextStyle(color: textColor)),
                content: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('通常時の検索半径: ${(hazardState.normalRadius / 1000).toStringAsFixed(1)} km', style: TextStyle(color: subTextColor)),
                    Slider(
                      value: hazardState.normalRadius,
                      min: 1000.0,
                      max: 50000.0,
                      divisions: 49,
                      activeColor: isDark ? AppColors.blueAccentLight : AppColors.primaryNavy,
                      onChanged: (val) => ref.read(hazardProvider.notifier).setNormalRadius(val),
                      onChangeEnd: (_) => _fetchHazards(),
                    ),
                    const SizedBox(height: 16),
                    Text('ルート時の検索半径: ${(hazardState.routingRadius / 1000).toStringAsFixed(1)} km', style: TextStyle(color: subTextColor)),
                    Slider(
                      value: hazardState.routingRadius,
                      min: 100.0,
                      max: 5000.0,
                      divisions: 49,
                      activeColor: isDark ? AppColors.blueAccentLight : AppColors.primaryNavy,
                      onChanged: (val) => ref.read(hazardProvider.notifier).setRoutingRadius(val),
                    ),
                  ],
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: Text('閉じる', style: TextStyle(color: isDark ? AppColors.blueAccentLight : AppColors.primaryNavy)),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  // ─────────────────────────────────────────────────────────────────────
  // 地図インタラクションハンドラ（本家 Google Map 準拠）
  // ─────────────────────────────────────────────────────────────────────

  /// 1. 通常タップ（自動 POI 判定）
  void _onMapTap(LatLng point) {
    if (_isSuggestionsVisible || _isNavigating) return;
    if (_isProcessingTap) return;
    if (_isPlaceSheetOpen) return; // ボトムシート表示中の背景タップ貫通防止

    // ダブルタップ等のカメラ移動でキャンセルできるようタイマーをセット
    _mapTapDebounceTimer?.cancel();
    _mapTapDebounceTimer = Timer(const Duration(milliseconds: 300), () async {
      if (!mounted) return;

      setState(() {
        _isProcessingTap = true;
      });

      try {
        // カスタムピン（長押しで立てたピン）があればクリアする
        if (_customPinLocation != null) {
          _customPinLocation = null;
          _customPinAddress = null;
        }

        // タップ地点周辺を Nearby Search で検索し、POI かどうかを判定
        final poi = await _findNearbyPoi(point);

        if (poi != null) {
          // ① 付近に POI（店舗・スポット）が見つかった場合
          _showSpotDetails(point: poi.latLng, placeId: poi.placeId);
        } else {
          // ② 付近に POI が見つからない場合（ただの道路や地面をタップ）
          if (!mounted) return;
          if (_markers.isNotEmpty) {
            setState(() => _markers = {});
          }
        }
      } finally {
        if (mounted) {
          setState(() {
            _isProcessingTap = false;
          });
        }
      }
    });
  }

  /// タップ座標周辺の POI を検索するヘルパー
  Future<_DetectedPoi?> _findNearbyPoi(LatLng point) async {
    final apiService = ref.read(apiServiceProvider);
    final result = await apiService.getNearbyPoi(
      lat: point.latitude,
      lng: point.longitude,
      radius: 30.0, // タップ地点から30m以内を検索
    );

    if (result != null) {
      return _DetectedPoi(
        latLng: LatLng(result['lat'] as double, result['lng'] as double), // 店舗の正確な座標
        placeId: result['placeId'] as String,
      );
    }
    
    return null;
  }

  /// 2. POI（店舗・スポットアイコン）タップ
  ///
  /// google_maps_flutter 2.17.x現在、フロント側の GoogleMap Widget に `onPoiTap` は公開されていない。
  /// 長押し（`onLongPress`）ハンドラのみで対応する（下記参照）。
  /// 将来的にパッケージが対応した場合に拡張する。

  /// 3. 長押し：指定した地点へのピン立て
  ///
  /// `onPoiTap` が現在の Google Maps SDK バージョンで公開されていないため、
  /// 長押しのみで山所情報の取得・表示を実現する。
  /// Web 環境でも確実に動作する。
  Future<void> _onLongPress(LatLng point) async {
    if (_isSuggestionsVisible || _isNavigating) return;
    if (_isProcessingTap) return;
    if (_isPlaceSheetOpen) return; // ボトムシート表示中の背景タップ貫通防止

    setState(() {
      _isProcessingTap = true;
    });

    try {
      String addressStr = '座標: ${point.latitude.toStringAsFixed(4)}, ${point.longitude.toStringAsFixed(4)}';
      try {
        final placemarks = await Geocoding().placemarkFromCoordinates(point.latitude, point.longitude);
        if (placemarks.isNotEmpty) {
          final p = placemarks.first;
          final admin = p.administrativeArea ?? '';
          final local = p.locality ?? '';
          final subLocal = p.subLocality ?? '';
          final thoroughfare = p.thoroughfare ?? '';
          final subThoroughfare = p.subThoroughfare ?? '';

          final address = '$admin$local$subLocal$thoroughfare$subThoroughfare';
          if (address.isNotEmpty) {
            addressStr = address;
          }
        }
      } catch (e) {
        debugPrint('Geocoding error: $e');
      }

      setState(() {
        _customPinLocation = point;
        _customPinAddress = addressStr; // 値をセット
        _isPlaceSheetOpen = true;

        _markers = {
          Marker(
            markerId: const MarkerId('custom_pin'),
            position: point,
            icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueAzure),
          ),
        };
      });

      _showCustomPinSheet(point); // addressStrではなく_customPinAddressを使用するよう変更
    } finally {
      if (mounted) {
        setState(() {
          _isProcessingTap = false;
        });
      }
    }
  }

  void _showCustomPinSheet(LatLng point) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return Consumer(
          builder: (context, ref, child) {
            final isDark = ref.watch(mapThemeProvider);
            final bgColor = isDark ? AppColors.darkSurface : Colors.white;
            final textColor = isDark ? AppColors.darkTextPrimary : AppColors.primaryNavy;
            final subTextColor = isDark ? AppColors.darkTextSecondary : Colors.grey.shade600;

            // 状態から読み込むことでunused warningを解消
            final addressStr = _customPinAddress ?? '指定した地点';

            return PointerInterceptor(
              child: Container(
                padding: const EdgeInsets.only(top: 24, left: 24, right: 24, bottom: 32),
                decoration: BoxDecoration(
                  color: bgColor,
                  borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '指定した地点',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: textColor,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      addressStr,
                      style: TextStyle(fontSize: 14, color: subTextColor),
                    ),
                    const SizedBox(height: 24),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppColors.blueAccentLight,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        ),
                        onPressed: () {
                          Navigator.of(context).pop();
                          
                          final effectiveStart = _originLocation ?? _currentPosition;
                          if (effectiveStart == null) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('現在地が取得できていません。GPS を確認してください。')),
                            );
                            return;
                          }

                          setState(() {
                            if (!_isRoutePlanning) {
                              _originLocation = null;
                              _originName = null;
                            }
                            _isRoutePlanning = true;
                            _destinationLocation = point;
                            _destinationName = addressStr;
                          });

                          final startPoint = _originLocation ?? _currentPosition!;
                          fetchAndDrawRoute(start: startPoint, end: point);
                        },
                        child: const Text('ここへ行く', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    ).then((_) {
      Future.delayed(const Duration(milliseconds: 300), () {
        if (mounted) {
          setState(() {
            _isPlaceSheetOpen = false;
            _customPinLocation = null;
            _customPinAddress = null;
            if (!_isNavigating) {
              _markers = {};
            }
          });
        }
      });
    });
  }

  // ─────────────────────────────────────────────────────────────────────
  // GPS 追従
  // ─────────────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    _initLocationTracking();
    _loadCustomMarkers();
    _initAlertPolling();
  }

  Future<void> _loadCustomMarkers() async {
    final small = await createBearMarker(size: 25);
    final medium = await createBearMarker(size: 45);
    final large = await createBearMarker(size: 65);
    if (mounted) {
      setState(() {
        _bearMarkerSmall = small;
        _bearMarkerMedium = medium;
        _bearMarkerLarge = large;
      });
      
      // アイコン生成後にすでにハザードマーカーが存在していれば、アイコンを適用するために再描画（または再取得）する
      if (_hazardMarkers.isNotEmpty) {
        _fetchHazards();
      }
    }
  }

  Future<void> _initLocationTracking() async {
    try {
      bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) return;

      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied) return;
      }
      if (permission == LocationPermission.deniedForever) return;

      // 初回の現在地を取得
      try {
        final pos = await Geolocator.getCurrentPosition(
          desiredAccuracy: LocationAccuracy.high,
        );
        if (mounted) {
          setState(() {
            _currentPosition = LatLng(pos.latitude, pos.longitude);
            _isLoadingGps = false;
          });
          if (!_hasMovedToCurrentLocation) {
            _mapController?.animateCamera(
              CameraUpdate.newLatLngZoom(_currentPosition!, 15.0),
            );
            _hasMovedToCurrentLocation = true;
          }
        }
      } catch (e) {
        // 初期取得失敗時はストリームへ
        debugPrint('Initial location fetch failed: $e');
      }

      // ストリームで継続的な追従（10メートル以上動いた時だけ更新）
      _positionStream = Geolocator.getPositionStream(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          distanceFilter: 10,
        ),
      ).listen(
        (Position position) {
          if (mounted) {
            setState(() {
              _currentPosition = LatLng(position.latitude, position.longitude);
              _isLoadingGps = false;
            });

            if (!_hasMovedToCurrentLocation) {
              _mapController?.animateCamera(
                CameraUpdate.newLatLngZoom(_currentPosition!, 15.0),
              );
              _hasMovedToCurrentLocation = true;
            }

            // ナビ中はカメラが現在地を追従
            if (_isNavigating) {
              _mapController?.animateCamera(
                CameraUpdate.newLatLng(_currentPosition!),
              );
            }
          }
        },
        onError: (error) {
          debugPrint('Location stream error: $error');
        },
      );
    } catch (e) {
      debugPrint('Location tracking init error: $e');
      if (mounted) {
        setState(() => _isLoadingGps = false);
      }
    }
  }

  // ─────────────────────────────────────────────────────────────────────
  // 危険情報アラート（ポーリング方式 / Web対応）
  // ─────────────────────────────────────────────────────────────────────

  void _initAlertPolling() async {
    final apiService = ref.read(apiServiceProvider);

    // 初回: 現在DBにある中で最新のIDを記録（アプリ起動前の情報はアラートしない）
    final initials = await apiService.fetchNewCrimeReports();
    if (initials.isNotEmpty) {
      _lastKnownReportId = initials.first['id'] as int;
    } else {
      _lastKnownReportId = 0;
    }

    // 4秒ごとに新着レポートを確認
    _pollingTimer = Timer.periodic(const Duration(seconds: 4), (timer) async {
      if (!mounted) {
        timer.cancel();
        return;
      }
      if (_lastKnownReportId == null) return;

      try {
        final newReports = await apiService.fetchNewCrimeReports(afterId: _lastKnownReportId);

        if (newReports.isNotEmpty && mounted) {
          // 二度鳴り防止: 取得した中で最大のIDを更新
          _lastKnownReportId = newReports.last['id'] as int;

          final myLat = _currentPosition?.latitude ?? 37.3450;
          final myLng = _currentPosition?.longitude ?? 138.9000;

          for (final report in newReports) {
            if (mounted) {
              _showEmergencyDialog(report, myLat, myLng);
            }
          }
        }
      } catch (e) {
        debugPrint('[Polling] error: $e');
      }
    });
  }

  void _showEmergencyDialog(Map<String, dynamic> report, double myLat, double myLng) {
    final double rLat = (report['lat'] as num).toDouble();
    final double rLng = (report['lng'] as num).toDouble();

    final distMeters = Geolocator.distanceBetween(myLat, myLng, rLat, rLng).round();
    final String distanceText = distMeters > 1000
        ? '${(distMeters / 1000).toStringAsFixed(1)}km'
        : '${distMeters}m';

    final eventName = report['event_type'] == 'bear' ? 'クマ' : '不審者/危険対象';
    final headerMessage = '$distanceText先で$eventNameが目撃されました';
    final description = report['description'] ?? '詳しい状況の記載はありません。';

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.red.shade900,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            const Icon(Icons.warning_amber_rounded, color: Colors.amber, size: 36),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '$eventName出没警告',
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 20,
                ),
              ),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: Colors.amber.shade400,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                headerMessage,
                style: const TextStyle(
                  color: Colors.black,
                  fontWeight: FontWeight.bold,
                  fontSize: 16,
                ),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              '詳細：$description',
              style: const TextStyle(color: Colors.white, fontSize: 15, height: 1.4),
            ),
          ],
        ),
        actions: [
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.white),
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text(
              '確認',
              style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _pollingTimer?.cancel();
    _mapTapDebounceTimer?.cancel();
    _positionStream?.cancel();
    _mapController?.dispose();
    super.dispose();
  }

  // ─────────────────────────────────────────────────────────────────────
  // UI: ルート設定カード
  // ─────────────────────────────────────────────────────────────────────

  void _showOriginSearchSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return const OriginSearchSheet();
      },
    ).then((result) {
      if (result == null) return;
      
      setState(() {
        if (result == 'CURRENT_LOCATION') {
          _originLocation = null;
          _originName = null;
        } else if (result is PlaceResult) {
          _originLocation = LatLng(result.lat, result.lng);
          _originName = result.shortName;
        }
      });

      if (_destinationLocation != null) {
        final startPoint = _originLocation ?? _currentPosition;
        if (startPoint != null) {
          fetchAndDrawRoute(start: startPoint, end: _destinationLocation!);
        } else {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('現在地が取得できていません。GPSを確認してください。')),
            );
          }
        }
      }
    });
  }

  Widget _buildRoutePlanningCard() {
    if (!_isRoutePlanning) return const SizedBox.shrink();

    final isDark = ref.watch(mapThemeProvider);
    final bgColor = isDark ? AppColors.darkSurface.withValues(alpha: 0.95) : Colors.white.withValues(alpha: 0.95);
    final textColor = isDark ? AppColors.darkTextPrimary : Colors.black87;
    final borderColor = isDark ? AppColors.darkBorder : Colors.grey.shade300;

    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: SafeArea(
        bottom: false,
        child: PointerInterceptor(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
            child: Card(
              elevation: 4,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
              color: bgColor,
              child: Padding(
                padding: const EdgeInsets.all(12.0),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // ヘッダー（戻るボタン・タイトル）
                    Row(
                      children: [
                        IconButton(
                          icon: Icon(Icons.arrow_back, color: textColor),
                          onPressed: _clearRoute,
                          tooltip: 'ルート設定をキャンセル',
                        ),
                        Expanded(
                          child: Text(
                            'ルート設定',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                              color: textColor,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    // 出発地
                    GestureDetector(
                      onTap: _showOriginSearchSheet,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                        decoration: BoxDecoration(
                          border: Border.all(color: borderColor),
                          borderRadius: BorderRadius.circular(8),
                          color: isDark ? AppColors.darkCard : Colors.grey.shade50,
                        ),
                        child: Row(
                          children: [
                            const Icon(Icons.my_location, size: 16, color: Colors.blue),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                _originName ?? '現在地',
                                style: TextStyle(
                                  color: _originName == null ? Colors.blue : textColor,
                                  fontWeight: _originName == null ? FontWeight.bold : FontWeight.normal,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    // 目的地（読み取り専用）
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                      decoration: BoxDecoration(
                        border: Border.all(color: borderColor),
                        borderRadius: BorderRadius.circular(8),
                        color: isDark ? AppColors.darkCard : Colors.grey.shade50,
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.location_on, size: 16, color: Colors.red),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              _destinationName ?? '目的地',
                              style: TextStyle(color: textColor),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ─────────────────────────────────────────────────────────────────────
  // UI: ルート比較カード
  // ─────────────────────────────────────────────────────────────────────

  Widget _buildRouteCompareCard() {
    if (_currentRouteResponse == null || _isNavigating) {
      return const SizedBox.shrink();
    }

    final safe = _currentRouteResponse!.safeRoute;
    final shortest = _currentRouteResponse!.shortestRoute;
    final isDark = ref.watch(mapThemeProvider);
    final bgColor = isDark ? AppColors.darkSurface.withValues(alpha: 0.97) : Colors.white.withValues(alpha: 0.97);
    final headerColor = isDark ? Colors.white : AppColors.primaryNavy;
    final iconCloseColor = isDark ? Colors.white70 : Colors.grey;

    return Positioned(
      bottom: 24,
      left: 12,
      right: 12,
      child: PointerInterceptor(
        child: Card(
          elevation: 8,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
          ),
          color: bgColor,
          child: Padding(
            padding: const EdgeInsets.symmetric(
                horizontal: 16.0, vertical: 14.0),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // ── ヘッダー ──
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      '🧭 ルート比較',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 14,
                        color: headerColor,
                      ),
                    ),
                    GestureDetector(
                      onTap: _clearRoute,
                      child: Icon(Icons.close,
                          size: 20, color: iconCloseColor),
                    ),
                  ],
                ),
                const SizedBox(height: 12),

                // ── ルート選択タイル ──
                Row(
                  children: [
                    Expanded(
                      child: _buildRouteSelectorTile(
                        label: '安全優先',
                        icon: Icons.shield_outlined,
                        color: const Color(0xFF2ECC71),
                        distance: safe.distanceM,
                        score: safe.safetyScore,
                        routeType: _RouteType.safe,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      width: 1,
                      height: 70,
                      color: Colors.grey.shade300,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _buildRouteSelectorTile(
                        label: '最短距離',
                        icon: Icons.route,
                        color: const Color(0xFF3498DB),
                        distance: shortest.distanceM,
                        score: shortest.safetyScore,
                        routeType: _RouteType.shortest,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),

                // ── 「案内を開始」ボタン ──
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: _startNavigation,
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.primaryNavy,
                      padding:
                          const EdgeInsets.symmetric(vertical: 13),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    icon: const Icon(Icons.navigation,
                        color: Colors.white),
                    label: const Text(
                      '案内を開始',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 10),

                // ── 帰属表記（ライセンス設計指針 §2.3 準拠）──
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.info_outline,
                        size: 11, color: Colors.grey.shade500),
                    const SizedBox(width: 4),
                    Text(
                      '経路データ提供: OpenStreetMap コントリビューター',
                      style: TextStyle(
                          fontSize: 10, color: Colors.grey.shade500),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// ルート種別を選択できるタイル（選択中は枠線でハイライト）
  Widget _buildRouteSelectorTile({
    required String label,
    required IconData icon,
    required Color color,
    required double distance,
    required double score,
    required _RouteType routeType,
  }) {
    final bool isSelected = _selectedRouteType == routeType;

    return GestureDetector(
      onTap: () {
        setState(() {
          if (_selectedRouteType == routeType) {
            _selectedRouteType = null;
          } else {
            _selectedRouteType = routeType;
          }
        });
        _refreshPolylines();
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding:
            const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: isSelected
              ? color.withValues(alpha: 0.08)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: isSelected ? color : Colors.transparent,
            width: 1.5,
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 14, color: color),
                const SizedBox(width: 4),
                Text(
                  label,
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 12,
                    color: color,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              distance >= 1000
                  ? '${(distance / 1000).toStringAsFixed(1)} km'
                  : '${distance.toStringAsFixed(0)} m',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w700,
                color: ref.watch(mapThemeProvider) ? AppColors.darkTextPrimary : Colors.black87,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              '安全: ${(score * 100).toStringAsFixed(0)}%',
              style: TextStyle(
                fontSize: 11, 
                color: ref.watch(mapThemeProvider) ? AppColors.darkTextSecondary : Colors.grey.shade600,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ─────────────────────────────────────────────────────────────────────
  // UI: ナビ中 HUD
  // ─────────────────────────────────────────────────────────────────────

  Widget _buildNavigationHud() {
    if (!_isNavigating || _currentRouteResponse == null) {
      return const SizedBox.shrink();
    }

    final routeInfo = _selectedRouteType == _RouteType.safe
        ? _currentRouteResponse!.safeRoute
        : _currentRouteResponse!.shortestRoute;

    final routeLabel = _selectedRouteType == _RouteType.safe
        ? '安全優先ルート'
        : '最短距離ルート';
    final routeColor = _selectedRouteType == _RouteType.safe
        ? const Color(0xFF2ECC71)
        : const Color(0xFF3498DB);

    final isDark = ref.watch(mapThemeProvider);
    final bgColor = isDark ? AppColors.darkSurface : AppColors.primaryNavy;

    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: PointerInterceptor(
        child: Container(
          decoration: BoxDecoration(
            color: bgColor,
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.3),
                blurRadius: 8,
                offset: const Offset(0, 3),
              ),
            ],
          ),
          child: SafeArea(
            bottom: false,
            child: Padding(
              padding: const EdgeInsets.symmetric(
                  horizontal: 16, vertical: 12),
              child: Row(
                children: [
                  Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                      color: routeColor,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          '案内中: $routeLabel',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 13,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          routeInfo.distanceM >= 1000
                              ? '総距離: ${(routeInfo.distanceM / 1000).toStringAsFixed(1)} km  ・  '
                                  '安全スコア: ${(routeInfo.safetyScore * 100).toStringAsFixed(0)}%'
                              : '総距離: ${routeInfo.distanceM.toStringAsFixed(0)} m  ・  '
                                  '安全スコア: ${(routeInfo.safetyScore * 100).toStringAsFixed(0)}%',
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.8),
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ),
                  ),
                  TextButton(
                    onPressed: _stopNavigation,
                    style: TextButton.styleFrom(
                      backgroundColor: Colors.red.shade600,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 8),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(20),
                      ),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    child: const Text(
                      '終了',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ─────────────────────────────────────────────────────────────────────
  // 投稿用ボトムシートの表示
  // ─────────────────────────────────────────────────────────────────────
  void _showPostBottomSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true, // キーボード表示時にシート全体を押し上げるために必要
      backgroundColor: Colors.transparent, // シート側の角丸を活かすため
      builder: (context) {
        return const PostBottomSheet();
      },
    );
  }

  // ─────────────────────────────────────────────────────────────────────
  // build
  // ─────────────────────────────────────────────────────────────────────

  void _showSettingsSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return StatefulBuilder(
          builder: (BuildContext context, StateSetter setModalState) {
            return Consumer(
          builder: (context, ref, child) {
            final isDarkTheme = ref.watch(mapThemeProvider);
            final bgColor = isDarkTheme ? AppColors.darkSurface : Colors.white;
            final textColor = isDarkTheme ? AppColors.darkTextPrimary : Colors.black87;

            return PointerInterceptor(
              child: Material(
                color: bgColor,
                borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          '設定',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            color: textColor,
                          ),
                        ),
                        IconButton(
                          icon: Icon(Icons.close, color: textColor),
                          onPressed: () => Navigator.pop(context),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    SwitchListTile(
                      title: Text('マップのダークモード', style: TextStyle(color: textColor)),
                      value: isDarkTheme,
                      onChanged: (value) {
                        ref.read(mapThemeProvider.notifier).toggleTheme(value);
                      },
                      secondary: Icon(
                        isDarkTheme ? Icons.dark_mode : Icons.light_mode,
                        color: isDarkTheme ? AppColors.blueAccentLight : Colors.orange,
                      ),
                      activeThumbColor: AppColors.blueAccentLight,
                    ),
                    const SizedBox(height: 8),
                    SwitchListTile(
                      title: Text('航空写真モード', style: TextStyle(color: textColor)),
                      value: _isSatelliteMode,
                      onChanged: (value) {
                        setModalState(() {
                          _isSatelliteMode = value;
                        });
                        setState(() {
                          _isSatelliteMode = value;
                        });
                      },
                      secondary: Icon(
                        _isSatelliteMode ? Icons.satellite_alt : Icons.map,
                        color: _isSatelliteMode ? AppColors.blueAccentLight : Colors.grey,
                      ),
                      activeThumbColor: AppColors.blueAccentLight,
                    ),
                    const SizedBox(height: 20),
                  ],
                ),
              ),
            ),
          );
          },
        );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDarkTheme = ref.watch(mapThemeProvider);
    final imageState = ref.watch(selectedImageProvider);
    final coverageState = ref.watch(coverageProvider);
    final coveragePolygons = _buildCoveragePolygons(coverageState);

    return Scaffold(
      resizeToAvoidBottomInset: false,
      // ナビ中は AppBar を非表示
      appBar: _isNavigating
          ? null
          : AppBar(
              title: const Row(
                children: [
                  Icon(Icons.shield_outlined, color: AppColors.white),
                  SizedBox(width: 8),
                  Text(
                    'SafeWay',
                    style: TextStyle(
                        fontWeight: FontWeight.bold,
                        letterSpacing: 1.2),
                  ),
                ],
              ),
              actions: [
                IconButton(
                  icon: const Icon(Icons.info_outline),
                  onPressed: () {
                    showAboutDialog(
                      context: context,
                      applicationName: 'SafeWay',
                      applicationVersion: '1.0.0 (Phase 3)',
                      applicationIcon: const Icon(
                        Icons.shield,
                        color: AppColors.primaryNavy,
                        size: 40,
                      ),
                      children: const [
                        Text(
                            'GPA 2026 アプリ部門受賞を目指す「安心」ナビゲーション。'),
                        SizedBox(height: 8),
                        Text('Phase 3: 場所検索・タップ詳細・API仕様書対応'),
                        SizedBox(height: 8),
                        Text(
                          '地図データ経路計算: © OpenStreetMap contributors (ODbL)',
                          style: TextStyle(fontSize: 12),
                        ),
                        Text(
                          'https://www.openstreetmap.org/copyright',
                          style: TextStyle(
                              fontSize: 12, color: Colors.blue),
                        ),
                      ],
                    );
                  },
                ),
              ],
            ),
      body: Stack(
        children: [
          // ── 1. Google Maps 本体 ──────────────────────────────────────
          // AbsorbPointer でサジェスト表示中はネイティブタッチを遮断
          AbsorbPointer(
            absorbing: _isSuggestionsVisible,
            child: GoogleMap(
              onMapCreated: (controller) {
                setState(() {
                  _mapController = controller;
                });

                if (_currentPosition != null &&
                    !_hasMovedToCurrentLocation) {
                  controller.animateCamera(
                    CameraUpdate.newLatLngZoom(
                        _currentPosition!, 15.0),
                  );
                  _hasMovedToCurrentLocation = true;
                }
              },
              initialCameraPosition: const CameraPosition(
                target: _defaultCenter,
                zoom: 15.0,
              ),
              mapType: _isSatelliteMode ? MapType.hybrid : MapType.normal,
              style: isDarkTheme ? MapStyles.dark : MapStyles.light,
              // ─ 本家 Google Map 準拠のインタラクションハンドラ ─
              onTap: _onMapTap,
              // onPoiTap: google_maps_flutter 2.17.x 時点で公開なし。
              // POI情報は長押し（onLongPress）経由で全て対応する。
              onLongPress: _onLongPress,
              onCameraMoveStarted: () {
                // ダブルタップズームやドラッグ等の操作が始まったら、保留中のシングルタップ処理をキャンセル
                _mapTapDebounceTimer?.cancel();
              },
              onCameraIdle: _onCameraIdle,
              onCameraMove: (CameraPosition position) {
                // ズーム閾値を超えた場合のみ setState して再描画
                final newZoom = position.zoom;
                final crossed8_0 = (_currentZoom < 8.0) != (newZoom < 8.0);
                final crossed12_0 = (_currentZoom < 12.0) != (newZoom < 12.0);
                final crossed14_5 = (_currentZoom < 14.5) != (newZoom < 14.5);
                final crossed15_0 = (_currentZoom < 15.0) != (newZoom < 15.0);
                _currentZoom = newZoom;
                if ((crossed8_0 || crossed12_0 || crossed14_5 || crossed15_0) && mounted) {
                  setState(() {
                    _hazardMarkers = _hazardMarkers
                        .where((marker) => true)
                        .toSet();
                  });
                  _fetchHazards();
                }
              },
              markers: {..._markers, ..._hazardMarkers},
              polygons: coveragePolygons,
              polylines: _polylines,
              myLocationEnabled: true,
              myLocationButtonEnabled: false,
              zoomControlsEnabled: false,
              compassEnabled: true,
              mapToolbarEnabled: false,
            ),
          ),

          // ── 2. ナビ中 HUD（最前面: AppBar代替）─────────────────────
          _buildNavigationHud(),

          // ── 2.5. 左側：ハザード情報トグルボタン＆設定ボタン（ナビ中は非表示）───────────
          if (!_isNavigating) ...[
            // 設定ボタン
            Positioned(
              left: 16,
              top: 80, // ハザードボタンのすぐ上
              child: SafeArea(
                child: PointerInterceptor(
                  child: FloatingActionButton(
                    heroTag: 'settingsBtn',
                    onPressed: _showSettingsSheet,
                    backgroundColor: isDarkTheme ? AppColors.darkFabBackground : Colors.white,
                    foregroundColor: isDarkTheme ? AppColors.darkTextPrimary : AppColors.primaryNavy,
                    mini: true,
                    tooltip: '設定',
                    child: const Icon(Icons.settings),
                  ),
                ),
              ),
            ),
            // ハザード情報ボタン
            Positioned(
              left: 16,
              top: 140, // 検索バーの下あたり
              child: SafeArea(
                child: PointerInterceptor(
                  child: Consumer(
                    builder: (context, ref, child) {
                      final hazardState = ref.watch(hazardProvider);
                      return GestureDetector(
                        onLongPress: _showHazardSettingsDialog,
                        child: FloatingActionButton(
                          heroTag: 'hazardToggleBtn',
                          onPressed: () {
                            ref.read(hazardProvider.notifier).toggleVisibility();
                            // 表示状態が変わったら即座に再フェッチ
                            _fetchHazards();
                          },
                          backgroundColor: hazardState.isVisible ? Colors.yellow.shade700 : Colors.grey.shade400,
                          foregroundColor: Colors.white,
                          mini: true, // 少し小さめに
                          tooltip: 'ハザード情報の表示 (長押しで設定)',
                          child: const Icon(Icons.warning_amber),
                        ),
                      );
                    },
                  ),
                ),
              ),
            ),
            // カバレッジ情報ボタン
            Positioned(
              left: 16,
              top: 200, // ハザードボタンの下
              child: SafeArea(
                child: PointerInterceptor(
                  child: Consumer(
                    builder: (context, ref, child) {
                      final coverageState = ref.watch(coverageProvider);
                      return FloatingActionButton(
                        heroTag: 'coverageToggleBtn',
                        onPressed: () async {
                          final notifier = ref.read(coverageProvider.notifier);
                          notifier.toggleVisibility();
                          final newState = ref.read(coverageProvider);
                          if (newState.isVisible && _mapController != null) {
                            final zoom = await _mapController!.getZoomLevel();
                            if (zoom >= 8.0) {
                              final bounds = await _mapController!.getVisibleRegion();
                              notifier.fetchCoverage(
                                minLat: bounds.southwest.latitude,
                                minLng: bounds.southwest.longitude,
                                maxLat: bounds.northeast.latitude,
                                maxLng: bounds.northeast.longitude,
                                zoom: zoom,
                              );
                            } else {
                              if (context.mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(content: Text('カバレッジを表示するにはズームインしてください')),
                                );
                              }
                            }
                          }
                        },
                        backgroundColor: coverageState.isVisible ? Colors.green.shade600 : Colors.grey.shade400,
                        foregroundColor: Colors.white,
                        mini: true,
                        tooltip: '情報空白地帯の可視化',
                        child: const Icon(Icons.layers),
                      );
                    },
                  ),
                ),
              ),
            ),
          ],

          // ── 3. 上部：検索バー（ナビ中は非表示）─────────────────────
          if (!_isNavigating && !_isRoutePlanning)
            MapSearchBar(
              mapController: _mapController,
              currentPosition: _currentPosition,
              onSuggestionsVisibilityChanged: (isVisible) {
                setState(() => _isSuggestionsVisible = isVisible);
              },
              onPlaceSelected: (place) {
                final point = LatLng(place.lat, place.lng);
                // placeId を渡すことで、高精度な詳細情報を一発取得
                _showSpotDetails(point: point, placeId: place.placeId); 
              },
              onSearchResultsFetched: (results) {
                if (results.isEmpty) return;

                final Set<Marker> newMarkers = {};
                for (int i = 0; i < results.length; i++) {
                  final place = results[i];
                  final point = LatLng(place.lat, place.lng);
                  
                  newMarkers.add(
                    Marker(
                      markerId: MarkerId('search_result_$i'),
                      position: point,
                      icon: BitmapDescriptor.defaultMarker,
                      onTap: () {
                        if (_isProcessingTap) return;
                        _isProcessingTap = true;
                        try {
                          // いずれかのピンをタップした際に、その店舗の詳細情報を表示
                          _showSpotDetails(point: point, placeId: place.placeId);
                        } finally {
                          _isProcessingTap = false;
                        }
                      },
                    ),
                  );
                }

                setState(() {
                  _markers = newMarkers;
                });
                
                // 必要に応じて、最初の検索結果の場所にカメラを移動させる
                if (results.isNotEmpty) {
                  final firstPlace = results.first;
                  _mapController?.animateCamera(
                    CameraUpdate.newLatLngZoom(
                      LatLng(firstPlace.lat, firstPlace.lng),
                      14.0, // 周辺が見渡せるズームレベル
                    ),
                  );
                }
              },
            ),

          // ルート設定カード
          if (!_isNavigating && _isRoutePlanning)
            _buildRoutePlanningCard(),

          // ── 4. 画像プレビューカード（ナビ中は非表示）────────────────
          if (imageState.image != null && !_isNavigating)
            ImagePreviewCard(imageState: imageState),

          // ── 5. 右下のアクションボタン（ナビ中は非表示）──────────────
          if (!_isNavigating)
            ActionButtons(
              mapController: _mapController,
              currentPosition: _currentPosition,
              onCameraPressed: _showPostBottomSheet,
            ),

          // ── 6. ルート比較カード（ルート取得後・ナビ前のみ）──────────
          _buildRouteCompareCard(),

          // ── 7. ルート探索中ローディングインジケーター ────────────────
          if (_isLoadingRoute)
            Positioned(
              top: 80,
              left: 0,
              right: 0,
              child: SafeArea(
                child: Center(
                  child: PointerInterceptor(
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          vertical: 8, horizontal: 20),
                      decoration: BoxDecoration(
                        color:
                            AppColors.primaryNavy.withValues(alpha: 0.9),
                        borderRadius: BorderRadius.circular(20),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.2),
                            blurRadius: 6,
                            offset: const Offset(0, 3),
                          ),
                        ],
                      ),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          ),
                          SizedBox(width: 10),
                          Text(
                            'ルートを探索中...',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w500,
                              color: Colors.white,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),

          // ── 8. GPS取得中インジケーター（ナビ中は非表示）─────────────
          if (_isLoadingGps && !_isNavigating)
            Positioned(
              top: _isLoadingRoute ? 120 : 80,
              left: 16,
              right: 16,
              child: SafeArea(
                child: Center(
                  child: PointerInterceptor(
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          vertical: 8, horizontal: 16),
                      decoration: BoxDecoration(
                        color:
                            AppColors.white.withValues(alpha: 0.9),
                        borderRadius: BorderRadius.circular(20),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.1),
                            blurRadius: 4,
                            offset: const Offset(0, 2),
                          ),
                        ],
                      ),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(
                                strokeWidth: 2),
                          ),
                          SizedBox(width: 10),
                          Text(
                            'GPS現在地を取得中...',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w500,
                              color: Colors.black87,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          // ── 9. クマ情報 出典表記 ──────────────────────────────────────
          Positioned(
            bottom: 24,
            left: 8,
            child: SafeArea(
              child: IgnorePointer(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.7),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    '出典：群馬県環境森林部自然環境課',
                    style: TextStyle(
                      fontSize: 10,
                      color: Colors.grey.shade700,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
