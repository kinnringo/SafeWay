import 'package:image_picker/image_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/analyze_result.dart';
// import 'package:http/http.dart' as http; // 本番連携時に使用

final apiServiceProvider = Provider<ApiService>((ref) => ApiService());

class ApiService {
  // 本番用URL（相方さんのPCのIPアドレス等を2日後に入れます）
  // static const String baseUrl = 'http://192.168.X.X:8000/api';

  /// 画像をサーバーに送信し、解析結果（BBox等）を受け取る
  Future<AnalyzeResponse> analyzeImage(XFile imageFile) async {
    /* --- 本番連携時のコード（2日後にコメントアウトを解除します） ---
    var request = http.MultipartRequest('POST', Uri.parse('$baseUrl/analyze'));
    // Webとモバイル両対応のためXFileのreadAsBytesを使用するか、パスを使います
    // request.files.add(await http.MultipartFile.fromPath('file', imageFile.path));

    var response = await request.send();
    
    if (response.statusCode == 200) {
      var responseData = await response.stream.bytesToString();
      var jsonResponse = jsonDecode(responseData);
      return AnalyzeResponse.fromJson(jsonResponse);
    } else {
      throw Exception('Failed to analyze image: ${response.statusCode}');
    }
    ---------------------------------------------------------- */

    // --- 今回のテスト用（ダミーのBBox結果を返すモック処理） ---
    // APIの通信待ちをシミュレート（2秒待機）
    await Future.delayed(const Duration(seconds: 2));

    // 画像の中央付近に「街灯」の枠を描画するためのダミーデータ
    // [xmin, ymin, xmax, ymax] ※後で画像の実際のサイズに合わせてパーセンテージ等で描画します
    return AnalyzeResponse(
      results: [
        AnalyzeResult(
          label: 'streetlight',
          confidence: 0.88,
          bbox: BoundingBox(xmin: 0.3, ymin: 0.2, xmax: 0.7, ymax: 0.8), // 0.0〜1.0の相対座標で返ってくると仮定
        ),
      ],
    );
  }
}
