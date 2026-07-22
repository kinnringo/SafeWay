import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/theme.dart';
import '../providers/map_theme_provider.dart';
import '../services/auth_service.dart';

class MyPageScreen extends ConsumerStatefulWidget {
  const MyPageScreen({super.key});

  @override
  ConsumerState<MyPageScreen> createState() => _MyPageScreenState();
}

class _MyPageScreenState extends ConsumerState<MyPageScreen> {
  Map<String, dynamic>? _userData;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _fetchUserData();
  }

  Future<void> _fetchUserData() async {
    final token = ref.read(authProvider).token;
    if (token == null) {
      setState(() => _isLoading = false);
      return;
    }
    final data = await ref.read(authServiceProvider).getCurrentUser(token);
    if (mounted) {
      setState(() {
        _userData = data;
        _isLoading = false;
      });
    }
  }

  Future<void> _handleLogout() async {
    final bool? confirm = await showDialog<bool>(
      context: context,
      builder: (context) {
        final isDark = ref.watch(mapThemeProvider);
        final bgColor = isDark ? AppColors.darkSurface : Colors.white;
        final textColor = isDark ? AppColors.darkTextPrimary : AppColors.primaryNavy;

        return AlertDialog(
          backgroundColor: bgColor,
          title: Text('ログアウト', style: TextStyle(color: textColor)),
          content: Text('ログアウトしますか？', style: TextStyle(color: textColor)),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text('キャンセル', style: TextStyle(color: Colors.grey.shade600)),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text('はい', style: TextStyle(color: Colors.red.shade700, fontWeight: FontWeight.bold)),
            ),
          ],
        );
      },
    );

    if (confirm == true) {
      // ログアウト処理
      await ref.read(authProvider.notifier).logout();
      
      if (!mounted) return;
      
      // 完了通知（SnackBar）の表示
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('ログアウトしました'),
          backgroundColor: AppColors.primaryNavy,
          behavior: SnackBarBehavior.floating,
        ),
      );

      // マイページやダイアログなどをすべて閉じ、根元の画面（ログイン画面）を表示する
      Navigator.of(context).popUntil((route) => route.isFirst);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = ref.watch(mapThemeProvider);
    final bgColor = isDark ? AppColors.darkSurface : const Color(0xFFF0F4FF);
    final cardColor = isDark ? AppColors.darkCard : Colors.white;
    final textColor = isDark ? AppColors.darkTextPrimary : AppColors.primaryNavy;
    final subTextColor = isDark ? AppColors.darkTextSecondary : Colors.grey.shade600;
    
    return Scaffold(
      backgroundColor: bgColor,
      appBar: AppBar(
        title: const Text('マイページ', style: TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: AppColors.primaryNavy,
        foregroundColor: Colors.white,
        elevation: 0,
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator(color: AppColors.primaryNavy))
          : _userData == null
              ? Center(
                  child: Text('ユーザー情報の取得に失敗しました', style: TextStyle(color: textColor)),
                )
              : _buildProfileContent(context, cardColor, textColor, subTextColor),
    );
  }

  Widget _buildProfileContent(BuildContext context, Color cardColor, Color textColor, Color subTextColor) {
    final username = _userData!['username'] as String? ?? 'ゲスト';
    final initial = username.isNotEmpty ? username[0].toUpperCase() : '?';
    final coins = _userData!['coins'] as int? ?? 0;
    
    // 日付のフォーマット (簡易的)
    String formattedDate = '-';
    if (_userData!['created_at'] != null) {
      try {
        final date = DateTime.parse(_userData!['created_at'] as String);
        formattedDate = '${date.year}/${date.month.toString().padLeft(2, '0')}/${date.day.toString().padLeft(2, '0')}';
      } catch (_) {}
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ── プロフィールヘッダー ──
          Container(
            padding: const EdgeInsets.symmetric(vertical: 32, horizontal: 16),
            decoration: BoxDecoration(
              color: cardColor,
              borderRadius: BorderRadius.circular(20),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.05),
                  blurRadius: 10,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Column(
              children: [
                CircleAvatar(
                  radius: 48,
                  backgroundColor: AppColors.blueAccentLight,
                  child: Text(
                    initial,
                    style: const TextStyle(fontSize: 40, fontWeight: FontWeight.bold, color: Colors.white),
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  username,
                  style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: textColor),
                ),
                const SizedBox(height: 4),
                Text(
                  '登録日: $formattedDate',
                  style: TextStyle(fontSize: 14, color: subTextColor),
                ),
              ],
            ),
          ),
          
          const SizedBox(height: 24),
          
          // ── 統計カード ──
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: cardColor,
              borderRadius: BorderRadius.circular(20),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.05),
                  blurRadius: 10,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.amber.withValues(alpha: 0.15),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.monetization_on_rounded, color: Colors.amber, size: 28),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('保有コイン', style: TextStyle(fontSize: 14, color: subTextColor)),
                      Text('$coins 枚', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: textColor)),
                    ],
                  ),
                ),
              ],
            ),
          ),
          
          const SizedBox(height: 40),
          
          // ── ログアウトボタン ──
          FilledButton.icon(
            onPressed: _handleLogout,
            style: FilledButton.styleFrom(
              backgroundColor: Colors.red.shade600,
              padding: const EdgeInsets.symmetric(vertical: 16),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
            ),
            icon: const Icon(Icons.logout_rounded, color: Colors.white),
            label: const Text(
              'ログアウト',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white),
            ),
          ),
          
          const SizedBox(height: 24),
          Center(
            child: Text(
              'v1.0.0',
              style: TextStyle(fontSize: 12, color: subTextColor),
            ),
          ),
        ],
      ),
    );
  }
}
