import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:image_picker/image_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import '../models/analyze_result.dart';
import '../models/route_models.dart';
import '../models/coverage_models.dart';

final apiServiceProvider = Provider<ApiService>((ref) => ApiService());

class ApiService {
  // バックエンドのURL
  // MacのiOSシミュレータやWebブラウザでテストする場合は 127.0.0.1 で繋がります。
  // iPhone実機でテストする場合は、MacのIPアドレス（例: 192.168.1.5等）に変更してください！
  // static const String baseUrl = 'http://127.0.0.1:8000/api';
  // android用↓
  static const String baseUrl = 'http://10.0.2.2:8000/api';

  /// 認証ヘッダーを含む Map を生成するユーティリティ
  ///
  /// [token] が null の場合は通常の JSON ヘッダーのみを返す。
  /// 認証が必要なエンドポイントを呼び出す際に使用する。
  ///   例: http.get(uri, headers: ApiService.authorizedHeaders(token))
  static Map<String, String> authorizedHeaders(String? token) {
    return {
      'Content-Type': 'application/json',
      if (token != null) 'Authorization': 'Bearer $token',
    };
  }

  /// モードA: ライブカメラ撮影モード
  ///
  /// 仕様書 Section 4 モードA に準拠。
  /// GPS座標・コンパス方位角（bearing）・焦点距離をFormフィールドとして一緒に送信する。
  /// これにより、バックエンドが「物体の実際のGPS位置」を高精度で推定できる。
  ///
  /// [imageFile] 撮影した画像ファイル
  /// [lat] 撮影者の緯度
  /// [lng] 撮影者の経度
  /// [bearing] コンパス方位角（0〜360°, 0=北, 時計回り）。取得できない場合はnull。
  /// [focalLength35mm] 35mm換算焦点距離。EXIFから取得できない場合はnull。
  Future<AnalyzeResponse> analyzeImageCamera({
    required XFile imageFile,
    double? bearing,
    double? focalLength35mm,
    String? token,
  }) async {
    final request = http.MultipartRequest(
      'POST',
      Uri.parse('$baseUrl/analyze'),
    );

    if (token != null) {
      request.headers['Authorization'] = 'Bearer $token';
    }

    // 画像をバイトデータとして添付（Web・モバイル両対応）
    final bytes = await imageFile.readAsBytes();
    request.files.add(
      http.MultipartFile.fromBytes('image', bytes, filename: imageFile.name),
    );

    // コンパス方位角を 0〜360 に正規化して送信（仕様書 Section 6-4 準拠）
    if (bearing != null) {
      final normalizedBearing = (bearing % 360 + 360) % 360;
      request.fields['bearing'] = normalizedBearing.toString();
    }

    // 焦点距離を送信（あれば position_accuracy: "high" になる）
    if (focalLength35mm != null) {
      request.fields['focal_length_35mm'] = focalLength35mm.toString();
    }

    return _sendRequest(request);
  }

  /// モードB: ギャラリーから過去写真を選択するモード
  ///
  /// 仕様書 Section 4 モードB に準拠。
  /// 画像ファイルのみ送信。バックエンドがEXIFからGPS・bearing等を自動抽出する。
  /// EXIF が存在しない場合は position_accuracy: "low" になるがエラーにはならない。
  Future<AnalyzeResponse> analyzeImageGallery({
    required XFile imageFile,
    String? token,
  }) async {
    final request = http.MultipartRequest(
      'POST',
      Uri.parse('$baseUrl/analyze'),
    );

    if (token != null) {
      request.headers['Authorization'] = 'Bearer $token';
    }

    // 画像のみ送信（仕様書通り）
    final bytes = await imageFile.readAsBytes();
    request.files.add(
      http.MultipartFile.fromBytes('image', bytes, filename: imageFile.name),
    );

    // デバッグ時のみ test_mode を有効化（リリース版では使用しない）
    if (kDebugMode) {
      request.fields['test_mode'] = 'true';
    }

    return _sendRequest(request);
  }

  /// FCMデバイストークンをバックエンドに登録する
  Future<void> registerDeviceToken({
    required String jwtToken,
    required String fcmToken,
    double notificationRadiusM = 5000.0,
  }) async {
    final response = await http.post(
      Uri.parse('$baseUrl/notifications/register'),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $jwtToken',
      },
      body: jsonEncode({
        'fcm_token': fcmToken,
        'notification_radius_m': notificationRadiusM,
      }),
    );
    if (response.statusCode != 200 && response.statusCode != 201) {
      throw Exception('デバイスの登録に失敗しました: ${response.body}');
    }
  }

  /// 経路探索: POST /api/route
  ///
  /// [startLat] 出発地の緯度
  /// [startLng] 出発地の経度
  /// [endLat]   目的地の緯度
  /// [endLng]   目的地の経度
  ///
  /// 安全優先ルート・最短ルート・沿道ハザード情報をまとめた [RouteResponse] を返す。
  Future<RouteResponse> fetchRoute({
    required double startLat,
    required double startLng,
    required double endLat,
    required double endLng,
    double hazardRadiusM = 1000.0,
  }) async {
    final uri = Uri.parse('$baseUrl/route');
    final body = jsonEncode({
      'start_lat': startLat,
      'start_lng': startLng,
      'end_lat': endLat,
      'end_lng': endLng,
      'hazard_radius_m': hazardRadiusM,
    });

    final response = await http.post(
      uri,
      headers: {'Content-Type': 'application/json'},
      body: body,
    );

    if (response.statusCode == 200) {
      final jsonResponse =
          jsonDecode(response.body) as Map<String, dynamic>;
      return RouteResponse.fromJson(jsonResponse);
    } else if (response.statusCode == 400) {
      throw Exception(
          'ルート探索エラー (400): 指定座標が道路ネットワーク外の可能性があります。\n${response.body}');
    } else if (response.statusCode == 404) {
      throw Exception(
          'ルートが見つかりません (404): 出発地または目的地が道路網から離れすぎています。');
    } else if (response.statusCode == 503) {
      throw Exception('サービス一時停止 (503): データベースに接続できません。');
    } else {
      throw Exception('サーバーエラー: HTTP ${response.statusCode}');
    }
  }

  /// 周辺のハザード情報取得: GET /api/hazards
  Future<List<HazardPoint>> getHazards({
    required double minLat,
    required double minLng,
    required double maxLat,
    required double maxLng,
  }) async {
    final uri = Uri.parse('$baseUrl/hazards').replace(queryParameters: {
      'min_lat': minLat.toString(),
      'min_lng': minLng.toString(),
      'max_lat': maxLat.toString(),
      'max_lng': maxLng.toString(),
    });

    final response = await http.get(uri);

    if (response.statusCode == 200) {
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final points = data['points'] as List<dynamic>? ?? [];
      return points.map((e) => HazardPoint.fromJson(e)).toList();
    } else {
      throw Exception('ハザード情報の取得に失敗しました: HTTP ${response.statusCode}');
    }
  }

  /// カバレッジ情報取得: GET /api/coverage
  Future<CoverageResponse> fetchCoverage({
    required double minLat,
    required double minLng,
    required double maxLat,
    required double maxLng,
    required double zoom,
  }) async {
    final uri = Uri.parse('$baseUrl/coverage').replace(queryParameters: {
      'min_lat': minLat.toString(),
      'min_lng': minLng.toString(),
      'max_lat': maxLat.toString(),
      'max_lng': maxLng.toString(),
      'zoom': zoom.toString(),
    });

    final response = await http.get(uri);

    if (response.statusCode == 200) {
      final jsonMap = jsonDecode(response.body) as Map<String, dynamic>;
      return CoverageResponse.fromJson(jsonMap);
    } else {
      throw Exception('カバレッジ情報の取得に失敗しました: HTTP ${response.statusCode}');
    }
  }

  /// 周辺施設検索: GET /api/places/nearby
  /// 
  /// 指定された座標から [radius] m 以内の施設を検索し、
  /// 最も近い施設の座標と placeId を Map 形式で返します。
  Future<Map<String, dynamic>?> getNearbyPoi({
    required double lat,
    required double lng,
    double radius = 30.0,
  }) async {
    final uri = Uri.parse('$baseUrl/places/nearby').replace(queryParameters: {
      'lat': lat.toString(),
      'lng': lng.toString(),
      'radius': radius.toString(),
    });

    try {
      final response = await http.get(uri).timeout(const Duration(seconds: 4));
      
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final results = data['results'] as List<dynamic>?;
        
        if (results != null && results.isNotEmpty) {
          // レビュー件数（user_ratings_total）と評価（rating）を基準に最適な施設を選択
          Map<String, dynamic>? bestPlace;
          int maxReviews = -1;
          double maxRating = -1.0;
          double minDistSq = double.infinity;

          for (final r in results) {
            final place = r as Map<String, dynamic>;
            final geom = place['geometry'] as Map<String, dynamic>?;
            final loc = geom?['location'] as Map<String, dynamic>?;
            if (loc == null) continue;

            final rLat = (loc['lat'] as num).toDouble();
            final rLng = (loc['lng'] as num).toDouble();
            final distSq = (rLat - lat) * (rLat - lat) + (rLng - lng) * (rLng - lng);

            final reviews = place['user_ratings_total'] as int? ?? 0;
            final rating = (place['rating'] as num?)?.toDouble() ?? 0.0;

            bool isBetter = false;

            // 1. 基本的にレビュー件数（user_ratings_total）が最も多い施設を最優先
            if (reviews > maxReviews) {
              isBetter = true;
            } 
            // 2. レビュー件数が同じ場合は、評価（rating）が高い方を優先
            else if (reviews == maxReviews) {
              if (rating > maxRating) {
                isBetter = true;
              } 
              // 3. レビューも評価も同じ場合は、タップ座標からの距離が近い方を優先
              else if (rating == maxRating) {
                if (distSq < minDistSq) {
                  isBetter = true;
                }
              }
            }

            if (isBetter) {
              maxReviews = reviews;
              maxRating = rating;
              minDistSq = distSq;
              bestPlace = place;
            }
          }

          if (bestPlace != null) {
            final geomLat =
                bestPlace['geometry']['location']['lat'] as num;
            final geomLng =
                bestPlace['geometry']['location']['lng'] as num;

            return {
              'lat': geomLat.toDouble(),
              'lng': geomLng.toDouble(),
              'placeId': bestPlace['place_id'] as String,
            };
          }
        }
      }
    } catch (e) {
      // ネットワークエラー等の場合は null を返す
      debugPrint('Nearby API Error: $e');
    }
    
    return null;
  }

  /// 検索サジェスト用: GET /api/places/search
  ///
  /// 入力された [query] を元に、候補の施設リストを取得します。
  Future<List<dynamic>?> searchPlaces({
    required String query,
    double? lat,
    double? lng,
    double? radius,
  }) async {
    final queryParams = <String, String>{'query': query};

    if (lat != null && lng != null) {
      queryParams['location'] = '$lat,$lng';
      if (radius != null) {
        queryParams['radius'] = radius.toInt().toString();
      }
    }

    final uri = Uri.parse('$baseUrl/places/search').replace(queryParameters: queryParams);

    try {
      final response = await http.get(uri).timeout(const Duration(seconds: 5));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final status = data['status'] as String? ?? '';
        final errorMessage = data['error_message'] as String?;

        if (status != 'OK' && status != 'ZERO_RESULTS') {
          debugPrint('[ApiService] Places API error: status=$status, message=$errorMessage');
          return null; // または例外を投げる
        }

        final results = data['results'] as List<dynamic>? ?? [];
        return results;
      } else {
        debugPrint('[ApiService] searchPlaces HTTP error: ${response.statusCode} ${response.reasonPhrase}');
      }
    } catch (e) {
      debugPrint('[ApiService] searchPlaces Exception: $e');
    }

    return null;
  }

  /// 詳細施設情報取得: GET /api/places/details
  /// 
  /// [placeId] に対応する施設の詳細情報（電話番号、営業時間など）を取得します。
  Future<Map<String, dynamic>?> getPlaceDetails(String placeId) async {
    final uri = Uri.parse('$baseUrl/places/details').replace(queryParameters: {
      'place_id': placeId,
    });

    try {
      final response = await http.get(uri).timeout(const Duration(seconds: 5));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final status = data['status'] as String? ?? '';
        final errorMessage = data['error_message'] as String?;

        if (status != 'OK' && status != 'ZERO_RESULTS') {
          debugPrint('[ApiService] Place Details API error: status=$status, message=$errorMessage');
          return null;
        }

        final result = data['result'] as Map<String, dynamic>?;
        return result;
      } else {
        debugPrint('[ApiService] getPlaceDetails HTTP error: ${response.statusCode} ${response.reasonPhrase}');
      }
    } catch (e) {
      debugPrint('[ApiService] getPlaceDetails Exception: $e');
    }

    return null;
  }

  /// 共通: リクエスト送信とレスポンスのパース

  Future<AnalyzeResponse> _sendRequest(http.MultipartRequest request) async {
    // デバッグ: リクエストの詳細を出力
    debugPrint('[ApiService] Sending ${request.method} to ${request.url}');
    debugPrint('[ApiService] Form fields: ${request.fields}');
    debugPrint('[ApiService] Files: ${request.files.map((f) => '${f.field}=${f.filename} (${f.length} bytes)').toList()}');

    final response = await request.send();
    final responseData = await response.stream.bytesToString();

    debugPrint('[ApiService] Response status: ${response.statusCode}');

    if (response.statusCode == 200) {
      final jsonResponse = jsonDecode(responseData) as Map<String, dynamic>;
      return AnalyzeResponse.fromJson(jsonResponse);
    } else {
      // エラー時はレスポンスボディの詳細を出力
      debugPrint('[ApiService] ❌ API Error Body: $responseData');
      throw Exception('APIエラー (${response.statusCode}): $responseData');
    }
  }
}
