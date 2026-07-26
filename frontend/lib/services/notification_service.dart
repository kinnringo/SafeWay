import 'package:flutter/material.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../main.dart'; // rootScaffoldMessengerKey 用
import 'api_service.dart';
import 'auth_service.dart';

final notificationServiceProvider = Provider<NotificationService>((ref) {
  final service = NotificationService(ref);

  // 認証状態を監視し、ログインされたらFCMセットアップとトークン登録を行う
  ref.listen<AuthState>(authProvider, (previous, next) {
    // ログイン状態に切り替わった場合、または起動時からログイン状態だった場合に登録処理を走らせる
    if (next.status == AuthStatus.authenticated) {
      if (previous == null || previous.status != AuthStatus.authenticated) {
        service.setupAndRegisterToken();
      }
    }
  });

  return service;
});

class NotificationService {
  final Ref _ref;
  final FirebaseMessaging _messaging = FirebaseMessaging.instance;
  bool _isInitialized = false;

  NotificationService(this._ref);

  /// FCMの初期設定と権限リクエスト、デバイストークンの登録を行う
  Future<void> setupAndRegisterToken() async {
    if (!_isInitialized) {
      // フォアグラウンドでのプッシュ通知受信リスナー
      FirebaseMessaging.onMessage.listen((RemoteMessage message) {
        final notification = message.notification;
        if (notification != null) {
          rootScaffoldMessengerKey.currentState?.showSnackBar(
            SnackBar(
              content: Text('${notification.title ?? "通知"}\n${notification.body ?? ""}'),
              backgroundColor: const Color(0xFFE74C3C), // 赤系の警告色
              duration: const Duration(seconds: 8),
              behavior: SnackBarBehavior.floating,
              margin: const EdgeInsets.all(16.0),
            ),
          );
        }
      });

      // トークンが更新された際に自動で再登録するリスナー
      _messaging.onTokenRefresh.listen((newToken) {
        _registerDeviceToken(newToken);
      });

      _isInitialized = true;
    }

    // 権限のリクエスト（iOS向けに必須）
    await _messaging.requestPermission();

    // FCMトークンの取得
    try {
      final fcmToken = await _messaging.getToken();
      if (fcmToken != null) {
        await _registerDeviceToken(fcmToken);
      }
    } catch (e) {
      debugPrint('FCM Token generation failed: $e');
    }
  }

  /// 取得したFCMトークンをバックエンドへ登録する
  Future<void> _registerDeviceToken(String fcmToken) async {
    final jwtToken = _ref.read(authProvider).token;
    if (jwtToken == null) return;

    try {
      await _ref.read(apiServiceProvider).registerDeviceToken(
            jwtToken: jwtToken,
            fcmToken: fcmToken,
            notificationRadiusM: 5000.0,
          );
      debugPrint('FCM Token successfully registered to backend.');
    } catch (e) {
      debugPrint('Failed to register FCM token: $e');
    }
  }
}
