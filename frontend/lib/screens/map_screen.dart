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
      // 初期取得失敗時は無視してストリームへ
    }

    // ストリームで継続的な追従（更新頻度を下げて点滅を防止）
    _positionStream = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 10, // 10メートル以上動いた時だけ更新
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

  @override
  void dispose() {
    _positionStream?.cancel();
    _mapController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 全体をリビルドさせるのは画像の状態が変わった時だけ！
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
                applicationVersion: '1.0.0 (Phase 2)',
                applicationIcon: const Icon(Icons.shield, color: AppColors.primaryNavy, size: 40),
                children: [
                  const Text('GPA 2026 アプリ部門受賞を目指す「安心」ナビゲーション。'),
                  const SizedBox(height: 8),
                  const Text('Phase 2: 点滅バグ修正版・YOLO解析連携'),
                ],
              );
            },
          )
        ],
      ),
      body: Stack(
        children: [
          // 1. 地図表示
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: _defaultCenter,
              initialZoom: 15.0,
            ),
            children: [
              TileLayer(
                urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName: 'com.example.frontend',
              ),
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
                              color: AppColors.blueAccentLight.withValues(alpha: 0.3),
                            ),
                          ),
                          Container(
                            width: 18,
                            height: 18,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: AppColors.blueAccent,
                              border: Border.all(color: AppColors.white, width: 2),
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
            ],
          ),

          // 2. プレビュー画像（選択された時だけ）
          if (imageState.image != null)
            ImagePreviewCard(imageState: imageState),

          // 3. 右下のアクションボタン
          ActionButtons(
            mapController: _mapController,
            currentPosition: _currentPosition,
          ),

          // 4. GPSロード中インジケータ
          if (_isLoadingGps)
            Positioned(
              top: 16,
              left: 16,
              right: 16,
              child: SafeArea(
                child: Center(
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
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
                          style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: Colors.black87),
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
