import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import '../providers/image_provider.dart';
import '../core/theme.dart';
import '../widgets/image_preview_card.dart';
import '../widgets/action_buttons.dart';
import '../widgets/search_bar_widget.dart';
import '../widgets/place_info_sheet.dart';

class MapScreen extends ConsumerStatefulWidget {
  const MapScreen({super.key});

  @override
  ConsumerState<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends ConsumerState<MapScreen> {
  late final MapController _mapController;
  StreamSubscription<Position>? _positionStream;

  LatLng? _currentPosition;
  bool _isLoadingGps = true;
  bool _hasMovedToCurrentLocation = false;

  /// タップされたマーカーの位置（表示中のみ non-null）
  LatLng? _tappedPoint;

  final LatLng _defaultCenter = const LatLng(36.3895, 139.0634); // 前橋駅

  @override
  void initState() {
    super.initState();
    _mapController = MapController();
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
        _mapController.move(_currentPosition!, 15.0);
        _hasMovedToCurrentLocation = true;
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
          _mapController.move(_currentPosition!, 15.0);
          _hasMovedToCurrentLocation = true;
        }
      }
    });
  }

  /// 地図タップ時の処理
  void _onMapTap(TapPosition tapPosition, LatLng point) {
    setState(() {
      _tappedPoint = point;
    });

    // 場所情報ボトムシートを表示
    showPlaceInfoSheet(
      context: context,
      tappedPoint: point,
      onUploadPhoto: () {
        // 「この場所の写真を投稿する」ボタンが押されたらカメラボトムシートを開く
        _showImageSourceBottomSheet();
      },
    ).then((_) {
      // ボトムシートが閉じたらマーカーをクリア
      if (mounted) {
        setState(() {
          _tappedPoint = null;
        });
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
                leading: const Icon(Icons.camera_alt, color: AppColors.primaryNavy),
                title: const Text('カメラで撮影（精度: 高）'),
                subtitle: const Text('GPS+コンパスで街灯の実際の位置を推定します'),
                onTap: () {
                  Navigator.pop(context);
                  ref.read(selectedImageProvider.notifier).pickImageFromCamera();
                },
              ),
              ListTile(
                leading: const Icon(Icons.photo_library, color: AppColors.primaryNavy),
                title: const Text('ギャラリーから写真を選択'),
                subtitle: const Text('EXIFのGPS情報を自動抽出します'),
                onTap: () {
                  Navigator.pop(context);
                  ref.read(selectedImageProvider.notifier).pickImageFromGallery();
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
    _mapController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final imageState = ref.watch(selectedImageProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Row(
          children: [
            Icon(Icons.shield_outlined, color: AppColors.white),
            SizedBox(width: 8),
            Text(
              'SafeWay',
              style: TextStyle(fontWeight: FontWeight.bold, letterSpacing: 1.2),
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
                  Text('GPA 2026 アプリ部門受賞を目指す「安心」ナビゲーション。'),
                  SizedBox(height: 8),
                  Text('Phase 3: 場所検索・タップ詳細・API仕様書対応'),
                ],
              );
            },
          ),
        ],
      ),
      body: Stack(
        children: [
          // 1. 地図本体
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: _defaultCenter,
              initialZoom: 15.0,
              onTap: _onMapTap, // ← タップ検出
            ),
            children: [
              TileLayer(
                urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName: 'com.example.frontend',
              ),

              // 現在地マーカー
              if (_currentPosition != null)
                MarkerLayer(
                  markers: [
                    Marker(
                      point: _currentPosition!,
                      width: 60,
                      height: 60,
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          Container(
                            width: 36,
                            height: 36,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: AppColors.blueAccentLight
                                  .withValues(alpha: 0.3),
                            ),
                          ),
                          Container(
                            width: 18,
                            height: 18,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: AppColors.blueAccent,
                              border: Border.all(
                                  color: AppColors.white, width: 2),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withValues(alpha: 0.25),
                                  spreadRadius: 1,
                                  blurRadius: 4,
                                  offset: const Offset(0, 2),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),

              // タップ位置マーカー
              if (_tappedPoint != null)
                MarkerLayer(
                  markers: [
                    Marker(
                      point: _tappedPoint!,
                      width: 44,
                      height: 44,
                      child: Container(
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: AppColors.primaryNavy.withValues(alpha: 0.15),
                        ),
                        child: const Icon(
                          Icons.location_on,
                          color: AppColors.primaryNavy,
                          size: 32,
                        ),
                      ),
                    ),
                  ],
                ),
            ],
          ),

          // 2. 上部：検索バー
          MapSearchBar(mapController: _mapController),

          // 3. 画像プレビューカード（選択された時だけ）
          if (imageState.image != null)
            ImagePreviewCard(imageState: imageState),

          // 4. 右下のアクションボタン
          ActionButtons(
            mapController: _mapController,
            currentPosition: _currentPosition,
            onCameraPressed: _showImageSourceBottomSheet,
          ),

          // 5. GPSロード中インジケータ
          if (_isLoadingGps)
            Positioned(
              // 検索バーの下に表示
              top: 80,
              left: 16,
              right: 16,
              child: SafeArea(
                child: Center(
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        vertical: 8, horizontal: 16),
                    decoration: BoxDecoration(
                      color: AppColors.white.withValues(alpha: 0.9),
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
                          child: CircularProgressIndicator(strokeWidth: 2),
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
        ],
      ),
    );
  }
}
