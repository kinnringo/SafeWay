import 'dart:convert';
import 'package:image_picker/image_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import '../models/analyze_result.dart';

final apiServiceProvider = Provider<ApiService>((ref) => ApiService());

class ApiService {
  // バックエンドのURL
  // MacのiOSシミュレータやWebブラウザでテストする場合は 127.0.0.1 で繋がります。
  // iPhone実機でテストする場合は、MacのIPアドレス（例: 192.168.1.5等）に変更してください！
  static const String baseUrl = 'http://127.0.0.1:8000/api';

  /// 画像をサーバーに送信し、解析結果（BBox等）を受け取る
  Future<AnalyzeResponse> analyzeImage(XFile imageFile) async {
    // 1. リクエストの準備
    var request = http.MultipartRequest('POST', Uri.parse('$baseUrl/analyze'));
    
    // 2. Web・モバイル両対応で画像をバイトデータとして読み込んで添付
    final bytes = await imageFile.readAsBytes();
    request.files.add(
      http.MultipartFile.fromBytes(
        'file', 
        bytes, 
        filename: imageFile.name,
      )
    );

    // 3. APIに送信
    var response = await request.send();
    
    // 4. 結果のパース
    if (response.statusCode == 200) {
      var responseData = await response.stream.bytesToString();
      var jsonResponse = jsonDecode(responseData);
      return AnalyzeResponse.fromJson(jsonResponse);
    } else {
      throw Exception('Failed to analyze image: HTTP ${response.statusCode}');
    }
  }
}
