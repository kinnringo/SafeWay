# SafeWay Backend API 仕様書

最終更新: 2026-07-01

ベースURL: `http://localhost:8000`

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

### リクエスト形式: `multipart/form-data`

| パラメータ | 型 | 必須 | 説明 |
|---|---|---|---|
| `image` | File | ✅ | 解析する画像ファイル（JPEG/PNG） |
| `lat` | float | ❌ | 撮影者の緯度。省略時はEXIFから自動抽出 |
| `lng` | float | ❌ | 撮影者の経度。省略時はEXIFから自動抽出 |
| `bearing` | float | ❌ | コンパス方位角（度、0=北、時計回り）。省略時はEXIFのGPSImgDirectionから抽出 |
| `focal_length_35mm` | float | ❌ | 35mm換算焦点距離（mm）。省略時はEXIFから抽出 |
| `test_mode` | bool | ❌ | `true` の場合、YOLOが未検出でもダミーの街灯検出を1つ注入する（デバッグ用） |

**パラメータ優先順位**: Form フィールドの値 > EXIF から抽出した値 > エラーまたはフォールバック

**位置推定精度**:
- `bearing` と `focal_length_35mm` の両方が取得できた場合: `position_accuracy = "high"`（三角測量で対象物の実位置を推定）
- いずれかが不足している場合: `position_accuracy = "low"`（撮影者位置をフォールバックとして使用）

### レスポンス

| フィールド | 型 | 説明 |
|---|---|---|
| `detections` | DetectionResult[] | 検出結果のリスト |
| `user_lat` | float | 撮影者の緯度 |
| `user_lng` | float | 撮影者の経度 |
| `updated_score` | float (0.0〜1.0) | 更新後の安全スコア（暫定計算値） |

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
  "updated_score": 0.6
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
      "updated_at": "2026-06-17T05:29:22.035039"
    }
  ],
  "count": 1
}
```

---

## スコア定数一覧

`score_modifier` の値は `app/core/score_config.py` で一元管理されている。

| ラベル | score_modifier | 説明 |
|---|---|---|
| `streetlight` | +0.10 | 街灯: 夜間の視認性向上 |
| `traffic_light` | +0.05 | 信号機: 交通整理があり安全 |
| `utility_pole` | +0.02 | 電柱: 街灯と紐付くことが多い |
| `stop_sign` | +0.03 | 止まれ標識: 車両速度が下がり歩行者に有利 |
| `obstacle` | -0.15 | 障害物: 通行の妨げ |
| `puddle` | -0.10 | 水たまり: 転倒リスク |
| `crack` | -0.05 | 路面クラック: 転倒リスク（軽微） |
| `crime_report` | -0.30 | 犯罪報告: 最も重大な危険指標 |
| その他 | 0.00 | 未定義ラベルのデフォルト |

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
