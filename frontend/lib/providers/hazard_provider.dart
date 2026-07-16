import 'package:flutter_riverpod/flutter_riverpod.dart';

class HazardState {
  final bool isVisible;
  final double normalRadius;
  final double routingRadius;

  HazardState({
    this.isVisible = true,
    this.normalRadius = 20000.0,
    this.routingRadius = 1000.0,
  });

  HazardState copyWith({
    bool? isVisible,
    double? normalRadius,
    double? routingRadius,
  }) {
    return HazardState(
      isVisible: isVisible ?? this.isVisible,
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
