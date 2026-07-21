import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// マップのダークモード状態を保持するプロバイダー
final mapThemeProvider = StateNotifierProvider<MapThemeNotifier, bool>((ref) {
  return MapThemeNotifier();
});

class MapThemeNotifier extends StateNotifier<bool> {
  MapThemeNotifier() : super(false) {
    _loadTheme();
  }

  static const _themeKey = 'map_is_dark_mode';

  /// 保存されたテーマ設定を読み込む
  Future<void> _loadTheme() async {
    final prefs = await SharedPreferences.getInstance();
    final isDark = prefs.getBool(_themeKey) ?? false;
    state = isDark;
  }

  /// テーマを切り替えて保存する
  Future<void> toggleTheme(bool isDark) async {
    state = isDark;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_themeKey, isDark);
  }
}
