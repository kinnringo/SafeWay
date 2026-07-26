# Web版 リアルタイム危険情報アラート（距離計測＋ポーリング方式）実装依頼

## 1. 目的と背景
- デモ・プレゼン環境における安定稼働を保証するため、Web（Chrome）上でのリアルタイムな危険通知を外部プッシュサービスを介さない「アクティビティ感知 (ローカルポーリング) 方式」で実装する。
- **デモ時の仕様**: Swagger等から `POST /api/crime-reports` でクマ出没情報（緯度経度・詳細状況つき）を投入。その瞬間、Webアプリが端末現在地との距離を即時計算し、以下の画面イメージでポップアップ警告を展開する。

**【画面出力イメージ（構成の理想形）】**
```text
==========================================
⚠️ クマ出没警告
450m先でクマが目撃されました
詳細：【頭数】1.0 【状況】干俣川から県道を渡って山の方向へ走って行った
==========================================
```
※ `450m` の部分は現在地から投稿位置との計算距離、`クマ` や詳細内容は投稿データ（レスポンス）に応じて可変。

## 2. ゴールと求めること
1. 定期タイマー（3〜5秒間隔）でバックエンドの「差分監視用API」を監視する。
2. 新規レコードの座標（`lat`, `lng`）と端末現在地の座標間の直線距離をメートル計算し、上記の簡潔・明確なフォーマットで警告ダイアログを展開する。
3. **二度鳴り防止**: 一度アラートを出したら即座に内部管理している最新ID（`lastKnownId`）を上書き更新し、次回確認時以降は同一事案で再発出させないこと。

---

## 3. バックエンド追加仕様 (実装済)

### `GET /api/crime-reports` (認証不要)
指定した `after_id` より後に登録された新着データのみを古い順に取り出すことが可能な仕様を搭載済み。

**リクエスト例:**
`GET http://127.0.0.1:8000/api/crime-reports?after_id=15`

| パラメータ | 型 | デフォルト | 説明 |
|---|---|---|---|
| `after_id` | integer | `null` | 指定したIDより大きい（＝新しく登録された）レコードのみを古い順で取得 |
| `limit` | integer | 20 | 最大返却件数 |

**レスポンス例（※ 新規に1件追加された場合のデータ構造の一例。値は固定ではなく動的に変わる）:**
```json
[
  {
    "id": 16,
    "event_type": "bear",
    "description": "【頭数】1.0 【状況】干俣川から県道を渡って山の方向へ走って行った",
    "lat": 37.3456,
    "lng": 138.9012,
    "occurred_at": "2026-07-26T10:30:00",
    "created_at": "2026-07-26T10:31:12"
  }
]
```
※ 変更がない場合や新着ゼロの時は空の配列 `[]` が返り、画面上に変化は起こらない。

---

## 4. フロントエンド 実装イメージ（Dart / Flutter）

### ① `api_service.dart` への差分取得メソッド追加
```dart
Future<List<Map<String, dynamic>>> fetchNewCrimeReports({int? afterId}) async {
  final query = afterId != null ? '?after_id=$afterId' : '?limit=1';
  final uri = Uri.parse('$baseUrl/crime-reports$query');
  
  final response = await http.get(uri);
  if (response.statusCode == 200) {
    final List<dynamic> data = json.decode(response.body);
    return data.cast<Map<String, dynamic>>();
  }
  return [];
}
```

### ② 「〇〇m先で〇〇が目撃されました / 詳細：...」を表示する警告ポップアップUI
すでに導入済みの `Geolocator.distanceBetween` を用いてシンプルに構築すること。

```dart
import 'package:geolocator/geolocator.dart';

void _showEmergencyDialog(Map<String, dynamic> report, double myLat, double myLng) {
  final double rLat = report['lat'] as double;
  final double rLng = report['lng'] as double;
  
  // 距離の整数算出
  final distMeters = Geolocator.distanceBetween(myLat, myLng, rLat, rLng).round();
  final String distanceText = distMeters > 1000 
      ? '${(distMeters / 1000).toStringAsFixed(1)}km' 
      : '${distMeters}m';

  // イベント種別と詳細テキストの成形
  final eventName = report['event_type'] == 'bear' ? 'クマ' : '不審者/危険対象';
  final headerMessage = '$distanceText先で$eventNameが目撃されました';
  final description = report['description'] ?? '詳しい状況の記載はありません。';

  showDialog(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => AlertDialog(
      backgroundColor: Colors.red.shade900,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Row(
        children: [
          const Icon(Icons.warning_amber_rounded, color: Colors.amber, size: 36),
          const SizedBox(width: 8),
          Text('$eventName出没警告', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 20)),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: Colors.amber.shade400,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              headerMessage, 
              style: const TextStyle(color: Colors.black, fontWeight: FontWeight.bold, fontSize: 16),
            ),
          ),
          const SizedBox(height: 12),
          Text('詳細：$description', style: const TextStyle(color: Colors.white, fontSize: 15, height: 1.4)),
        ],
      ),
      actions: [
        ElevatedButton(
          style: ElevatedButton.styleFrom(backgroundColor: Colors.white),
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text('確認', style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold)),
        ),
      ],
    ),
  );
}
```

### ③ タイマー監視ロジック（マップ等主画面Stateful での設定例）
```dart
import 'dart:async';

int? _lastKnownReportId;
Timer? _pollingTimer;

@override
void initState() {
  super.initState();
  _initAlertPolling();
}

void _initAlertPolling() async {
  // 初回: 今DBにある中で最上位のIDを取得し記録
  final initials = await apiService.fetchNewCrimeReports();
  if (initials.isNotEmpty) {
    _lastKnownReportId = initials.first['id'] as int;
  } else {
    _lastKnownReportId = 0;
  }

  // 4秒に一度更新確認
  _pollingTimer = Timer.periodic(const Duration(seconds: 4), (timer) async {
    if (_lastKnownReportId == null) return;

    final newReports = await apiService.fetchNewCrimeReports(afterId: _lastKnownReportId);
    
    if (newReports.isNotEmpty) {
      // 一度感知したレコードで再びアラートが出ないようにIDを即座に上書き更新
      _lastKnownReportId = newReports.last['id'] as int;

      // 端末の現在地変数を引き当てる
      final myLat = _currentPosition?.latitude ?? 37.3450;
      final myLng = _currentPosition?.longitude ?? 138.9000;

      for (var report in newReports) {
        _showEmergencyDialog(report, myLat, myLng);
      }
    }
  });
}

@override
void dispose() {
  _pollingTimer?.cancel();
  super.dispose();
}
```
