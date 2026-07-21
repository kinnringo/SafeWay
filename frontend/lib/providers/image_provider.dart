import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:flutter_compass/flutter_compass.dart';
import '../models/analyze_result.dart';
import '../services/api_service.dart';

class ImageAnalyzeState {
  final XFile? image;
  final bool isAnalyzing;
  final AnalyzeResponse? analyzeResult;
  final String? errorMessage;

  const ImageAnalyzeState({
    this.image,
    this.isAnalyzing = false,
    this.analyzeResult,
    this.errorMessage,
  });

  ImageAnalyzeState copyWith({
    XFile? image,
    bool? isAnalyzing,
    AnalyzeResponse? analyzeResult,
    String? errorMessage,
    bool clearResult = false,
    bool clearError = false,
  }) {
    return ImageAnalyzeState(
      image: image ?? this.image,
      isAnalyzing: isAnalyzing ?? this.isAnalyzing,
      analyzeResult: clearResult ? null : (analyzeResult ?? this.analyzeResult),
      errorMessage:
          clearError ? null : (errorMessage ?? this.errorMessage),
    );
  }
}

class SelectedImageNotifier extends StateNotifier<ImageAnalyzeState> {
  final ApiService _apiService;
  final ImagePicker _picker = ImagePicker();

  SelectedImageNotifier(this._apiService) : super(const ImageAnalyzeState());

  /// モードA: カメラで撮影してAPIに送信
  ///
  /// 撮影直前にGPS座標とコンパス方位角を取得し、Formフィールドとして送信する。
  /// これにより、バックエンドの「物体の実際のGPS位置推定」が高精度（high）になる。
  Future<void> pickImageFromCamera() async {
    try {
      // 1. 撮影前にセンサー値を取得（コンパス方位角のみ）
      final bearing = await _getCompassBearing();

      // 2. カメラで撮影
      final XFile? image = await _picker.pickImage(
        source: ImageSource.camera,
      );
      if (image == null) return;

      // 3. 画像をセットして解析中状態に
      state = state.copyWith(
        image: image,
        isAnalyzing: true,
        clearResult: true,
        clearError: true,
      );

      // 4. モードA API呼び出し（bearing を送信、位置情報はEXIFから）
      final result = await _apiService.analyzeImageCamera(
        imageFile: image,
        bearing: bearing,
      );

      state = state.copyWith(isAnalyzing: false, analyzeResult: result);
    } catch (e) {
      state = state.copyWith(
        isAnalyzing: false,
        errorMessage: '解析中にエラーが発生しました: $e',
      );
    }
  }

  /// モードB: ギャラリーから過去写真を選択してAPIに送信
  ///
  /// 仕様書通り、画像のみ送信。バックエンドがEXIFから位置情報を自動抽出する。
  Future<void> pickImageFromGallery() async {
    try {
      final XFile? image = await _picker.pickImage(
        source: ImageSource.gallery,
      );
      if (image == null) return;

      state = state.copyWith(
        image: image,
        isAnalyzing: true,
        clearResult: true,
        clearError: true,
      );

      // モードB API呼び出し（画像のみ）
      final result = await _apiService.analyzeImageGallery(imageFile: image);
      state = state.copyWith(isAnalyzing: false, analyzeResult: result);
    } catch (e) {
      state = state.copyWith(
        isAnalyzing: false,
        errorMessage: '解析中にエラーが発生しました。EXIFにGPS情報がない写真は解析できません。',
      );
    }
  }

  void clearImage() {
    state = const ImageAnalyzeState();
  }

  /// コンパスの方位角を取得。Webや取得不可の場合はnullを返す。
  Future<double?> _getCompassBearing() async {
    // Webはコンパスをサポートしていないためスキップ
    if (kIsWeb) return null;
    try {
      final event = await FlutterCompass.events?.first;
      return event?.heading;
    } catch (_) {
      return null;
    }
  }
}

final selectedImageProvider =
    StateNotifierProvider<SelectedImageNotifier, ImageAnalyzeState>((ref) {
  final apiService = ref.watch(apiServiceProvider);
  return SelectedImageNotifier(apiService);
});
