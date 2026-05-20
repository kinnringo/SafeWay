import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import '../providers/location_provider.dart';
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
  bool _hasMovedToCurrentLocation = false;

  @override
  void initState() {
    super.initState();
    _mapController = MapController();
  }

  @override
  void dispose() {
    _mapController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final locationAsync = ref.watch(locationStreamProvider);
    final selectedImage = ref.watch(selectedImageProvider);

    // 初期位置（前橋駅）
    const LatLng centerPosition = LatLng(36.3895, 139.0634);
    LatLng? currentPosition;

    locationAsync.whenData((Position position) {
      currentPosition = LatLng(position.latitude, position.longitude);

      if (!_hasMovedToCurrentLocation && currentPosition != null) {
        _hasMovedToCurrentLocation = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _mapController.move(currentPosition!, 15.0);
        });
      }
    });

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
                applicationVersion: '1.0.0 (Phase 1)',
                applicationIcon: const Icon(
                  Icons.shield,
                  color: AppColors.primaryNavy,
                  size: 40,
                ),
                children: [
                  const Text('GPA 2026 アプリ部門受賞を目指す「安心」ナビゲーション。'),
                  const SizedBox(height: 8),
                  const Text('Phase 1: 現在地GPS連動・写真撮影シミュレーション機能'),
                ],
              );
            },
          )
        ],
      ),
      body: Stack(
        children: [
          // 1. 地図表示 (OpenStreetMap)
          FlutterMap(
            mapController: _mapController,
            options: const MapOptions(
              initialCenter: centerPosition,
              initialZoom: 15.0,
            ),
            children: [
              TileLayer(
                urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName: 'com.example.frontend',
              ),
              if (currentPosition != null)
                MarkerLayer(
                  markers: [
                    Marker(
                      point: currentPosition!,
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

          // 2. 選択された画像のプレビューカード
          if (selectedImage != null)
            ImagePreviewCard(imageFile: selectedImage),

          // 3. 右下のボタンコントローラー
          ActionButtons(
            mapController: _mapController,
            currentPosition: currentPosition,
          ),

          // 4. GPSロード中インジケータ
          if (locationAsync.isLoading)
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
