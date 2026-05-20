import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';
import '../providers/location_provider.dart';
import '../providers/image_provider.dart';
import '../core/theme.dart';

class ActionButtons extends ConsumerWidget {
  final MapController mapController;
  final LatLng? currentPosition;

  const ActionButtons({
    super.key,
    required this.mapController,
    required this.currentPosition,
  });

  void _showImageSourceBottomSheet(BuildContext context, WidgetRef ref) {
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
                title: const Text('カメラで撮影（街灯・危険箇所など）'),
                onTap: () {
                  Navigator.pop(context);
                  ref.read(selectedImageProvider.notifier).pickImageFromCamera();
                },
              ),
              ListTile(
                leading: const Icon(Icons.photo_library, color: AppColors.primaryNavy),
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
  Widget build(BuildContext context, WidgetRef ref) {
    final locationAsync = ref.watch(locationStreamProvider);

    return Positioned(
      right: 16,
      bottom: 16,
      child: SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 現在地追従ボタン
            FloatingActionButton(
              heroTag: 'currentLocationBtn',
              onPressed: () {
                if (currentPosition != null) {
                  mapController.move(currentPosition!, 16.0);
                } else {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('GPS現在地を取得中です。少々お待ちください。'),
                      duration: Duration(seconds: 2),
                    ),
                  );
                }
              },
              backgroundColor: AppColors.white,
              foregroundColor: AppColors.primaryNavy,
              elevation: 4,
              child: locationAsync.when(
                data: (_) => const Icon(Icons.my_location),
                error: (error, stack) => const Icon(Icons.location_off, color: Colors.red),
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
              onPressed: () => _showImageSourceBottomSheet(context, ref),
              backgroundColor: AppColors.emeraldGreen,
              foregroundColor: AppColors.white,
              elevation: 6,
              child: const Icon(Icons.camera_alt, size: 32),
            ),
          ],
        ),
      ),
    );
  }
}
