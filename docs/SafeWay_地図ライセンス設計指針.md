# SafeWay 地図関連 規約・ライセンス設計指針

**対象読者:** SafeWayの設計・実装を担当するエージェント／開発者
**目的:** Google Maps Platform利用規約 と OpenStreetMap(OSM)のODbLライセンスに関する制約を理解した上で、「ベースマップ・場所検索＝Google Maps Platform／経路計算＝OSM(OSMnx)」構成を安全に実装するための設計ルールを共有する。

---

## 1. 前提：SafeWayの現状構成

- **ベースマップ表示・場所検索・建物情報:** Google Maps SDK / Places API / Geocoding API
- **経路計算（バックエンド処理のみ）:** OSM/OSMnx
- 計算されたルートは座標配列としてフロントに返され、Google Map上に線として描画される

この構成自体は明示的に禁止されていない。Google自身が「Google地図＋第三者ルーティングエンジン」の組み合わせを規約上で想定・許容している（後述2.3）。ただし各要素に厳密な条件が付くため、以下に整理する。

---

## 2. Google Maps Platform利用規約 上のルール

### 2.1 非Google地図との併用禁止（"No Use With Non-Google Maps"）

**ルール:** Google Maps Core Servicesを、同一Customer Application内で非Google地図と併用・近接表示してはならない。

**厳密な適用条件（＝これに当てはまると違反になる）:**
- 非Google地図（OSMタイル等）を**画面上にレンダリングして**表示している
- Google由来のコンテンツ（Places情報等）を非Google地図の上に表示している
- Street View画像と非Google地図を同一画面に表示している
- Google Mapを非Google地図（またはそのコンテンツ）にリンクさせている

**現状評価:** OSMタイルを画面表示していないため非該当。

**設計ルール①:**
> OSMのタイルレイヤー・地図ビューはアプリのどの画面にも一切実装しない（フォールバック表示・デバッグ画面も含む）。もし将来「オフライン時はOSMタイルを表示する」等の仕様を追加する場合は、この条項に抵触するため要再検討。

**ソース:** Google Maps Platform Terms of Service, Section 3.2 (License Restrictions) — https://cloud.google.com/maps-platform/terms

---

### 2.2 Googleコンテンツの持ち出し禁止（"No Scraping / Export"）

**ルール（原文要旨）:**
> You will not export, extract, or otherwise scrape any content provided in or through Google Maps Content for use outside the Google Maps Content.

**厳密な適用条件（＝これに当てはまると違反になりうる）:**
- Geocoding/Places APIの応答（住所文字列・building情報・レビュー・写真等）を、Googleのサービス外のシステムに保存・転送し、**その情報自体を再利用**している
- Google Maps tiles / Street View画像 / directions / distance matrix結果などを一括ダウンロード・保存・再ホストしている
- キャッシュ許容期間（原則30日、place_idは無期限）を超えてlat/lng等を保持している

**例外（重要）:**
> ユーザーがオートコンプリート機能で住所を選択し、その住所がユーザー自身の入力でも得られたであろうものである場合、その選択された住所は、**そのユーザーの取引目的に限り**、Google Maps Contentの制約対象外となる。

**現状評価:** ユーザーが検索・選択した地点の座標をOSMのルーティングエンジンに渡す行為は、上記例外に該当し非該当と考えられる。ただし「その場限りの利用」が条件であり、選択結果を独自データベースとして蓄積・再配布する場合は対象外にならない点に注意。

**設計ルール②:**
> Google Places/Geocoding APIの検索結果は、ユーザーがその場で選択した地点についてのみ、その場の経路計算リクエストに使ってよい。ただし以下は禁止：①検索結果（住所・座標・建物情報）をSafeWay独自のDBに永続保存して再利用する、②Places/Geocodingの応答を30日を超えてキャッシュする（place_id除く）、③取得した建物情報をGoogle Map以外の場所に表示する。

**ソース:**
- No Scraping条項: Google Maps Platform Terms of Service, Section 3.2.3 — https://cloud.google.com/maps-platform/terms
- Autocomplete例外規定: Policies and attributions for Places API — https://developers.google.com/maps/documentation/places/web-service/policies
- キャッシュ期間: Policies and attributions for Geocoding API — https://developers.google.com/maps/documentation/geocoding/policies

---

### 2.3 第三者ルーティングとの組み合わせ

**ルール:** Googleは「Google地図＋非Google提供のルーティング/ナビゲーション」の組み合わせを禁止しておらず、条件付きで明示的に許容している。

**厳密な適用条件（＝これを満たさないと違反になる）:**
- 非Google提供のルートをGoogle地図上または隣接して使用する場合、**ナビゲーション開始前にUI上で「Routing provided by [第三者名]」等、提供元を明確に表示すること**
- 第三者サービスとの組み合わせについて、法令・業界標準等への準拠はCustomer（SafeWay側）の責任となる
- Googleは第三者サービスとの組み合わせについて保証・責任を負わない旨に同意していること（利用規約上自動的に適用）

**現状評価:** 現在UIに「ルート提供元」表示が無い場合は、この条件を満たしていない可能性がある。

**設計ルール⑤（新規）:**
> ルート表示画面（ナビゲーション開始前）に「経路情報: OpenStreetMap」等、Google以外が提供している旨をユーザーに分かる形で表示する。デザイン上は帰属表示と統合してもよいが、省略しないこと。

**ソース:** Google Maps Platform EEA Service Specific Terms, Section 4.2–4.3 — https://cloud.google.com/terms/maps-platform/eea/maps-service-terms
（※EEA向け条項だが、Googleの一般的な運用方針を示す一次情報として参照。日本向け契約でも同種の要求がある可能性を考慮し、予防的に採用することを推奨）

---

### 2.4 帰属表示の一般原則

**厳密な適用条件:**
- Google提供の帰属表示（ロゴ、著作権表示、データプロバイダ名）を削除・改変・隠蔽しない
- Google由来のコンテンツと、それ以外（OSM等）のコンテンツを、ユーザーから見て明確に区別できるようにする（枠線・背景色・見出し等のUI上の工夫）
- Places APIのデータ（写真・レビュー等）を表示する場合、著者情報・出典リンクも表示する

**設計ルール⑥:**
> UI設計時、「これはGoogle由来」「これはOSM由来」が視覚的に区別できるようにする（例: ベースマップ＝Googleロゴ表示、ルート線の凡例に「経路: OpenStreetMap」）。

**ソース:** Policies and attributions for Places/Geocoding API — https://developers.google.com/maps/documentation/places/web-service/policies

---

### 2.5 Directions API（最短経路）とOSM安全経路の同時表示

**背景:** SafeWayは「独自の安全経路（OSMベース）」と「最短経路」を同時に表示する予定。最短経路をGoogle Directions API / Routes APIで計算することの可否。

**ルール:** Directions APIの結果はGoogle Mapと併用する限り問題ない。

**厳密な適用条件:**
- Directions API（Google Maps Content）を**非Google地図と併用しない**（Google Map上にのみ描画する）
- Directions API結果のlat/lngは30日を超えてキャッシュしない
- Directions APIとGeolocation API、Maps SDK for Androidを組み合わせて、**Googleマップアプリ本体とほぼ同じリアルタイムナビゲーション機能（ターンバイターン音声案内＋自動再ルーティング等）を再現しない**（3.2.3(d)(iv) "No Re-Creating Google Products or Features"に抵触する）
- SafeWay独自の安全スコアリング機能など、"substantial, independent value"（Googleの機能を超えた独自価値）を維持する

**現状評価:** 「最短経路（Google）」と「安全経路（独自）」を並べて表示する機能自体は、Googleの標準ナビを再現するものではなく独自価値があるため問題なし。ただし将来的にDirections API単体でフル機能のターンバイターンナビまで実装する場合は要再検討。

**設計ルール⑦:**
> 最短経路はGoogle Directions API（またはRoutes API）を使い、必ずGoogle Map上に描画する。安全経路と視覚的に区別できる色・凡例を用意する。「Googleナビの完全な代替品」にならないよう、安全スコアリング等の独自機能を常に主軸に置く。

**ソース:**
- Directions API固有条項（Google Mapとの併用要件）: Google Maps Platform Service Specific Terms — https://cloud.google.com/maps-platform/terms/maps-service-terms
- No Re-Creating Google Products or Features: Google Maps Platform Terms of Service, Section 3.2.3(d) — https://cloud.google.com/maps-platform/terms

### 2.6 「ベンチマーキング」条項との違い（誤解注意）

**ルール:** 3.2.4 Benchmarkingは、Google Maps Platformの比較テスト結果を**公に開示する場合**にのみ適用される条項であり、アプリ内でユーザーに2つのルートを並べて見せる機能そのものには適用されない。

**厳密な適用条件（＝これに当てはまると開示義務が生じる）:**
- 「GoogleのルーティングはOSMよりXX%遅い／安全性が低い」等の比較・ベンチマーク結果を**外部に公表**する（プレスリリース、ブログ、コンテスト発表資料等）
- その場合、Googleや第三者がテストを再現できるだけの情報を開示に含める必要がある

**現状評価:** アプリ内UIで両ルートを表示するだけなら非該当。ただしGPA等のコンテストで「Googleの最短経路と比較して当アプリの安全経路はこう優れている」という**比較データを公表資料に載せる場合は要注意**。

**設計ルール⑧（新規）:**
> コンテスト発表・ブログ等でGoogleルーティングとの比較結果を公表する場合は、再現可能な情報（比較条件・データ）を併記するか、定量的な優劣比較の公表自体を避け、「安全性を考慮した独自ルートを提案する」という機能説明にとどめる。

**ソース:** Google Maps Platform Terms of Service, Section 3.2.4 (Benchmarking) — https://cloud.google.com/maps-platform/terms

---

## 3. OpenStreetMap（ODbL）ライセンス上のルール

### 3.1 "Produced Work" と "Derivative Database" の区別

**ルール:** OSMデータを検索・処理して得た出力物（Produced Work）は帰属表示のみで足りるが、OSMデータを他データと結合して新しいデータベースを作った場合（Derivative Database）はシェアアライク義務が生じる。

**厳密な適用条件（Produced Workとして扱ってよい条件）:**
- OSMデータベースへの問い合わせ・計算処理の**結果のみ**（座標配列、経路案内テキスト等）を出力・保持している
- 出力物から元のOSMデータベース全体・実質部分を**復元できない**
- OSMの道路網データ自体を改変・保存・再配布していない

**この条件から外れると違反になりうる例:**
- OSMの道路網データを丸ごと（または実質的な部分を）SafeWayのサーバーに永続的に複製・保存し、それを別サービスに提供する
- OSMデータと独自データを恒久的に結合し、新しいデータセットとして第三者に配布する

**設計ルール③:**
> アプリ内（設定画面／アバウト画面）に `© OpenStreetMap contributors` の表記と、ODbLライセンスへのリンク（ https://www.openstreetmap.org/copyright ）を必ず入れる。将来「オフライン用に道路データをまるごと同梱する」仕様を追加する場合は、Derivative Database扱いとなり全面公開義務が生じるため要再検討。

**ソース:**
- ODbL本文: https://opendatacommons.org/licenses/odbl/1-0/
- OpenStreetMap Copyright and License: https://www.openstreetmap.org/copyright
- OSMF Produced Work Guideline: https://wiki.openstreetmap.org/wiki/Open_Data_License/Produced_Work_-_Guideline

### 3.2 Collective Database（他データとの緩い組み合わせ）とDerivative Databaseの境界

**厳密な適用条件（Derivative Databaseとみなされる＝要注意）:**
- OSMデータと第三者データ（Google由来のデータ、YOLO検出データ等）を「機能的に結合・接続」させ、単一のデータベース／グラフ構造として動作させ、それを保存・配布している
- 例: OSMの歩道ノードとGoogle独自の横断歩道座標をマッチングさせ、新しい統合道路網グラフを作成し、アプリの資産として永続化する

**Collective Database（問題になりにくい）として扱える条件:**
- OSMデータと独自データ（YOLO検出結果など）を、**論理的に分離した状態**で扱う（例: 経路探索時にのみ一時的にパラメータとして参照し、恒久的なデータ統合は行わない）

**設計ルール④:**
> 街灯密度などのカスタム重み付けは「経路探索時の一時的な計算パラメータ」として扱い、OSMの道路網データ自体を書き換えて保存・再配布しない。YOLO検出データとOSMデータを恒久的に統合したデータセットを作らない。

**ソース:** OSMF Collective Database Guideline — https://osmfoundation.org/wiki/License/Community_Guidelines/Collective_Database_Guideline_Guideline

---

## 4. 実装チェックリスト（仕様変更時に毎回参照）

- [ ] OSMの地図タイル・地図ビューをどの画面にも表示していない（2.1）
- [ ] Places/Geocoding APIの結果を独自DBに永続保存・再利用していない（30日超キャッシュ・place_id以外）（2.2）
- [ ] Places/Geocoding検索結果の利用が「ユーザーがその場で選んだ地点の、その場の処理」に限定されている（2.2）
- [ ] ルート表示画面に「経路提供元：OpenStreetMap」等の表示がある（2.3）
- [ ] GoogleコンテンツとOSMコンテンツがUI上で視覚的に区別できる（2.4）
- [ ] OSMnxの出力（座標配列）以外に、OSMの道路網データそのものを保存・再配布していない（3.1）
- [ ] YOLO検出データなどの独自データとOSMデータを恒久的に結合・保存していない（3.2）
- [ ] アプリ内に `© OpenStreetMap contributors` + ODbLリンクの帰属表示がある（3.1）
- [ ] Google Maps SDK関連の帰属表示（ロゴ・利用規約リンク等）を削除・改変していない（2.4）
- [ ] 最短経路（Directions/Routes API）は非Google地図と併用せず、Google Map上にのみ描画している（2.5）
- [ ] Directions API + Geolocation API + Maps SDKでGoogle純正ナビとほぼ同じフル機能を再現していない（2.5）
- [ ] コンテスト発表等でGoogleルーティングとの定量比較を公表する場合、再現可能な情報を併記している（2.6）

---

## 5. 参考一次資料（全項目まとめ）

- Google Maps Platform Terms of Service: https://cloud.google.com/maps-platform/terms
- Google Maps Platform EEA Service Specific Terms（第三者ルーティング併用の規定）: https://cloud.google.com/terms/maps-platform/eea/maps-service-terms
- Policies and attributions for Places API: https://developers.google.com/maps/documentation/places/web-service/policies
- Policies and attributions for Geocoding API: https://developers.google.com/maps/documentation/geocoding/policies
- ODbL 1.0 本文: https://opendatacommons.org/licenses/odbl/1-0/
- OpenStreetMap Copyright and License: https://www.openstreetmap.org/copyright
- OSMF Produced Work Guideline: https://wiki.openstreetmap.org/wiki/Open_Data_License/Produced_Work_-_Guideline
- OSMF Collective Database Guideline: https://osmfoundation.org/wiki/License/Community_Guidelines/Collective_Database_Guideline_Guideline

> 本資料は法的助言ではなく、規約・ライセンス文言の技術的解釈に基づく設計指針です。商用化・一般公開の段階では改めて専門家（弁護士）の確認を推奨します。また、Google Maps Platformの利用規約は改定される可能性があるため、定期的に一次ソースを再確認してください。
