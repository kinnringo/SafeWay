# SafeWay Backend API 仕様書

最終更新: 2026-07-27

ベースURL: `http://localhost:8000`

---

## 認証

認証が必要なエンドポイントは `Authorization: Bearer <token>` ヘッダーを付与すること。
トークンは `/api/auth/login` で取得する。

---

## POST /api/auth/register

新規ユーザーを登録する。

### リクエストボディ

| フィールド | 型 | 必須 | 説明 |
|---|---|---|---|
| `username` | string | ○ | ユーザー名（3〜50文字） |
| `password` | string | ○ | パスワード（6文字以上） |

### レスポンス

**201 Created**

| フィールド | 型 | 説明 |
|---|---|---|
| `id` | int | ユーザー ID |
| `username` | string | ユーザー名 |
| `coins` | int | 保有コイン数（初期値: 0） |
| `created_at` | string | 登録日時（ISO 8601） |

**409 Conflict**: ユーザー名が既に使用されている場合

### レスポンス例

```json
{
  "id": 1,
  "username": "taro",
  "coins": 0,
  "created_at": "2026-07-20T12:00:00"
}
```

---

## POST /api/auth/login

ユーザー認証を行い、JWT アクセストークンを返す。

### リクエストボディ

| フィールド | 型 | 必須 | 説明 |
|---|---|---|---|
| `username` | string | ○ | ユーザー名 |
| `password` | string | ○ | パスワード |

### レスポンス

**200 OK**

| フィールド | 型 | 説明 |
|---|---|---|
| `access_token` | string | JWT アクセストークン（有効期限: 60分） |
| `token_type` | string | 常に `"bearer"` |

**401 Unauthorized**: 認証情報が誤っている場合

### レスポンス例

```json
{
  "access_token": "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9...",
  "token_type": "bearer"
}
```

---

## GET /api/auth/me

**認証必須**

ログイン中のユーザー情報を返す。

### リクエストヘッダー

| ヘッダー | 値 |
|---|---|
| `Authorization` | `Bearer <access_token>` |

### レスポンス

**200 OK**: `UserResponse`（`/api/auth/register` と同形式）

**401 Unauthorized**: トークンが無効・期限切れの場合

---

## GET /health

ヘルスチェック用エンドポイント。サーバーが起動しているかの確認に使用する。

### パラメータ

なし

### レスポンス

| フィールド | 型 | 説明 |
|---|---|---|
| `status` | string | 常に `"ok"` |

### レスポンス例

```json
{
  "status": "ok"
}
```

---

## POST /api/analyze

アップロードされた画像をYOLOv26で解析し、街灯や歩道状況を検出する。検出結果の座標をEXIF＋三角測量で推定し、DBに保存する。

### 実装状況: ✅ 実装済み

### ヘッダー

| キー | 必須 | 説明 |
|---|---|---|
| `Authorization` | ❌ | `Bearer <token>` の形式でJWTトークンを指定。送信した場合、解析結果がアカウントに紐付きコインが付与される。 |

### リクエスト形式: `multipart/form-data`

| パラメータ | 型 | 必須 | 説明 |
|---|---|---|---|
| `image` | File | ✅ | 解析する画像ファイル（JPEG/PNG）。**必ずGPS EXIF情報が含まれている必要があります。** |
| `bearing` | float | ❌ | コンパス方位角（度、0=北、時計回り）。省略時はEXIFのGPSImgDirectionから抽出 |
| `focal_length_35mm` | float | ❌ | 35mm換算焦点距離（mm）。省略時はEXIFから抽出 |
| `test_mode` | bool | ❌ | `true` の場合、YOLOが未検出でもダミーの街灯検出を1つ注入する（デバッグ用） |

**パラメータ優先順位**: Form フィールドの値 > EXIF から抽出した値 > エラーまたはフォールバック
※ **位置情報（緯度・経度）については、Form フィールドでの指定は廃止され、EXIF からのみ取得します。**

**位置推定精度**:
- `bearing` と `focal_length_35mm` の両方が取得できた場合: `position_accuracy = "high"`（三角測量で対象物の実位置を推定）
- いずれかが不足している場合: `position_accuracy = "low"`（画像に記録されたEXIF撮影位置をフォールバックとして使用）

### レスポンス

| フィールド | 型 | 説明 |
|---|---|---|
| `detections` | DetectionResult[] | 検出結果のリスト |
| `user_lat` | float | 撮影者の緯度 |
| `user_lng` | float | 撮影者の経度 |
| `updated_score` | float (0.0〜1.0) | 更新後の安全スコア（暫定計算値） |
| `earned_coins` | integer | この投稿で獲得したコイン数 |

**DetectionResult の構造:**

| フィールド | 型 | 説明 |
|---|---|---|
| `label` | string | 検出ラベル（`streetlight`, `obstacle` 等） |
| `confidence` | float (0.0〜1.0) | YOLO の信頼度 |
| `bbox` | float[4] | バウンディングボックス `[x1, y1, x2, y2]`（画像ピクセル座標） |
| `object_lat` | float | 推定した対象物の緯度 |
| `object_lng` | float | 推定した対象物の経度 |
| `estimated_distance_m` | float? | カメラから対象物までの推定水平距離（m）。`position_accuracy` が `low` の場合は `null` |
| `position_accuracy` | string | 位置推定の精度。`"high"` または `"low"` |
| `score_modifier` | float | このオブジェクトが安全スコアに与える影響（正=安全方向、負=危険方向） |

### レスポンス例

```json
{
  "detections": [
    {
      "label": "streetlight",
      "confidence": 0.92,
      "bbox": [320.0, 50.0, 480.0, 400.0],
      "object_lat": 36.3905,
      "object_lng": 139.0635,
      "estimated_distance_m": 12.5,
      "position_accuracy": "high",
      "score_modifier": 0.10
    }
  ],
  "user_lat": 36.3900,
  "user_lng": 139.0634,
  "updated_score": 0.6,
  "earned_coins": 10
}
```

### 内部処理フロー

1. 画像を読み込み、PIL Image オブジェクトを生成
2. EXIF からメタデータ（GPS座標・方位角・焦点距離）を抽出
3. Form フィールドと EXIF の優先順位でパラメータをマージ
4. 焦点距離を 35mm → ピクセル単位に変換
5. YOLOv26 による物体検出を実行
6. 各検出結果について三角測量で GPS 位置を推定
7. `detections` テーブルと `safety_points` テーブルに保存（重複排除あり）
8. 周辺の `edges` の安全スコアを更新（edges テーブルが空の場合はスキップ）
9. レスポンスを返却

### 重複排除ロジック

同一ラベル（`streetlight` 等）の既存 `SafetyPoint` が5m以内に存在する場合、新規作成せずに既存ポイントの検出結果リンクと座標を最新のものに更新する。

---

## POST /api/route

出発地と目的地を受け取り、安全スコア優先（`safe_route`）と最短距離優先（`shortest_route`）の2つのルートを返す。

### 実装状況: ✅ 実装済み

OSM道路ネットワーク（新潟県・群馬県）と pgRouting エンジンを利用した経路探索機能が実装されている。

### リクエスト形式: `application/json`

| パラメータ | 型 | 必須 | 説明 |
|---|---|---|---|
| `start_lat` | float (ge=-90.0, le=90.0) | ✅ | 出発地の緯度 |
| `start_lng` | float (ge=-180.0, le=180.0) | ✅ | 出発地の経度 |
| `end_lat` | float (ge=-90.0, le=90.0) | ✅ | 目的地の緯度 |
| `end_lng` | float (ge=-180.0, le=180.0) | ✅ | 目的地の経度 |
| `hazard_radius_m` | float (ge=0.0) | ❌ | ルート周辺の危険情報を検索・取得する範囲（メートル）。デフォルトは1000.0（1km） |

### レスポンス

| フィールド | 型 | 説明 |
|---|---|---|
| `safe_route` | RouteInfo | 安全スコア優先のルート情報 |
| `shortest_route` | RouteInfo | 最短距離優先のルート情報 |
| `nearby_hazards` | HazardPoint[] | ルート沿い（100m以内）の危険情報（犯罪・野生動物等。道路インフラ情報は含まない） |

**RouteInfo の構造:**

| フィールド | 型 | 説明 |
|---|---|---|
| `route` | GeoJSON FeatureCollection | エッジ（道路区間）ごとの Feature を含むルートデータ。各 Feature に区間別の `safety_score` が付与される |
| `distance_m` | float | ルートの総距離（メートル） |
| `safety_score` | float (0.01〜1.0) | ルート全体の安全スコア（エッジ長による加重平均） |

**FeatureCollection 内の各 Feature:**

各 Feature は1つの道路区間（エッジ）を表す。フロントエンドでは `safety_score` に応じて区間ごとに色分け描画できる。

| properties フィールド | 型 | 説明 |
|---|---|---|
| `safety_score` | float (0.01〜1.0) | この区間の安全スコア |

### レスポンス例

```json
{
  "safe_route": {
    "route": {
      "type": "FeatureCollection",
      "features": [
        {
          "type": "Feature",
          "geometry": {
            "type": "LineString",
            "coordinates": [[139.0634, 36.3895], [139.0632, 36.3897]]
          },
          "properties": { "safety_score": 0.90 }
        },
        {
          "type": "Feature",
          "geometry": {
            "type": "LineString",
            "coordinates": [[139.0632, 36.3897], [139.0628, 36.3900]]
          },
          "properties": { "safety_score": 0.20 }
        },
        {
          "type": "Feature",
          "geometry": {
            "type": "LineString",
            "coordinates": [[139.0628, 36.3900], [139.0602, 36.3908]]
          },
          "properties": { "safety_score": 0.80 }
        }
      ]
    },
    "distance_m": 645.76,
    "safety_score": 0.63
  },
  "shortest_route": {
    "route": {
      "type": "FeatureCollection",
      "features": [
        {
          "type": "Feature",
          "geometry": {
            "type": "LineString",
            "coordinates": [[139.0634, 36.3895], [139.0620, 36.3902]]
          },
          "properties": { "safety_score": 0.50 }
        },
        {
          "type": "Feature",
          "geometry": {
            "type": "LineString",
            "coordinates": [[139.0620, 36.3902], [139.0602, 36.3908]]
          },
          "properties": { "safety_score": 0.50 }
        }
      ]
    },
    "distance_m": 528.86,
    "safety_score": 0.50
  },
  "nearby_hazards": [
    {
      "id": 5,
      "lat": 36.3899,
      "lng": 139.0629,
      "source_type": "crime_report",
      "score_modifier": -0.30,
      "label": null,
      "confidence": null,
      "updated_at": "2026-07-01T12:00:00"
    }
  ]
}
```

---

## GET /api/hazards

地図上に表示するためのハザードポイント（安全/危険情報）一覧を返す。

### 実装状況: ✅ 実装済み

### パラメータ（すべてクエリパラメータ）

| パラメータ | 型 | 必須 | 説明 |
|---|---|---|---|
| `min_lat` | float | ❌ | バウンディングボックス南端の緯度 |
| `min_lng` | float | ❌ | バウンディングボックス西端の経度 |
| `max_lat` | float | ❌ | バウンディングボックス北端の緯度 |
| `max_lng` | float | ❌ | バウンディングボックス東端の経度 |
| `source_type` | string | ❌ | フィルタ: 情報源の種別（`detection`, `crime_report`） |

- バウンディングボックスの4パラメータが全て指定された場合のみ、範囲フィルタが有効になる。
- `is_visible = false` のポイントは常に除外される。
- 結果は `updated_at` の新しい順でソートされる。

### レスポンス

| フィールド | 型 | 説明 |
|---|---|---|
| `points` | HazardPoint[] | ハザードポイントのリスト |
| `count` | int | 返却されたポイント数 |

**HazardPoint の構造:**

| フィールド | 型 | 説明 |
|---|---|---|
| `id` | int | SafetyPoint の ID |
| `lat` | float | 緯度 |
| `lng` | float | 経度 |
| `source_type` | string | 情報源の種別（`detection`, `crime_report` 等） |
| `score_modifier` | float | 安全スコアへの影響値（正=安全、負=危険） |
| `label` | string? | 検出ラベル（`streetlight` 等）。`source_type` が `detection` の場合のみ |
| `confidence` | float? | YOLO の信頼度。`source_type` が `detection` の場合のみ |
| `event_type` | string? | イベント種別（`bear` 等）。`source_type` が `crime_report` の場合のみ |
| `updated_at` | datetime | 最終更新日時 |

### レスポンス例

```json
{
  "points": [
    {
      "id": 2,
      "lat": 36.39044,
      "lng": 139.0634,
      "source_type": "detections",
      "score_modifier": 0.1,
      "label": "streetlight",
      "confidence": 0.95,
      "event_type": null,
      "updated_at": "2026-06-17T05:29:22.035039"
    }
  ],
  "count": 1
}
```

---

## スコア定数一覧

| `score_modifier` の値は `app/core/score_config.py` で一元管理されている。

| ラベル | score_modifier | 影響半径(m) | 説明 |
|---|---|---|---|
| `streetlight` | +0.10 | 単一エッジ | 街灯: 夜間の視認性向上 |
| `traffic_light` | +0.05 | 単一エッジ | 信号機: 交通整理があり安全 |
| `utility_pole` | +0.02 | 単一エッジ | 電柱: 街灯と紐付くことが多い |
| `stop_sign` | +0.03 | 単一エッジ | 止まれ標識: 車両速度が下がり歩行者に有利 |
| `obstacle` | -0.15 | 単一エッジ | 障害物: 通行の妨げ |
| `puddle` | -0.10 | 単一エッジ | 水たまり: 転倒リスク |
| `crack` | -0.05 | 単一エッジ | 路面クラック: 転倒リスク（軽微） |
| `bear` | -0.80 | 1000m (減衰) | クマ: 極めて危険（中心部） |
| `wildlife` | -0.60 | 500m (減衰) | その他の野生動物: 危険 |
| `suspicious_person` | -0.40 | 300m (減衰) | 不審者 |
| `crime_violent` | -0.70 | 500m (減衰) | 凶悪犯罪 |
| その他 | 0.00 | - | 未定義ラベルのデフォルト |

---

## DBテーブル構成（参考）

| テーブル | 役割 |
|---|---|
| `users` | ユーザー情報（未実装: 認証後に使用） |
| `coin_transactions` | コイン付与履歴（未実装） |
| `detections` | YOLO検出結果の保存先 |
| `safety_points` | 安全/危険ポイントの統合テーブル（detections, crime_reports からリンク） |
| `crime_reports` | 犯罪情報（行政データ連携用、未実装） |
| `road_edges` | OSM道路ネットワーク（pgRouting用、新潟県・群馬県データ投入済み） |
---

## GET /api/places/search

Google Places API (Text Search) の中継（プロキシ）エンドポイント。
フロントエンド環境における CORS 制限の回避、および API キー隠蔽のために使用する。

### 実装状況: ✅ 実装済み

### リクエスト形式: URLクエリパラメータ

| パラメータ | 型 | 必須 | 説明 |
|---|---|---|---|
| `query` | string | ✅ | 検索キーワード（例: "コンビニ"、"東京駅"） |
| `location` | string | ❌ | 検索中心地の現在地（例: "35.6812,139.7671"） |
| `radius` | string | ❌ | 検索範囲メートル（例: "10000"） |

### 内部処理フロー

1. フロントエンドから受け取った `query`, `location`, `radius` パラメータを受け取る
2. バックエンド側で環境変数の `GOOGLE_MAPS_API_KEY` を付加し、同時に `language=ja`, `region=jp` を追加する
3. `https://maps.googleapis.com/maps/api/place/textsearch/json` にリクエストを送信する
4. Google API から返ってきた JSON レスポンスをそのままフロントエンドに返却する

### レスポンス

Google Places API のレスポンス形式に準拠する JSON オブジェクトが返却される。

---

## GET /api/places/nearby

Google Places API (Nearby Search) の中継（プロキシ）エンドポイント。
フロントエンド環境における CORS 制限の回避、および API キー隠蔽のために使用する。

### 実装状況: ✅ 実装済み

### リクエスト形式: URLクエリパラメータ

| パラメータ | 型 | 必須 | 説明 |
|---|---|---|---|
| `lat` | float | ✅ | 検索中心の緯度 |
| `lng` | float | ✅ | 検索中心の経度 |

### 内部処理フロー

1. フロントエンドから受け取った `lat`, `lng` パラメータを受け取る
2. バックエンド側で環境変数の `GOOGLE_MAPS_API_KEY` と `language=ja` を付加し、さらに距離順で最寄りの施設を取得するため内部的に `rankby=distance`, `type=point_of_interest` を指定する
3. `https://maps.googleapis.com/maps/api/place/nearbysearch/json` にリクエストを送信する
4. Google API から返ってきた JSON レスポンスをそのままフロントエンドに返却する

### レスポンス

Google Places API のレスポンス形式に準拠する JSON オブジェクトが返却される。

---

## GET /api/places/details

Google Places API (Place Details) の中継（プロキシ）エンドポイント。
指定した施設の詳細情報（レビューや写真情報など）を取得する。

### 実装状況: ✅ 実装済み

### リクエスト形式: URLクエリパラメータ

| パラメータ | 型 | 必須 | 説明 |
|---|---|---|---|
| `place_id` | string | ✅ | 施設を一意に識別する Google Place ID |

### レスポンス

Google Places API のレスポンス形式に準拠する JSON オブジェクトが返却される。

---

## GET /api/places/photo

Google Places API (Place Photo) の中継（プロキシ）エンドポイント。
施設に紐づく画像（写真）を取得する。

### 実装状況: ✅ 実装済み

### リクエスト形式: URLクエリパラメータ

| パラメータ | 型 | 必須 | 説明 |
|---|---|---|---|
| `photo_reference` | string | ✅ | 画像のリファレンス文字列（Details API等から取得したもの） |
| `maxwidth` | int | ❌ | 画像の最大幅。デフォルトは 400 |

### レスポンス

- **302 Found**: 実際の画像データ（Googleのサーバー）へリダイレクトされる。フロントエンドでは `<img>` タグの `src` 属性にこのAPIのエンドポイントURLをそのまま指定するだけで、自動的に画像が表示される。

---

## GET /api/coverage

情報空白地帯可視化機能のためのカバレッジ情報（セルごとの情報密度）を取得する。

### 実装状況: ✅ 実装済み

### リクエスト形式: URLクエリパラメータ

| パラメータ | 型 | 必須 | 説明 |
|---|---|---|---|
| `min_lat` | float | ✅ | マップ画面の表示範囲（バウンディングボックス南端の緯度） |
| `min_lng` | float | ✅ | マップ画面の表示範囲（バウンディングボックス西端の経度） |
| `max_lat` | float | ✅ | マップ画面の表示範囲（バウンディングボックス北端の緯度） |
| `max_lng` | float | ✅ | マップ画面の表示範囲（バウンディングボックス東端の経度） |
| `zoom` | float | ✅ | 現在のマップのズームレベル（これによって集計解像度が変わる） |

### レスポンス

事前集計されたカバレッジテーブルから、指定範囲内の**データが存在するセルのみ**を返す。データ量が膨大になっても常に高速なレスポンスが保証される。

| フィールド | 型 | 説明 |
|---|---|---|
| `cells` | CoverageCellResponse[] | データが存在するセルのリスト |
| `cell_size` | float | 返却されたセルのサイズ（度単位） |
| `total_cells` | int | 返却されたセルの数 |

**CoverageCellResponse の構造:**

| フィールド | 型 | 説明 |
|---|---|---|
| `lat` | float | セル南端の緯度 |
| `lng` | float | セル西端の経度 |
| `count` | int | このセルに含まれる SafetyPoint の数（情報量） |

### レスポンス例

```json
{
  "cells": [
    {
      "lat": 36.390,
      "lng": 139.060,
      "count": 3
    }
  ],
  "cell_size": 0.002,
  "total_cells": 1
}
```

### フロントエンド実装の注意点

- **色分けロジック**: バックエンドは `count`（件数）のみを返す。何件なら何色にするかはフロント側で定義する。
- **空白領域の扱い**: APIはデータがあるセル（`count > 0`）しか返さない。APIから返却されなかったマップ上の領域は全て「情報空白地帯」として扱い、フロント側で一律に灰色（未調査・情報なし）で表現すること。

---

## POST /api/notifications/register

FCMデバイストークンを登録・更新し、プッシュ通知を有効にするエンドポイント。

### 実装状況: ✅ 実装済み

### ヘッダー

| キー | 必須 | 説明 |
|---|---|---|
| `Authorization` | ✅ | `Bearer <JWTトークン>` 形式。認証必須。 |

### リクエスト形式: `application/json`

| フィールド | 型 | 必須 | 説明 |
|---|---|---|---|
| `fcm_token` | string | ✅ | Firebase から発行されるデバイストークン |
| `notification_radius_m` | float | ❌ | 通知を受け取る範囲（メートル）。100m〜100km。デフォルト: 5000.0 |

### レスポンス例

```json
{
  "status": "registered",
  "notification_radius_m": 5000.0
}
```

| フィールド | 説明 |
|---|---|
| `status` | 新規登録なら `"registered"`、既存レコード更新なら `"updated"` |
| `notification_radius_m` | 設定された通知範囲（メートル） |

### 内部処理フロー

1. JWTトークンからユーザーを特定
2. `device_tokens` テーブルに同一ユーザーのレコードが存在すれば更新、なければ新規作成
3. レスポンスを返却

---

## POST /api/crime-reports

危険情報（クマ出没・不審者等）を新規登録し、FCMトークンを登録している全ユーザーへプッシュ通知を送信するエンドポイント。

### 実装状況: ✅ 実装済み

### 認証: 不要（デモ・外部トリガーからも利用可能）

### リクエスト形式: `application/json`

| フィールド | 型 | 必須 | 説明 |
|---|---|---|---|
| `event_type` | string | ✅ | 危険種別。例: `"bear"`（クマ）, `"suspicious_person"`（不審者）, `"traffic"`（交通事故）, `"disaster"`（災害） |
| `description` | string | ❌ | 詳細な説明文 |
| `lat` | float | ✅ | 発生場所の緯度 |
| `lng` | float | ✅ | 発生場所の経度 |
| `occurred_at` | datetime | ✅ | 発生日時（ISO 8601形式。例: `"2026-07-24T10:30:00"`） |

### リクエスト例

```json
{
  "event_type": "bear",
  "description": "住宅地付近でクマが目撃されました。外出時は注意してください。",
  "lat": 37.3456,
  "lng": 138.9012,
  "occurred_at": "2026-07-24T10:30:00"
}
```

### レスポンス例

```json
{
  "id": 42,
  "event_type": "bear",
  "lat": 37.3456,
  "lng": 138.9012,
  "occurred_at": "2026-07-24T10:30:00",
  "notified_users": 3
}
```

| フィールド | 説明 |
|---|---|
| `id` | 新しく登録された crime_report の ID |
| `notified_users` | 通知を送信したデバイス数 |

### 内部処理フロー

1. `crime_reports` テーブルに登録
2. `safety_points` テーブルにも紐付けて登録（ハザードマップに即反映）
3. `device_tokens` テーブルに登録されている全ユーザーに対して FCM プッシュ通知を送信
4. レスポンスを返却（通知送信が失敗しても 500 にはならず、DB登録は確定する）

### FCM通知のフォーマット

| 項目 | 内容 |
|---|---|
| タイトル | `⚠️ 近くでクマが目撃されました`（event_type に応じて変化） |
| 本文 | `description` が指定された場合はそれを使用。なければデフォルトメッセージ |
| data payload | `{"type": "crime_report", "event_type": "bear", "lat": "37.3456", "lng": "138.9012", "crime_report_id": "42"}` |

### 前提条件

バックエンドの `.env` に以下の設定が必要（フロントエンド担当者がFirebaseコンソールから取得）：

```
GOOGLE_APPLICATION_CREDENTIALS=./firebase-service-account.json
```
設定されていない場合、危険情報のDB登録は成功するが通知は送信されない（ログにドライラン旨が記録される）。

---

## GET /api/crime-reports

登録されている危険情報（クマ出没等）の一覧を返す。
特にデモ等での「Web版・リアルタイムアラート（ポーリング検知）」機能用に、指定ID以降の新着データのみを引き出す仕組みを標準搭載する。

### 実装状況: ✅ 実装済み（差分ポーリング完全対応）

### 認証: 不要

### クエリパラメータ

| キー | 型 | 必須 | デフォルト | 説明 |
|---|---|---|---|---|
| `after_id` | integer | ❌ | `null` | 指定した `id` より大きい（＝それ以降に登録された）レコードのみを古い順で取得 |
| `limit` | integer | ❌ | 20 | 取得する最大件数（1〜100） |

### レスポンス例（※ 以下は新着1件検知時の一例であり、description等は投稿データにより変化する）

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

> **注記:**
> `description` のフィールドは、実際に投稿（あるいは検出・登録）された危険情報のテキストが入る可変文字列であり、上記レスポンス例のような【頭数】【状況】等の形式で動的に提供される。固定文言ではないため、UI上に可変コンテンツとしてそのまま描画すること。

### フロントエンド（ポーリングによるリアルタイムアラート演出）での活用推奨フロー

1. アプリ起動・画面初期化時: `GET /api/crime-reports?limit=1` をパラメータなしで呼び、取得できた中の最大の `id` を初期の `lastKnownId` 変数に記録する。
2. 3〜5秒のタイマー間隔にて `GET /api/crime-reports?after_id={lastKnownId}` をクエリ実行し続ける。
3. `after_id` より新しく登録されたレポートがあれば（配列の長さ `length > 0`）、新着と判断してポップアップダイアログやバナー警告をユーザーへ表示する！
4. 表示直後に `lastKnownId` を取得した中で一番大きな `id` に更新することで、二度同じアラートが出現する現象を100%遮断・完全制御する。

---

## POST /api/detections/debug

プレゼン本番デモやデバッグ専用の、画像および複雑な EXIF 情報を必要としない「即時路上アセット登録＆シミュレーションAPI」。
クリックされた座標を「三角測量済み実質位置（位置精度: `high`）」と見立て、ただちに `SafetyPoint` への追加と周辺道路のハザードコスト・安全スコアの再計算・適用を実行する。

### 実装状況: ✅ 実装済み（デバッガ・シミュレータ全連動）
### 認証: 不要
### リクエストボディ (JSON)

| フィールド | 型 | 必須 | デフォルト | 説明 |
|---|---|---|---|---|
| `label` | string | ○ | `-` | 検出ラベル。例: `streetlight` (街灯: +0.2点), `sidewalk` (歩道: +0.3点) |
| `lat` | float | ○ | `-` | 検出対象の緯度 |
| `lng` | float | ○ | `-` | 検出対象の経度 |
| `confidence` | float | ❌ | 0.99 | 推論信頼度 |

---

## GET /demo （プレゼンテーション統合シミュレーションポータル）

バックエンド（FastAPI）に直接導入されたスタンドアロンの **デモ専用マスターマップコンソール画面 (HTML / JS / CSS 統合機能)**。
フロントエンドへのコード改変や処理過重などの依存を一切ゼロにし、**`http://localhost:8000/demo`** にアクセスするだけで専用操作盤面を起動する。

### 最大の特徴・機能仕様
- **直感的マップ操作:** 日本/ローカル領域が収容されたスタイリッシュな暗黒ベースのタイル地図を展開。任意の地点をクリックするだけで経緯度をミリレベルで瞬時に獲得・自動設定。
- **モード①（緊急アラート生成・発射）:** 熊（`bear`）や不審者などをプルダウン選択し、生々しいリアリティーな詳細データ（「【頭数】1.0 【状況】…」等）を標準搭載した上で一押し発令！**発生時刻（`occurred_at`）は完全自動・現在のシステム正確日時**で刻まれる。
- **モード②（道路対象 街灯/歩道の配置成約）:** マップクリックした地点を「三角測量の完了した実情ターゲット座標」と見做し、ワンタップで街灯（`streetlight`）や歩道（`sidewalk`）を安全マップおよびハザード計算ロジックへ流し込み、周辺ルートスコアの塗り替えを瞬発的に実現。
- **内蔵ターミナルログ:** リクエストや生成ID、実行可否のメッセージを取り込めるコンソールバーを下部にビルトイン。

---

## ルート保存・通知に関する API

選択したルート（安全ルート・最短距離ルート）をアカウントへ保存し、保存したルート沿いで危険情報（クマ・野生動物・不審者など）が新規登録された際にアラートを通知するための機能。
`POST /api/crime-reports` 実行時にバックエンド側の空間クエリ (`ST_DWithin`) を通じて沿道の危険判定がなされ、該当する場合に自動で `route_alerts` レコードが蓄積される。

---

## POST /api/saved-routes

新しくルートを計算し、アカウントに保存する。

### 実装状況: ✅ 実装済み
### 認証: ○ （必須: `Authorization: Bearer <token>`）

### リクエストボディ (JSON)
| フィールド | 型 | 必須 | デフォルト | 説明 |
|---|---|---|---|---|
| `start_lat` | float | ○ | `-` | 出発地の緯度 (-90.0〜90.0) |
| `start_lng` | float | ○ | `-` | 出発地の経度 (-180.0〜180.0) |
| `end_lat` | float | ○ | `-` | 目的地の緯度 (-90.0〜90.0) |
| `end_lng` | float | ○ | `-` | 目的地の経度 (-180.0〜180.0) |
| `route_type` | string | ❌ | `"safe"` | ルート種別: `"safe"` または `"shortest"` |
| `notification_radius_m` | float | ❌ | `500.0` | このルート沿いで危険情報を検知する半径（メートル: 50.0〜5000.0） |
| `name` | string | ❌ | `null` | ルートの任意名称（最大100文字） |

### レスポンス
**201 Created**
```json
{
  "id": 1,
  "user_id": 2,
  "start_lat": 36.3895,
  "start_lng": 139.0634,
  "end_lat": 36.4000,
  "end_lng": 139.0700,
  "route_type": "safe",
  "notification_radius_m": 500.0,
  "name": "通勤ルート",
  "created_at": "2026-07-27T00:00:00"
}
```

---

## GET /api/saved-routes

ログインユーザーが保存したルートの一覧を取得する（作成日時順）。

### 実装状況: ✅ 実装済み
### 認証: ○ （必須: `Authorization: Bearer <token>`）

### レスポンス
**200 OK**: 保存されたルートのオブジェクトの JSON 配列

---

## DELETE /api/saved-routes/{route_id}

指定した保存ルートを削除する。関連する発生済みのルート沿いアラート履歴 (`route_alerts`) も同時に連鎖（CASCADE）削除される。

### 実装状況: ✅ 実装済み
### 認証: ○ （必須: `Authorization: Bearer <token>`）

### レスポンス
**204 No Content** （削除完了・レスポンスボディなし）

---

## GET /api/saved-routes/alerts

保存されたルートの `notification_radius_m` メートル以内で新規に登録・発生した危険情報アラート履歴を取得する（差分ポーリング専用対応）。

### 実装状況: ✅ 実装済み
### 認証: ○ （必須: `Authorization: Bearer <token>`）

### クエリパラメータ
| パラメータ | 型 | 必須 | デフォルト | 説明 |
|---|---|---|---|---|
| `after_id` | integer | ❌ | `null` | 指定したIDより大きい新着の沿道アラートのみを古い順で取得する |
| `limit` | integer | ❌ | `20` | 最大取得件数 (1〜100) |

### レスポンス
**200 OK**
```json
[
  {
    "id": 1,
    "saved_route_id": 1,
    "crime_report_id": 18,
    "event_type": "bear",
    "description": "【頭数】1.0 【状況】道路横の木立付近で目撃",
    "report_lat": 36.3950,
    "report_lng": 139.0660,
    "occurred_at": "2026-07-27T00:10:00",
    "created_at": "2026-07-27T00:10:05"
  }
]
```

### フロントエンド（ルート沿いリアルタイムアラート）での推奨ポーリング実装仕様
1. 初期化: `GET /api/saved-routes/alerts` をパラメータなしで呼び、配列内における最新（最大）の `id` を初期化時の基準IDとして `lastKnownRouteAlertId` 等の変数へ一時記録する。
2. 差分監視: 地図画面等で `GET /api/saved-routes/alerts?after_id={lastKnownRouteAlertId}` を定期的（4秒間隔等）にクエリ実行する。
3. 検知と更新: 1件以上の要素 (`length > 0`) が返ってきた場合は自動的に保存ルート周辺の危険発生とみなし、警告表示（ダイアログ等）を展開する。展開直後に `lastKnownRouteAlertId` を今回受信した最大の `id` へ更新し、通知の二度鳴りを完全に防ぐ。
