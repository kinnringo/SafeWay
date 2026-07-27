import 'package:flutter_riverpod/flutter_riverpod.dart';

class HazardState {
  final bool isVisible; // crime-reports系 (ハザード/危険情報) の表示
  final bool isDetectionsVisible; // detections系 (街灯/歩道などの資産) の表示
  final double normalRadius;
  final double routingRadius;

  HazardState({
    this.isVisible = true,
    this.isDetectionsVisible = true,
    this.normalRadius = 20000.0,
    this.routingRadius = 1000.0,
  });

  HazardState copyWith({
    bool? isVisible,
    bool? isDetectionsVisible,
    double? normalRadius,
    double? routingRadius,
  }) {
    return HazardState(
      isVisible: isVisible ?? this.isVisible,
      isDetectionsVisible: isDetectionsVisible ?? this.isDetectionsVisible,
      normalRadius: normalRadius ?? this.normalRadius,
      routingRadius: routingRadius ?? this.routingRadius,
    );
  }
}

class HazardNotifier extends StateNotifier<HazardState> {
  HazardNotifier() : super(HazardState());

  void toggleVisibility() {
    state = state.copyWith(isVisible: !state.isVisible);
  }

  void toggleDetectionsVisibility() {
    state = state.copyWith(isDetectionsVisible: !state.isDetectionsVisible);
  }

  void setNormalRadius(double val) {
    state = state.copyWith(normalRadius: val);
  }

  void setRoutingRadius(double val) {
    state = state.copyWith(routingRadius: val);
  }
}


final hazardProvider = StateNotifierProvider<HazardNotifier, HazardState>((ref) {
  return HazardNotifier();
});
