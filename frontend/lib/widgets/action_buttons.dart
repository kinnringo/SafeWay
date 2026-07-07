import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import '../providers/location_provider.dart';
import '../core/theme.dart';

class ActionButtons extends ConsumerWidget {
  final GoogleMapController? mapController;
  final LatLng? currentPosition;
  final VoidCallback onCameraPressed;

  const ActionButtons({
    super.key,
    required this.mapController,
    required this.currentPosition,
    required this.onCameraPressed,
  });

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
                if (currentPosition != null && mapController != null) {
                  mapController!.animateCamera(
                    CameraUpdate.newLatLngZoom(currentPosition!, 16.0),
                  );
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
                error: (error, stack) =>
                    const Icon(Icons.location_off, color: Colors.red),
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
              onPressed: onCameraPressed,
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
