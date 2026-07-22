import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/coverage_models.dart';
import '../services/api_service.dart';

class CoverageState {
  final bool isVisible;
  final List<CoverageCell> cells;
  final double cellSize;
  final bool isLoading;

  CoverageState({
    this.isVisible = false,
    this.cells = const [],
    this.cellSize = 0.0,
    this.isLoading = false,
  });

  CoverageState copyWith({
    bool? isVisible,
    List<CoverageCell>? cells,
    double? cellSize,
    bool? isLoading,
  }) {
    return CoverageState(
      isVisible: isVisible ?? this.isVisible,
      cells: cells ?? this.cells,
      cellSize: cellSize ?? this.cellSize,
      isLoading: isLoading ?? this.isLoading,
    );
  }
}

class CoverageNotifier extends StateNotifier<CoverageState> {
  final ApiService _apiService;

  CoverageNotifier(this._apiService) : super(CoverageState());

  void toggleVisibility() {
    state = state.copyWith(isVisible: !state.isVisible);
    if (!state.isVisible) {
      // 非表示時はセルのデータをクリア
      state = state.copyWith(cells: [], cellSize: 0.0);
    }
  }

  Future<void> fetchCoverage({
    required double minLat,
    required double minLng,
    required double maxLat,
    required double maxLng,
    required double zoom,
  }) async {
    // 表示OFFなら何もしない
    if (!state.isVisible) return;

    state = state.copyWith(isLoading: true);
    
    try {
      final response = await _apiService.fetchCoverage(
        minLat: minLat,
        minLng: minLng,
        maxLat: maxLat,
        maxLng: maxLng,
        zoom: zoom,
      );
      
      state = state.copyWith(
        cells: response.cells,
        cellSize: response.cellSize,
        isLoading: false,
      );
    } catch (e) {
      debugPrint('カバレッジの取得エラー: $e');
      state = state.copyWith(isLoading: false);
    }
  }
}

final coverageProvider = StateNotifierProvider<CoverageNotifier, CoverageState>((ref) {
  return CoverageNotifier(ref.read(apiServiceProvider));
});
