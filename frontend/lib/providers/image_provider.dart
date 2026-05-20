import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

/// 選択された画像を保持・操作するNotifier
class SelectedImageNotifier extends StateNotifier<XFile?> {
  SelectedImageNotifier() : super(null);

  final ImagePicker _picker = ImagePicker();

  /// カメラを起動して写真を撮影する
  Future<void> pickImageFromCamera() async {
    try {
      final XFile? image = await _picker.pickImage(
        source: ImageSource.camera,
        maxWidth: 1024,
        maxHeight: 1024,
        imageQuality: 80, // サーバーアップロードに備えて軽量化
      );
      if (image != null) {
        state = image;
      }
    } catch (e) {
      // 権限エラーやユーザーキャンセル時は何もしない
    }
  }

  /// ギャラリーを開いて画像を選択する
  Future<void> pickImageFromGallery() async {
    try {
      final XFile? image = await _picker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 1024,
        maxHeight: 1024,
        imageQuality: 80,
      );
      if (image != null) {
        state = image;
      }
    } catch (e) {
      // エラーハンドリング
    }
  }

  /// 選択されている画像をクリアする
  void clearImage() {
    state = null;
  }
}

/// 選択された画像をグローバルに提供するプロバイダー
final selectedImageProvider = StateNotifierProvider<SelectedImageNotifier, XFile?>((ref) {
  return SelectedImageNotifier();
});
