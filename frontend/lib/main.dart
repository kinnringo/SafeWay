import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'core/theme.dart';
import 'screens/map_screen.dart';
import 'screens/login_screen.dart';
import 'services/auth_service.dart';
import 'services/notification_service.dart';

import 'package:firebase_core/firebase_core.dart';

final GlobalKey<ScaffoldMessengerState> rootScaffoldMessengerKey = GlobalKey<ScaffoldMessengerState>();

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  if (!kIsWeb) {
    try {
      await Firebase.initializeApp();
    } catch (e) {
      debugPrint('Firebase initialization failed: $e');
    }
  }

  runApp(
    const ProviderScope(
      child: SafeWayApp(),
    ),
  );
}

class SafeWayApp extends StatelessWidget {
  const SafeWayApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SafeWay',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.lightTheme,
      scaffoldMessengerKey: rootScaffoldMessengerKey,
      home: const _AuthGate(),
    );
  }
}

/// アプリ起動時の認証状態に応じて表示する画面を切り替えるゲート
class _AuthGate extends ConsumerWidget {
  const _AuthGate();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 起動時からFCMリスナーや認証状態の監視を有効にする
    ref.watch(notificationServiceProvider);

    final authState = ref.watch(authProvider);

    switch (authState.status) {
      case AuthStatus.loading:
        // トークン検証中: スプラッシュ的なローディング画面
        return const Scaffold(
          backgroundColor: Color(0xFFF0F4FF),
          body: Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.shield_rounded,
                  color: AppColors.primaryNavy,
                  size: 56,
                ),
                SizedBox(height: 20),
                CircularProgressIndicator(
                  color: AppColors.primaryNavy,
                  strokeWidth: 2.5,
                ),
              ],
            ),
          ),
        );

      case AuthStatus.authenticated:
        return const MapScreen();

      case AuthStatus.unauthenticated:
        return const LoginScreen();
    }
  }
}