# SafeWay データベーススキーマ定義

本ドキュメントでは、SafeWay バックエンドシステム（PostgreSQL / PostGIS）の主要なテーブル構成と、各カラムの役割について記載します。

## 概要

システムは主に以下のデータグループで構成されています。
1. **ユーザー・エコノミー系** (`users`, `coin_transactions`)
2. **収集データ系** (`detections`, `crime_reports`)
3. **ルーティング・評価系** (`safety_points`, `road_edges`)
4. **通知系** (`device_tokens`)

---

## 1. users (ユーザー情報)

利用ユーザーのアカウント情報と、獲得したコイン（リワード）を管理します。

| カラム名 | 型 | 制約 | 説明 |
|---|---|---|---|
| `id` | Integer | PK | ユーザーID |
| `username` | String | Unique, NotNull | ユーザー名 |
| `password_hash` | String | NotNull | パスワードのハッシュ値 |
| `coins` | Integer | NotNull, Default:0 | 現在の保有コイン数 |
| `created_at` | DateTime | NotNull | アカウント作成日時 |

---

## 2. coin_transactions (コイントランザクション)

ユーザーに対するコインの付与・消費履歴を管理します。街灯情報の投稿等のリワード付与に使用されます。

| カラム名 | 型 | 制約 | 説明 |
|---|---|---|---|
| `id` | Integer | PK | トランザクションID |
| `user_id` | Integer | FK(users.id), NotNull | 対象のユーザーID |
| `amount` | Integer | NotNull | 変動量（正は獲得、負は消費） |
| `reason` | String | NotNull | 付与・消費の理由（例: "投稿リワード"） |
| `created_at` | DateTime | NotNull | 取引発生日時 |

---

## 3. detections (物体検出結果)

ユーザーがアップロードした画像から、YOLOv26 等のAIによって検出された物体（街灯、障害物など）の情報を保持します。

| カラム名 | 型 | 制約 | 説明 |
|---|---|---|---|
| `id` | Integer | PK | 検出結果ID |
| `user_id` | Integer | FK(users.id), Nullable| 投稿したユーザーID |
| `label` | String | NotNull | 検出ラベル（例: "streetlight", "obstacle"） |
| `confidence` | Float | NotNull | AIの推論信頼度 (0.0〜1.0) |
| `image_path` | String | Nullable | 元画像の保存パス |
| `geom` | Geometry(POINT) | NotNull | 検出物体の推定座標 (SRID: 4326) |
| `position_accuracy` | String | NotNull, Default:"low"| 位置推定精度。"high"（三角測量成功）または "low"（撮影者位置フォールバック） |
| `estimated_distance_m` | Float | Nullable | カメラから物体までの推定水平距離。"low"精度時はNull。 |
| `created_at` | DateTime | NotNull | 検出日時 |

---

## 4. crime_reports (犯罪・危険報告)

外部APIや警察情報等から取り込んだ、犯罪や野生動物などの危険事象データを保持します。

| カラム名 | 型 | 制約 | 説明 |
|---|---|---|---|
| `id` | Integer | PK | 報告ID |
| `event_type` | String | NotNull | イベント種別（例: "wildlife", "suspicious_person"） |
| `description` | String | Nullable | 詳細な説明 |
| `geom` | Geometry(POINT) | NotNull | 発生場所の座標 (SRID: 4326) |
| `occurred_at` | DateTime | NotNull | 発生日時 |
| `created_at` | DateTime | NotNull | データ登録日時 |

---

## 5. safety_points (安全・危険ポイント)

`detections` や `crime_reports` から生成される、「ルーティングに影響を与える評価ポイント（統合ハザード情報）」を管理します。このデータに基づいて周辺道路の安全スコアが計算されます。

| カラム名 | 型 | 制約 | 説明 |
|---|---|---|---|
| `id` | Integer | PK | ポイントID |
| `source_type` | String | NotNull | 情報ソース種別（"detection", "crime_report", "wildlife" など） |
| `detection_id` | Integer | FK(detections.id), Nullable | 紐づく物体検出ID |
| `crime_report_id` | Integer | FK(crime_reports.id), Nullable | 紐づく犯罪報告ID |
| `score_modifier` | Float | NotNull | 安全スコアへの影響値（正=安全、負=危険） |
| `influence_radius_m` | Float | NotNull, Default:20.0 | スコアに影響を及ぼす最大半径（メートル）。広域ハザードの距離減衰計算に使用 |
| `is_road_attribute` | Boolean | NotNull, Default:False | Trueの場合、周辺の全エッジではなく「空間的に最も近い1本のエッジ」のみにスコアを適用する（街灯など道路属性用） |
| `geom` | Geometry(POINT) | NotNull | ポイント座標 (SRID: 4326) |
| `is_visible` | Boolean | NotNull, Default:True | 評価・表示に有効かどうか |
| `updated_at` | DateTime | NotNull | 最終更新日時 |

---

## 6. road_edges (道路ネットワークエッジ)

ルーティングエンジン（pgRouting）で使用する道路区間ネットワークデータです。OSM（OpenStreetMap）等のデータをベースとし、周辺の `safety_points` によって動的にスコアとコストが更新されます。

| カラム名 | 型 | 制約 | 説明 |
|---|---|---|---|
| `id` | Integer | PK | エッジID |
| `osm_id` | BigInteger | Nullable | 元となる OSM の Way ID |
| `source_node` | Integer | Nullable | 始点ノードID（pgRouting用） |
| `target_node` | Integer | Nullable | 終点ノードID（pgRouting用） |
| `length` | Float | NotNull | 区間の物理的な距離（メートル） |
| `geom` | Geometry(LINESTRING)| NotNull | 区間の線分ジオメトリ (SRID: 4326) |
| `base_safety_score` | Float | NotNull, Default:0.5 | 道路の基本安全スコア |
| `dynamic_safety_score`| Float | NotNull, Default:0.0 | 周辺の `safety_points` によって加減算される変動値 |
| `safety_score` | Float | NotNull, Default:0.5 | 最終的な安全スコア (base + dynamic)。0.01〜1.0 に丸められる |
| `routing_cost` | Float | Nullable | 経路探索コスト。`length × (1.0 / safety_score)` で算出される |

---

## 8. device_tokens (FCMデバイストークン)

プッシュ通知のためのFCMデバイストークンと、通知を受け取る範囲設定を管理します。
ユーザーは通知範囲（半径）を任意に設定できます（100m〜100km）。

| カラム名 | 型 | 制約 | 説明 |
|---|---|---|---|
| `id` | Integer | PK | |
| `user_id` | Integer | FK → users.id, Unique | ユーザーID（1ユーザー1レコード） |
| `fcm_token` | String | NotNull | Firebase Cloud Messaging のデバイストークン |
| `notification_radius_m` | Float | NotNull, Default:5000 | 通知を受け取る範囲（メートル）。デフォルト5km |
| `updated_at` | DateTime | NotNull | 最終更新日時 |
