# SafeWay フロントエンド API 仕様書
## 対象エンドポイント: `POST /api/analyze`

> **この文書の対象読者**: Flutter 担当開発者（人間）および実装を担当する AI エージェント。
> 仕様だけでなく、設計上の前提・目標・背景知識を含む。API の変更は必ずバックエンド担当と合意してから行うこと。

---

## 1. プロジェクト背景と目標

SafeWay は「最短経路」ではなく「**最も安全な経路**」を提案する歩行者・自転車向けナビゲーションアプリである。

安全経路を計算するためには、道路ごとの「安全スコア」が必要であり、そのスコアは**ユーザーが投稿する写真から収集される**。写真から YOLO モデルが街灯・障害物などを検出し、その物体の GPS 位置を推定して蓄積することで、道路ネットワークの安全スコアが更新されていく。

この API エンドポイント（`POST /api/analyze`）は、**このデータ収集パイプラインの入口**に当たる最も重要な API である。

---

## 2. このエンドポイントが行うこと（バックエンドの処理概要）

Flutter がこの API を呼び出すと、バックエンドは以下を順番に実行する。

```
1. 画像から EXIF を抽出する（GPS・方位角・焦点距離）
2. Form フィールドと EXIF をマージする（Form 値が優先）
3. YOLO で画像を解析し、物体（街灯・障害物等）を検出する
4. 各物体について、カメラのパラメータを使って実際の GPS 位置を推定する
5. 推定した位置を DB（PostGIS）に保存する
6. 保存した位置の周辺にある道路のスコアを自動更新する
7. 結果を返す
```

**このエンドポイントを呼ぶと、地図上のスコアが変わる。** リアルタイムではないが、次のルート検索 API 呼び出し時から新しいスコアが反映される。

---

## 3. 物体位置推定の仕組み（重要な前提知識）

> この節は Flutter 側が「なぜこれらのパラメータが必要なのか」を理解するために必要。

### 問題: 写真撮影位置 ≠ 物体の実際の位置

ユーザーが街灯の写真を撮ったとき、GPS が記録するのは「**ユーザーが立っている位置**」である。しかし、写真に写った街灯は 15m 先・30m 先にあるかもしれない。これを「ユーザー位置に街灯がある」として保存すると、道路スコアの計算が大きくずれる。

### 解決策: ピンホールカメラモデルによる位置推定

以下のパラメータが揃っていれば、三角測量によって物体の実際の GPS 位置を推定できる。

| パラメータ | 意味 | 用途 |
|---|---|---|
| `lat`, `lng` | 撮影者（ユーザー）の位置 | 推定の基準点 |
| `bearing` | カメラが向いていた方向（北=0°, 時計回り） | 物体がどの方向にいるか |
| `focal_length_35mm` | 35mm 換算焦点距離（mm） | 画像内の見かけの大きさから距離を計算するため |

推定の流れ（概略）:
1. YOLO のバウンディングボックスの高さ（px）と物体の既知の実高さ（例：街灯=5.5m）から距離を計算
2. バウンディングボックスの水平位置から、カメラ正面からの水平ズレ角を計算
3. `bearing` + ズレ角 → 物体への実際の方位角
4. 方位角 + 距離 → 物体の GPS 座標

### 精度フラグ: `position_accuracy`

推定に必要な情報が揃っているかどうかで、レスポンスの `position_accuracy` が変わる。

| `bearing` | `focal_length_35mm` | `position_accuracy` | 意味 |
|---|---|---|---|
| あり | あり | `"high"` | 物体の実際の位置を推定できた |
| なし（どちらか） | なし（どちらか） | `"low"` | 情報不足のため撮影者位置をそのまま使用 |

Flutter 側でこの値を使って UI を分けることを推奨する（後述）。

---

## 4. 対応する2つのアップロードモード

### モード A: ライブカメラ撮影（アプリから直接撮影）

ユーザーがアプリ内で写真を撮影し、その場でアップロードする。

**Flutter がすること:**
1. カメラで撮影する直前に、デバイスの各センサーから値を取得する
2. 撮影後、画像と一緒に Form フィールドとして API に送信する

**注意**: リアルタイム撮影では、撮影した JPEG に GPS が EXIF として埋め込まれない場合がある（端末・OS バージョン依存）。そのため、Flutter が Form フィールドとして明示的に送信するのが最も確実。

### モード B: 過去写真のアップロード（ギャラリーから選択）

ユーザーが同一端末で過去に撮影した**無加工の写真**を選んでアップロードする。

**前提・スコープ:**
- 対象は「同一端末で撮影した無加工の写真（EXIF 付き）」のみ
- ネットからダウンロードした画像、加工済み画像、他端末からの転送画像は対象外
- EXIF が存在しない画像は `position_accuracy: "low"` となるが、エラーにはならない

**Flutter がすること:**
1. ギャラリーから画像を選択する
2. **画像ファイルのみを送信する**（センサー値は不要。バックエンドが EXIF から自動抽出する）

---

## 5. API エンドポイント仕様

### エンドポイント

```
POST /api/analyze
Content-Type: multipart/form-data
```

### リクエストフィールド

| フィールド名 | 型 | 必須 | 説明 |
|---|---|---|---|
| `image` | File (JPEG/PNG) | **必須** | 解析する画像ファイル |
| `lat` | float | 任意 | 撮影者の緯度。省略時は EXIF から自動抽出。EXIF もなければエラー。 |
| `lng` | float | 任意 | 撮影者の経度。省略時は EXIF から自動抽出。EXIF もなければエラー。 |
| `bearing` | float | 任意 | コンパス方位角（0〜360°, 0=北, 時計回り）。省略時は EXIF から自動抽出。なければ `position_accuracy: "low"`。 |
| `focal_length_35mm` | float | 任意 | 35mm 換算焦点距離（mm）。省略時は EXIF から自動抽出。なければ `position_accuracy: "low"`。 |
| `test_mode` | bool | 任意 | **開発・デバッグ専用フィールド。リリース版では使用しないこと。** `true` を指定すると、YOLOが何も検出しなかった場合にダミーの街灯データを1件注入する。デフォルトは `false`。 |

> モード A（ライブカメラ）の推奨送信フィールド: `image`, `lat`, `lng`, `bearing`, `focal_length_35mm`
> モード B（過去写真）の推奨送信フィールド: `image` のみ

### レスポンス（200 OK）

```json
{
  "user_lat": 36.3895,
  "user_lng": 139.0634,
  "updated_score": 0.6,
  "detections": [
    {
      "label": "streetlight",
      "confidence": 0.92,
      "bbox": [120.5, 80.0, 200.3, 450.7],
      "object_lat": 36.3896,
      "object_lng": 139.0637,
      "estimated_distance_m": 22.5,
      "position_accuracy": "high",
      "score_modifier": 0.1
    }
  ]
}
```

### レスポンスフィールド詳細

| フィールド | 型 | 説明 |
|---|---|---|
| `user_lat` / `user_lng` | float | 撮影者の位置（Form または EXIF から取得した値） |
| `updated_score` | float (0〜1) | 暫定の安全スコア更新値（参考値） |
| `detections` | array | 検出された各オブジェクトの結果リスト |
| `detections[].label` | string | 検出ラベル（例: `"streetlight"`, `"obstacle"`） |
| `detections[].confidence` | float (0〜1) | YOLO の信頼度 |
| `detections[].bbox` | float[4] | 画像内のバウンディングボックス [x1, y1, x2, y2]（ピクセル座標） |
| `detections[].object_lat` | float | 推定したオブジェクトの緯度 |
| `detections[].object_lng` | float | 推定したオブジェクトの経度 |
| `detections[].estimated_distance_m` | float or null | 推定した水平距離（m）。position_accuracy が low の場合は null |
| `detections[].position_accuracy` | "high" or "low" | 位置推定の精度 |
| `detections[].score_modifier` | float | この物体が道路安全スコアに与える影響値（正=安全性の向上, 負=安全性の低下） |

### エラーレスポンス

| HTTP Status | 発生条件 |
|---|---|
| 400 | 画像ファイルが無効 |
| 400 | GPS 座標が Form にも EXIF にも存在しない |
| 500 | サーバー内部エラー |

---

## 6. Flutter での実装方法

### 6-1. 必要なパッケージ

```yaml
# pubspec.yaml
dependencies:
  image_picker: ^1.0.0
  geolocator: ^11.0.0
  flutter_compass: ^0.7.0
  http: ^1.0.0
  exif: ^3.1.0
```

> 注意: `flutter_compass` は Android では `ACCESS_FINE_LOCATION` パーミッションが必要。

### 6-2. モード A（ライブカメラ）の実装例

```dart
Future<void> captureAndUpload() async {
  final position = await Geolocator.getCurrentPosition(
    desiredAccuracy: LocationAccuracy.high,
  );

  final compassEvent = await FlutterCompass.events!.first;
  final bearing = compassEvent.heading;

  final picker = ImagePicker();
  final pickedFile = await picker.pickImage(source: ImageSource.camera);
  if (pickedFile == null) return;

  // 撮影した JPEG の EXIF から焦点距離を取得（最も確実な方法）
  double? focalLength35mm;
  // final bytes = await pickedFile.readAsBytes();
  // final exifData = await readExifFromBytes(bytes);
  // focalLength35mm = exifData['EXIF FocalLengthIn35mmFilm']?.toDouble();

  final request = http.MultipartRequest('POST', Uri.parse('http://YOUR_API_HOST/api/analyze'));
  request.files.add(await http.MultipartFile.fromPath('image', pickedFile.path));
  request.fields['lat'] = position.latitude.toString();
  request.fields['lng'] = position.longitude.toString();

  if (bearing != null) {
    final normalizedBearing = (bearing + 360) % 360;
    request.fields['bearing'] = normalizedBearing.toString();
  }
  if (focalLength35mm != null) {
    request.fields['focal_length_35mm'] = focalLength35mm.toString();
  }

  final response = await request.send();
}
```

### 6-3. モード B（過去写真）の実装例

```dart
Future<void> selectAndUpload() async {
  final picker = ImagePicker();
  final pickedFile = await picker.pickImage(source: ImageSource.gallery);
  if (pickedFile == null) return;

  // image のみ送信。バックエンドが EXIF から全て自動抽出する。
  final request = http.MultipartRequest('POST', Uri.parse('http://YOUR_API_HOST/api/analyze'));
  request.files.add(await http.MultipartFile.fromPath('image', pickedFile.path));

  final response = await request.send();
}
```

### 6-4. コンパス方位角の正規化

flutter_compass は端末によって -180〜180 または 0〜360 で返す場合がある。
バックエンドは 0〜360（北=0, 時計回り）を期待するため、必ず正規化すること。

```dart
double normalizeBearing(double rawBearing) {
  return (rawBearing % 360 + 360) % 360;
}
```

### 6-5. 投稿完了後のフィードバック表示（推奨）

> **重要**: `POST /api/analyze` のレスポンスに含まれる `object_lat`, `object_lng` は、**投稿した写真から検出されたオブジェクトの推定位置**である。これはあくまで「投稿完了の確認フィードバック」として使用するものであり、リリース版の危険情報マップ（全ユーザーのデータを集約して表示する機能）とは別物である。
>
> リリース版の危険情報マップは、別途 `GET /api/hazards`（将来実装予定）のような読み取り専用 API から取得したデータを使用する。

`position_accuracy` の値は、投稿完了フィードバックの表示精度を示すために使用できる。

```dart
for (final detection in detections) {
  final accuracy = detection['position_accuracy'] as String;
  final objLat = detection['object_lat'] as double;
  final objLng = detection['object_lng'] as double;

  if (accuracy == 'high') {
    // 精度良好 → 推定位置を実線アイコンで表示（投稿確認フィードバック）
    addMapMarker(lat: objLat, lng: objLng, opacity: 1.0);
  } else {
    // 精度低 → 撮影者位置付近に半透明で表示（「このあたりに登録されました」程度の参考表示）
    addMapMarker(lat: objLat, lng: objLng, opacity: 0.5);
  }
}
```

---

## 7. パラメータ取得不可時の挙動まとめ

| 不足するパラメータ | バックエンドの挙動 | position_accuracy |
|---|---|---|
| lat/lng が Form にも EXIF にもない | HTTP 400 エラー | - |
| bearing がない | 撮影者位置をそのまま使用 | "low" |
| focal_length_35mm がない | 撮影者位置をそのまま使用 | "low" |
| bearing と focal_length_35mm が両方ない | 撮影者位置をそのまま使用 | "low" |
| YOLO が何も検出しない | detections: [] を返す | - |

---

## 8. 実装チェックリスト

- [ ] ライブカメラモードで lat, lng, bearing が Form フィールドとして送信されている
- [ ] bearing が 0〜360 の範囲に正規化されて送信されている
- [ ] 過去写真モードでは画像ファイルのみを送信している
- [ ] position_accuracy の値に応じて、投稿完了フィードバックの表示を変えている（high=実線, low=半透明の参考表示）
- [ ] lat/lng がない場合の HTTP 400 エラーをユーザーにわかりやすく表示している
- [ ] アップロード中のローディング表示がある
- [ ] 投稿完了後、object_lat / object_lng を使って「このあたりに登録されました」というフィードバックを表示している（リリース版の危険情報マップとは別機能）

---

## 9. 将来的な変更予定

- **認証**: 現在は user_id: null で保存。将来的にログイン機能追加時、ヘッダーに認証トークンが必要。認証が導入されると、コイン付与や登録ルート機能もこの user_id に紐づく。
- **お礼コイン**: 有益な投稿へのコイン付与機能追加予定。レスポンスに `coins_earned` フィールドが追加される。
- **重複排除**: ✅ **実装済み**。同一位置（半径5m以内）に同じ種類のオブジェクトが投稿された場合、`safety_points` を新規作成せず既存レコードを更新することでスコアの異常膨張を防いでいる。フロント側の変更は不要。
- **時間帯別スコア**: 夜間モードのスコア計算追加に伴い、`timestamp` または `is_nighttime` フラグが追加される可能性あり。
- **危険情報マップ（読み取りAPI）**: 全ユーザーのデータを集約した危険情報を地図上に表示するための `GET /api/hazards` エンドポイントを将来実装する。野生動物（熊・イノシシ等）出没地点、犯罪発生地点、障害物等を地図上にアイコンで表示し、カテゴリ別に on/off できるUIを想定している。外部データソース（公的な野生動物・犯罪情報API等）が確定次第、対応するインポート処理も設計する。
- **登録ルートと危険通知機能**（認証機能が前提）: ログイン済みユーザーが通勤・通学路などよく使う道をアプリ上で登録できる機能。登録されたルート（LineString）の周辺（例: 50m以内）に新たな危険情報（野生動物出没・犯罪発生等）が追加されたとき、FCM（Firebase Cloud Messaging）等のプッシュ通知でユーザーに即時通知する。この機能の実装には以下が必要：(1) ルート登録・取得API、(2) ユーザーのFCMトークン管理、(3) `safety_points` 挿入時の空間判定トリガー処理。現時点では外部の危険情報データソースが未確定のため実装を保留しているが、DB設計・API設計の段階からこの機能を見越した設計を行うこと。
