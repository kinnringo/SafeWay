import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/saved_route_models.dart';
import '../services/api_service.dart';
import '../services/auth_service.dart';
import '../core/theme.dart';
import '../providers/map_theme_provider.dart';

class SavedRoutesSheet extends ConsumerStatefulWidget {
  final void Function(SavedRoute route) onSelectRoute;

  const SavedRoutesSheet({super.key, required this.onSelectRoute});

  @override
  ConsumerState<SavedRoutesSheet> createState() => _SavedRoutesSheetState();
}

class _SavedRoutesSheetState extends ConsumerState<SavedRoutesSheet> {
  List<SavedRoute> _routes = [];
  bool _isLoading = true;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _fetchRoutes();
  }

  Future<void> _fetchRoutes() async {
    final authState = ref.read(authProvider);
    if (authState.status != AuthStatus.authenticated || authState.token == null) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _errorMessage = '保存されたルートを表示するにはログインが必要です。';
        });
      }
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final apiService = ref.read(apiServiceProvider);
      final list = await apiService.getSavedRoutes(token: authState.token!);
      if (mounted) {
        setState(() {
          _routes = list;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _errorMessage = '一覧の取得に失敗しました。時間をおいてやり直してください。';
        });
      }
    }
  }

  Future<void> _deleteRoute(int routeId) async {
    final authState = ref.read(authProvider);
    if (authState.token == null) return;

    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('削除の確認', style: TextStyle(fontWeight: FontWeight.bold)),
        content: const Text('この保存ルートと、関連する沿道危険通知のアラート履歴を削除してもよろしいですか？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('キャンセル', style: TextStyle(color: Colors.grey)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('削除'),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    final apiService = ref.read(apiServiceProvider);
    final success = await apiService.deleteSavedRoute(
      token: authState.token!,
      routeId: routeId,
    );

    if (success && mounted) {
      setState(() {
        _routes.removeWhere((item) => item.id == routeId);
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('ルートを削除しました。'),
          backgroundColor: Colors.green.shade700,
        ),
      );
    } else if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('ルートの削除に失敗しました。'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  String _formatDate(String isoString) {
    try {
      final DateTime d = DateTime.parse(isoString).toLocal();
      final year = d.year;
      final month = d.month.toString().padLeft(2, '0');
      final day = d.day.toString().padLeft(2, '0');
      final hour = d.hour.toString().padLeft(2, '0');
      final min = d.minute.toString().padLeft(2, '0');
      return '$year/$month/$day $hour:$min';
    } catch (_) {
      return isoString;
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = ref.watch(mapThemeProvider);
    final bgColor = isDark ? AppColors.darkCard : Colors.white;
    final textColor = isDark ? AppColors.darkTextPrimary : Colors.black87;
    final subTextColor = isDark ? AppColors.darkTextSecondary : Colors.grey.shade700;

    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.75,
      ),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        boxShadow: const [
          BoxShadow(
            color: Colors.black26,
            blurRadius: 10,
            offset: Offset(0, -2),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 12),
          // ドロッグハンドル
          Container(
            width: 40,
            height: 5,
            decoration: BoxDecoration(
              color: Colors.grey.shade400,
              borderRadius: BorderRadius.circular(10),
            ),
          ),
          const SizedBox(height: 16),
          // ヘッダータイトル
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Row(
              children: [
                Icon(
                  Icons.bookmarks_rounded,
                  color: isDark ? AppColors.emeraldGreen : AppColors.primaryNavy,
                  size: 26,
                ),
                const SizedBox(width: 10),
                Text(
                  '保存したルート一覧',
                  style: TextStyle(
                    fontSize: 19,
                    fontWeight: FontWeight.bold,
                    color: textColor,
                  ),
                ),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.refresh, color: Colors.grey),
                  onPressed: _fetchRoutes,
                  tooltip: '最新に更新',
                ),
                IconButton(
                  icon: Icon(Icons.close, color: textColor),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
          ),
          const Divider(),
          // リスト内容
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : _errorMessage != null
                    ? _buildErrorOrEmptyState(Icons.lock_outline, _errorMessage!, subTextColor)
                    : _routes.isEmpty
                        ? _buildErrorOrEmptyState(Icons.route_outlined, 'まだ保存されたルートがありません。\n経路案内中の「ルートを保存」ボタンから追加できます。', subTextColor)
                        : ListView.separated(
                            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                            itemCount: _routes.length,
                            separatorBuilder: (ctx, index) => const SizedBox(height: 12),
                            itemBuilder: (ctx, index) {
                              final route = _routes[index];
                              final isSafe = route.routeType == 'safe';
                              final badgeColor = isSafe ? const Color(0xFF2ECC71) : const Color(0xFF3498DB);
                              final badgeText = isSafe ? '安全優先 🛡' : '最短距離 📍';

                              return Container(
                                decoration: BoxDecoration(
                                  color: isDark ? const Color(0xFF2C3E50) : const Color(0xFFF8F9FA),
                                  borderRadius: BorderRadius.circular(16),
                                  border: Border.all(
                                    color: isDark ? Colors.blueGrey.shade700 : Colors.grey.shade300,
                                    width: 1.2,
                                  ),
                                  boxShadow: const [
                                    BoxShadow(
                                      color: Colors.black12,
                                      blurRadius: 4,
                                      offset: Offset(0, 2),
                                    ),
                                  ],
                                ),
                                child: InkWell(
                                  borderRadius: BorderRadius.circular(16),
                                  onTap: () {
                                    Navigator.of(context).pop();
                                    widget.onSelectRoute(route);
                                  },
                                  child: Padding(
                                    padding: const EdgeInsets.all(16),
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Row(
                                          children: [
                                            // ルート種別バッジ
                                            Container(
                                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                              decoration: BoxDecoration(
                                                color: isSafe
                                                    ? const Color(0xFF2ECC71).withAlpha(40)
                                                    : const Color(0xFF3498DB).withAlpha(40),
                                                borderRadius: BorderRadius.circular(8),
                                                border: Border.all(color: badgeColor, width: 1.5),
                                              ),
                                              child: Text(
                                                badgeText,
                                                style: TextStyle(
                                                  color: badgeColor,
                                                  fontWeight: FontWeight.bold,
                                                  fontSize: 12,
                                                ),
                                              ),
                                            ),
                                            const SizedBox(width: 8),
                                            // 通知範囲
                                            Text(
                                              '通知範囲: ${route.notificationRadiusM.round()}m',
                                              style: TextStyle(
                                                fontSize: 12,
                                                color: subTextColor,
                                              ),
                                            ),
                                            const Spacer(),
                                            // 削除ボタン
                                            InkWell(
                                              onTap: () => _deleteRoute(route.id),
                                              borderRadius: BorderRadius.circular(20),
                                              child: const Padding(
                                                padding: EdgeInsets.all(6.0),
                                                child: Icon(Icons.delete_outline, color: Colors.redAccent, size: 22),
                                              ),
                                            ),
                                          ],
                                        ),
                                        const SizedBox(height: 10),
                                        // 名称・目的地表示
                                        Text(
                                          route.name ?? '保存したルート #${route.id}',
                                          style: TextStyle(
                                            fontSize: 16,
                                            fontWeight: FontWeight.bold,
                                            color: textColor,
                                          ),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                        const SizedBox(height: 6),
                                        Row(
                                          children: [
                                            Icon(Icons.access_time_rounded, size: 14, color: subTextColor),
                                            const SizedBox(width: 4),
                                            Text(
                                              '保存日時: ${_formatDate(route.createdAt)}',
                                              style: TextStyle(
                                                fontSize: 12,
                                                color: subTextColor,
                                              ),
                                            ),
                                            const Spacer(),
                                            // 読込ナビゲーション矢印
                                            Row(
                                              children: [
                                                Text(
                                                  '読み込んで案内',
                                                  style: TextStyle(
                                                    fontSize: 13,
                                                    fontWeight: FontWeight.w600,
                                                    color: isDark ? AppColors.emeraldGreen : AppColors.primaryNavy,
                                                  ),
                                                ),
                                                const SizedBox(width: 4),
                                                Icon(
                                                  Icons.arrow_forward_ios_rounded,
                                                  size: 14,
                                                  color: isDark ? AppColors.emeraldGreen : AppColors.primaryNavy,
                                                ),
                                              ],
                                            ),
                                          ],
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              );
                            },
                          ),
          ),
          const SizedBox(height: 12),
        ],
      ),
    );
  }

  Widget _buildErrorOrEmptyState(IconData icon, String message, Color subColor) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 50, color: Colors.grey.shade400),
            const SizedBox(height: 14),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 15, color: subColor, height: 1.5),
            ),
          ],
        ),
      ),
    );
  }
}
