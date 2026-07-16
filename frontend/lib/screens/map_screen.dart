import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:pointer_interceptor/pointer_interceptor.dart';
import '../providers/image_provider.dart';
import '../core/theme.dart';
import '../core/api_config.dart';
import '../widgets/image_preview_card.dart';
import '../widgets/action_buttons.dart';
import '../widgets/search_bar_widget.dart';
import '../widgets/place_info_sheet.dart';
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

  /// 地図上に立っているマーカー（目的地ピン等）
  Set<Marker> _markers = {};

  /// ルート描画用のポリラインセット
  Set<Polyline> _polylines = {};

  /// 現在表示中のルートデータ（比較カード・ナビ用）
  RouteResponse? _currentRouteResponse;

  /// ルート探索中フラグ
  bool _isLoadingRoute = false;

  /// サジェストリストが表示中の場合 true（地図タップを無効化する）
  bool _isSuggestionsVisible = false;

  /// 選択中のルート種別（比較カードでユーザーが選択）
  _RouteType _selectedRouteType = _RouteType.safe;

  /// ナビ案内中フラグ
  bool _isNavigating = false;

  /// ボトムシートが現在表示中かどうかを示すフラグ
  ///
  /// onTap での安全な Navigator.pop を実現するために使用する。
  /// ボトムシートが表示されていない状態で誤って地図画面自体がポップしないよう防衛する。
  bool _isPlaceSheetOpen = false;

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
    final Set<Polyline> newPolylines = {};

    // 1. 安全優先ルート: 区間ごとにループして safety_score で色分け
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

    // 2. 最短距離ルート: allPoints を使い単色（青）の1本線で描画
    final shortestPoints = response.shortestRoute.allPoints;
    if (shortestPoints.length >= 2) {
      newPolylines.add(
        Polyline(
          polylineId: const PolylineId('shortest_route'),
          points: shortestPoints,
          color: const Color(0xFF3498DB), // スカイブルー
          width: 4,
          zIndex: 5,
          startCap: Cap.roundCap,
          endCap: Cap.roundCap,
          jointType: JointType.round,
        ),
      );
    }

    setState(() {
      _currentRouteResponse = response;
      _polylines = newPolylines;
      _selectedRouteType = _RouteType.safe;
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
      final response = await apiService.fetchRoute(
        startLat: start.latitude,
        startLng: start.longitude,
        endLat: end.latitude,
        endLng: end.longitude,
      );
      _updateRoutePolylines(response);
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
      _markers = {};
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

    setState(() => _isNavigating = true);

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
      onRouteRequested: (LatLng destination) {
        if (_currentPosition == null) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('現在地が取得できていません。GPS を確認してください。'),
            ),
          );
          return;
        }
        fetchAndDrawRoute(start: _currentPosition!, end: destination);
      },
    ).then((_) {
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
  }

  // ─────────────────────────────────────────────────────────────────────
  // 地図インタラクションハンドラ（本家 Google Map 準拠）
  // ─────────────────────────────────────────────────────────────────────

  /// 1. 通常タップ（自動 POI 判定）
  Future<void> _onMapTap(LatLng point) async {
    if (_isSuggestionsVisible || _isNavigating) return;

    // タップ地点周辺を Nearby Search で検索し、POI かどうかを判定
    final poi = await _findNearbyPoi(point);

    if (poi != null) {
      // ① 付近に POI（店舗・スポット）が見つかった場合
      // 見つかった店舗の正確な座標にピンを立て、ボトムシートを表示
      _showSpotDetails(point: poi.latLng, placeId: poi.placeId);
    } else {
      // ② 付近に POI が見つからない場合（ただの道路や地面をタップ）
      // ユーザーが「選択を解除した」とみなし、シートを閉じてピンをクリア
      if (!mounted) return;
      
      if (_isPlaceSheetOpen) {
        if (Navigator.of(context).canPop()) {
          Navigator.pop(context); // 安全にボトムシートを閉じる
        }
      }
      if (_markers.isNotEmpty) {
        setState(() => _markers = {});
      }
    }
  }

  /// タップ座標周辺の POI を検索するヘルパー
  Future<_DetectedPoi?> _findNearbyPoi(LatLng point) async {
    const key = ApiConfig.googleMapsApiKey;
    if (key == 'YOUR_GOOGLE_MAPS_API_KEY_HERE' || key.isEmpty) return null;

    try {
      final uri = Uri.https(
        'maps.googleapis.com',
        '/maps/api/place/nearbysearch/json',
        {
          'location': '${point.latitude},${point.longitude}',
          'radius': '15', // タップ地点から15m以内の施設を検索
          'language': 'ja',
          'key': key,
        },
      );
      final response = await http.get(uri).timeout(const Duration(seconds: 4));
      if (response.statusCode != 200) return null;

      final data = jsonDecode(response.body);
      final results = data['results'] as List<dynamic>?;
      if (results == null || results.isEmpty) return null;

      // 一番近い施設をタップされた POI とみなす
      final place = results.first as Map<String, dynamic>;
      final lat = place['geometry']['location']['lat'] as num;
      final lng = place['geometry']['location']['lng'] as num;
      final placeId = place['place_id'] as String;

      return _DetectedPoi(
        latLng: LatLng(lat.toDouble(), lng.toDouble()), // 店舗の正確な座標
        placeId: placeId,
      );
    } catch (_) {
      return null;
    }
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
  void _onLongPress(LatLng point) {
    if (_isSuggestionsVisible || _isNavigating) return;
    _showSpotDetails(point: point);
  }

  // ─────────────────────────────────────────────────────────────────────
  // GPS 追従
  // ─────────────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    _initLocationTracking();
  }

  Future<void> _initLocationTracking() async {
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
    }

    // ストリームで継続的な追従（10メートル以上動いた時だけ更新）
    _positionStream = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 10,
      ),
    ).listen((Position position) {
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
    });
  }

  /// カメラ/ギャラリー選択ボトムシート（ActionButtonsからも呼ばれる）
  void _showImageSourceBottomSheet() {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (BuildContext context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 16),
                child: Text(
                  '街の状況を投稿',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: AppColors.primaryNavy,
                  ),
                ),
              ),
              ListTile(
                leading: const Icon(Icons.camera_alt,
                    color: AppColors.primaryNavy),
                title: const Text('カメラで撮影（精度: 高）'),
                subtitle:
                    const Text('GPS+コンパスで街灯の実際の位置を推定します'),
                onTap: () {
                  Navigator.pop(context);
                  ref
                      .read(selectedImageProvider.notifier)
                      .pickImageFromCamera();
                },
              ),
              ListTile(
                leading: const Icon(Icons.photo_library,
                    color: AppColors.primaryNavy),
                title: const Text('ギャラリーから写真を選択'),
                subtitle: const Text('EXIFのGPS情報を自動抽出します'),
                onTap: () {
                  Navigator.pop(context);
                  ref
                      .read(selectedImageProvider.notifier)
                      .pickImageFromGallery();
                },
              ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }

  @override
  void dispose() {
    _positionStream?.cancel();
    _mapController?.dispose();
    super.dispose();
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
          color: Colors.white.withValues(alpha: 0.97),
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
                    const Text(
                      '🧭 ルート比較',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 14,
                        color: AppColors.primaryNavy,
                      ),
                    ),
                    GestureDetector(
                      onTap: _clearRoute,
                      child: const Icon(Icons.close,
                          size: 20, color: Colors.grey),
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
      onTap: () => setState(() => _selectedRouteType = routeType),
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
              style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w700,
                color: Colors.black87,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              '安全: ${(score * 100).toStringAsFixed(0)}%',
              style:
                  TextStyle(fontSize: 11, color: Colors.grey.shade600),
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

    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: PointerInterceptor(
        child: Container(
          decoration: BoxDecoration(
            color: AppColors.primaryNavy,
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
  // build
  // ─────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final imageState = ref.watch(selectedImageProvider);

    return Scaffold(
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
              // ─ 本家 Google Map 準拠のインタラクションハンドラ ─
              onTap: _onMapTap,
              // onPoiTap: google_maps_flutter 2.17.x 時点で公開なし。
              // POI情報は長押し（onLongPress）経由で全て対応する。
              onLongPress: _onLongPress,
              markers: _markers,
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

          // ── 3. 上部：検索バー（ナビ中は非表示）─────────────────────
          if (!_isNavigating)
            MapSearchBar(
              mapController: _mapController,
              currentPosition: _currentPosition,
              onSuggestionsVisibilityChanged: (isVisible) {
                setState(() => _isSuggestionsVisible = isVisible);
              },
              onPlaceSelected: (place) {
                final point = LatLng(place.lat, place.lng);
                // _showSpotDetails を呼ぶことで、自動的に赤ピンが立ち、ボトムシートが表示される
                _showSpotDetails(point: point); 
              },
            ),

          // ── 4. 画像プレビューカード（ナビ中は非表示）────────────────
          if (imageState.image != null && !_isNavigating)
            ImagePreviewCard(imageState: imageState),

          // ── 5. 右下のアクションボタン（ナビ中は非表示）──────────────
          if (!_isNavigating)
            ActionButtons(
              mapController: _mapController,
              currentPosition: _currentPosition,
              onCameraPressed: _showImageSourceBottomSheet,
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
        ],
      ),
    );
  }
}
