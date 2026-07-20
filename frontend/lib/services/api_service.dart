import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:image_picker/image_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import '../models/analyze_result.dart';
import '../models/route_models.dart';

final apiServiceProvider = Provider<ApiService>((ref) => ApiService());

class ApiService {
  // バックエンドのURL
  // MacのiOSシミュレータやWebブラウザでテストする場合は 127.0.0.1 で繋がります。
  // iPhone実機でテストする場合は、MacのIPアドレス（例: 192.168.1.5等）に変更してください！
  static const String baseUrl = 'http://127.0.0.1:8000/api';

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
    required double lat,
    required double lng,
    double? bearing,
    double? focalLength35mm,
  }) async {
    final request = http.MultipartRequest(
      'POST',
      Uri.parse('$baseUrl/analyze'),
    );

    // 画像をバイトデータとして添付（Web・モバイル両対応）
    final bytes = await imageFile.readAsBytes();
    request.files.add(
      http.MultipartFile.fromBytes('image', bytes, filename: imageFile.name),
    );

    // GPS座標を送信（モードAは必須）
    request.fields['lat'] = lat.toString();
    request.fields['lng'] = lng.toString();

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
  }) async {
    final request = http.MultipartRequest(
      'POST',
      Uri.parse('$baseUrl/analyze'),
    );

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
          // 一番近い施設を返す
          final place = results.first as Map<String, dynamic>;
          final geomLat = place['geometry']['location']['lat'] as num;
          final geomLng = place['geometry']['location']['lng'] as num;
          
          return {
            'lat': geomLat.toDouble(),
            'lng': geomLng.toDouble(),
            'placeId': place['place_id'] as String,
          };
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
    final response = await request.send();
    final responseData = await response.stream.bytesToString();

    if (response.statusCode == 200) {
      final jsonResponse = jsonDecode(responseData) as Map<String, dynamic>;
      return AnalyzeResponse.fromJson(jsonResponse);
    } else if (response.statusCode == 400) {
      // GPS座標が取得できなかった場合など
      throw Exception('リクエストエラー (400): GPS座標またはEXIFデータが不足しています');
    } else {
      throw Exception('サーバーエラー: HTTP ${response.statusCode}');
    }
  }
}
