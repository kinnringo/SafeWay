import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import '../models/analyze_result.dart';
import '../services/api_service.dart';

class ImageAnalyzeState {
  final XFile? image;
  final bool isAnalyzing;
  final AnalyzeResponse? analyzeResult;

  ImageAnalyzeState({
    this.image,
    this.isAnalyzing = false,
    this.analyzeResult,
  });

  ImageAnalyzeState copyWith({
    XFile? image,
    bool? isAnalyzing,
    AnalyzeResponse? analyzeResult,
    bool clearResult = false,
  }) {
    return ImageAnalyzeState(
      image: image ?? this.image,
      isAnalyzing: isAnalyzing ?? this.isAnalyzing,
      analyzeResult: clearResult ? null : (analyzeResult ?? this.analyzeResult),
    );
  }
}

class SelectedImageNotifier extends StateNotifier<ImageAnalyzeState> {
  final ApiService _apiService;
  final ImagePicker _picker = ImagePicker();

  SelectedImageNotifier(this._apiService) : super(ImageAnalyzeState());

  Future<void> pickImageFromCamera() async {
    try {
      final XFile? image = await _picker.pickImage(
        source: ImageSource.camera,
        maxWidth: 1024,
        maxHeight: 1024,
        imageQuality: 80,
      );
      if (image != null) {
        await _processImage(image);
      }
    } catch (e) {
      // 権限エラー時等
    }
  }

  Future<void> pickImageFromGallery() async {
    try {
      final XFile? image = await _picker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 1024,
        maxHeight: 1024,
        imageQuality: 80,
      );
      if (image != null) {
        await _processImage(image);
      }
    } catch (e) {
      // エラーハンドリング
    }
  }

  Future<void> _processImage(XFile image) async {
    // 画像をセットし、解析中状態にする
    state = state.copyWith(image: image, isAnalyzing: true, clearResult: true);

    try {
      // APIサービスを呼び出して解析を実行
      final result = await _apiService.analyzeImage(File(image.path));
      // 解析完了
      state = state.copyWith(isAnalyzing: false, analyzeResult: result);
    } catch (e) {
      // エラー時はローディングを解除して結果なし
      state = state.copyWith(isAnalyzing: false);
    }
  }

  void clearImage() {
    state = ImageAnalyzeState(); // 初期状態に戻す
  }
}

final selectedImageProvider = StateNotifierProvider<SelectedImageNotifier, ImageAnalyzeState>((ref) {
  final apiService = ref.watch(apiServiceProvider);
  return SelectedImageNotifier(apiService);
});
