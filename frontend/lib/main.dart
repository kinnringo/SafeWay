import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'providers/location_provider.dart';
import 'providers/image_provider.dart';

void main() {
  runApp(
    const ProviderScope(
      child: SafeWayApp(),
    ),
  );
}

class SafeWayApp extends StatelessWidget {
  const SafeWayApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SafeWay',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF1E3A8A), // プレミアムなディープネイビー
          primary: const Color(0xFF1E3A8A),
          secondary: const Color(0xFF10B981), // 安全をイメージするエメラルドグリーン
        ),
        useMaterial3: true,
      ),
      home: const MapScreen(),
    );
  }
}

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

  /// カメラ・ギャラリー選択のボトムシートを表示
  void _showImageSourceBottomSheet(BuildContext context) {
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
                    color: Color(0xFF1E3A8A),
                  ),
                ),
              ),
              ListTile(
                leading: const Icon(Icons.camera_alt, color: Color(0xFF1E3A8A)),
                title: const Text('カメラで撮影（街灯・危険箇所など）'),
                onTap: () {
                  Navigator.pop(context);
                  ref.read(selectedImageProvider.notifier).pickImageFromCamera();
                },
              ),
              ListTile(
                leading: const Icon(Icons.photo_library, color: Color(0xFF1E3A8A)),
                title: const Text('ギャラリーから写真を選択'),
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
  Widget build(BuildContext context) {
    final locationAsync = ref.watch(locationStreamProvider);
    final selectedImage = ref.watch(selectedImageProvider);

    // 初期位置（前橋駅）
    LatLng centerPosition = const LatLng(36.3895, 139.0634);
    LatLng? currentPosition;

    locationAsync.whenData((Position position) {
      currentPosition = LatLng(position.latitude, position.longitude);

      // 初回取得時のみ現在地に地図の中心を自動移動
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
            Icon(Icons.shield_outlined, color: Colors.white),
            SizedBox(width: 8),
            Text(
              'SafeWay',
              style: TextStyle(fontWeight: FontWeight.bold, letterSpacing: 1.2),
            ),
          ],
        ),
        backgroundColor: const Color(0xFF1E3A8A),
        foregroundColor: Colors.white,
        elevation: 4,
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
                  color: Color(0xFF1E3A8A),
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
            options: MapOptions(
              initialCenter: centerPosition,
              initialZoom: 15.0,
            ),
            children: [
              TileLayer(
                urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName: 'com.example.frontend',
              ),
              // 現在地マーカーの描画
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
                          // パルスアニメーション風の半透明の外円
                          Container(
                            width: 36,
                            height: 36,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: const Color(0xFF3B82F6).withOpacity(0.3),
                            ),
                          ),
                          // 白枠付きの青い円
                          Container(
                            width: 18,
                            height: 18,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: const Color(0xFF2563EB),
                              border: Border.all(color: Colors.white, width: 2),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withOpacity(0.25),
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

          // 2. 選択された画像のプレミアムプレビューカード
          if (selectedImage != null)
            Positioned(
              left: 16,
              bottom: 16,
              child: Card(
                elevation: 10,
                shadowColor: Colors.black.withOpacity(0.3),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
                clipBehavior: Clip.antiAlias,
                child: Container(
                  width: 130,
                  height: 130,
                  color: Colors.grey[200],
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      // 画像本体
                      Image.file(
                        File(selectedImage.path),
                        fit: BoxFit.cover,
                      ),
                      // 右上の丸い「×」ボタン
                      Positioned(
                        top: 6,
                        right: 6,
                        child: GestureDetector(
                          onTap: () {
                            ref.read(selectedImageProvider.notifier).clearImage();
                          },
                          child: Container(
                            decoration: const BoxDecoration(
                              color: Colors.black54,
                              shape: BoxShape.circle,
                            ),
                            padding: const EdgeInsets.all(4),
                            child: const Icon(
                              Icons.close,
                              color: Colors.white,
                              size: 16,
                            ),
                          ),
                        ),
                      ),
                      // ラベル
                      Positioned(
                        bottom: 0,
                        left: 0,
                        right: 0,
                        child: Container(
                          color: Colors.black54,
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: const Text(
                            'プレビュー画像',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),

          // 3. 右下のボタンコントローラー (現在地追従と撮影)
          Positioned(
            right: 16,
            bottom: 16,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // 現在地追従ボタン
                FloatingActionButton(
                  heroTag: 'currentLocationBtn',
                  onPressed: () {
                    if (currentPosition != null) {
                      _mapController.move(currentPosition!, 16.0);
                    } else {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('GPS現在地を取得中です。少々お待ちください。'),
                          duration: Duration(seconds: 2),
                        ),
                      );
                    }
                  },
                  backgroundColor: Colors.white,
                  foregroundColor: const Color(0xFF1E3A8A),
                  elevation: 4,
                  child: locationAsync.when(
                    data: (_) => const Icon(Icons.my_location),
                    error: (_, __) => const Icon(Icons.location_off, color: Colors.red),
                    loading: () => const SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                // カメラ起動・写真投稿ボタン
                FloatingActionButton.large(
                  heroTag: 'takePhotoBtn',
                  onPressed: () => _showImageSourceBottomSheet(context),
                  backgroundColor: const Color(0xFF10B981), // エメラルドグリーン
                  foregroundColor: Colors.white,
                  elevation: 6,
                  child: const Icon(Icons.camera_alt, size: 32),
                ),
              ],
            ),
          ),

          // 4. GPSロード中インジケータ（上部オーバーレイ）
          if (locationAsync.isLoading)
            Positioned(
              top: 16,
              left: 16,
              right: 16,
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.9),
                    borderRadius: BorderRadius.circular(20),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.1),
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
        ],
      ),
    );
  }
}