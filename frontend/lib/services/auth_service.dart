import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'api_service.dart';

// ── 認証状態の定義 ──────────────────────────────
enum AuthStatus { loading, authenticated, unauthenticated }

class AuthState {
  final AuthStatus status;
  final String? username;
  final String? token;

  const AuthState({
    required this.status,
    this.username,
    this.token,
  });

  const AuthState.loading() : this(status: AuthStatus.loading);
  const AuthState.authenticated({required String username, required String token})
      : this(status: AuthStatus.authenticated, username: username, token: token);
  const AuthState.unauthenticated() : this(status: AuthStatus.unauthenticated);
}

// ── AuthService: API通信 + SharedPreferences管理 ──
class AuthService {
  static const String _tokenKey = 'safeway_auth_token';

  /// shared_preferences からトークンを取得
  Future<String?> getToken() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_tokenKey);
  }

  /// トークンを shared_preferences に保存
  Future<void> _saveToken(String token) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_tokenKey, token);
  }

  /// トークンを shared_preferences から削除
  Future<void> clearToken() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_tokenKey);
  }

  /// ログイン: POST /api/auth/login
  Future<Map<String, String>> login(String username, String password) async {
    final uri = Uri.parse('${ApiService.baseUrl}/auth/login');
    try {
      final response = await http
          .post(
            uri,
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'username': username, 'password': password}),
          )
          .timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final token = data['access_token'] as String;
        await _saveToken(token);
        return {'access_token': token};
      } else if (response.statusCode == 401) {
        throw AuthException('ユーザー名またはパスワードが正しくありません。');
      } else {
        throw AuthException('ログインに失敗しました。(${response.statusCode})');
      }
    } catch (e) {
      if (e is AuthException) rethrow;
      debugPrint('[AuthService] login error: $e');
      throw AuthException('サーバーに接続できませんでした。バックエンドが起動しているか確認してください。');
    }
  }

  /// 新規登録: POST /api/auth/register
  Future<void> register(String username, String password) async {
    final uri = Uri.parse('${ApiService.baseUrl}/auth/register');
    try {
      final response = await http
          .post(
            uri,
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'username': username, 'password': password}),
          )
          .timeout(const Duration(seconds: 10));

      if (response.statusCode == 201) {
        return;
      } else if (response.statusCode == 409) {
        throw AuthException('このユーザー名はすでに使用されています。別のユーザー名をお試しください。');
      } else {
        throw AuthException('登録に失敗しました。(${response.statusCode})');
      }
    } catch (e) {
      if (e is AuthException) rethrow;
      debugPrint('[AuthService] register error: $e');
      throw AuthException('サーバーに接続できませんでした。バックエンドが起動しているか確認してください。');
    }
  }

  /// 現在のユーザー情報を取得: GET /api/auth/me
  Future<String?> getCurrentUser(String token) async {
    final uri = Uri.parse('${ApiService.baseUrl}/auth/me');
    try {
      final response = await http
          .get(
            uri,
            headers: {'Authorization': 'Bearer $token'},
          )
          .timeout(const Duration(seconds: 8));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        return data['username'] as String?;
      }
      return null;
    } catch (e) {
      debugPrint('[AuthService] getCurrentUser error: $e');
      return null;
    }
  }
}

// ── AuthException ────────────────────────────────
class AuthException implements Exception {
  final String message;
  const AuthException(this.message);

  @override
  String toString() => message;
}

// ── Riverpod: AuthNotifier ────────────────────────
class AuthNotifier extends StateNotifier<AuthState> {
  final AuthService _service;

  AuthNotifier(this._service) : super(const AuthState.loading()) {
    _initialize();
  }

  Future<void> _initialize() async {
    final token = await _service.getToken();
    if (token == null) {
      state = const AuthState.unauthenticated();
      return;
    }
    final username = await _service.getCurrentUser(token);
    if (username != null) {
      state = AuthState.authenticated(username: username, token: token);
    } else {
      await _service.clearToken();
      state = const AuthState.unauthenticated();
    }
  }

  Future<void> login(String username, String password) async {
    final result = await _service.login(username, password);
    final token = result['access_token']!;
    state = AuthState.authenticated(username: username, token: token);
  }

  Future<void> register(String username, String password) async {
    await _service.register(username, password);
  }

  Future<void> logout() async {
    await _service.clearToken();
    state = const AuthState.unauthenticated();
  }

  String? get currentToken => state.token;
}

// ── Riverpod Provider 定義 ────────────────────────
final authServiceProvider = Provider<AuthService>((ref) => AuthService());

final authProvider = StateNotifierProvider<AuthNotifier, AuthState>((ref) {
  return AuthNotifier(ref.watch(authServiceProvider));
});
