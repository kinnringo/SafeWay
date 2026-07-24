import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:http/http.dart' as http;
import '../core/theme.dart';
import '../services/api_service.dart';
import '../providers/map_theme_provider.dart';
import 'package:pointer_interceptor/pointer_interceptor.dart';
import 'package:url_launcher/url_launcher.dart';

/// 場所情報のデータモデル
///
/// Google Places Details API / Nearby Search / Nominatim 逆ジオコーディングの
/// 結果を統一的に保持する。
/// ⚠️ ライセンス設計指針 §2.2 準拠: 各フィールドは State 上のメモリにのみ保持し、
/// SafeWay 独自の DB への永続保存・再利用は行わない。
class PlaceDetail {
  final String name;
  final String address;
  final String? category;
  final double? rating;
  final int? userRatingsTotal;
  final bool? isOpenNow;
  final List<String> photoReferences;
  final bool fromPlacesApi;

  // ── 詳細情報フィールド（Place Details API から一時取得） ──
  /// 電話番号 (formatted_phone_number)
  final String? phoneNumber;

  /// 公式ウェブサイト URL (website)
  final String? website;

  /// 曜日ごとの営業時間テキスト (opening_hours.weekday_text)
  final List<String>? weekdayText;

  const PlaceDetail({
    required this.name,
    required this.address,
    this.category,
    this.rating,
    this.userRatingsTotal,
    this.isOpenNow,
    this.photoReferences = const [],
    this.fromPlacesApi = false,
    this.phoneNumber,
    this.website,
    this.weekdayText,
  });
}

/// 地図タップ・長押し・POI タップ時に下から出るボトムシート
///
/// 情報取得の優先順位:
/// 1. [placeId] が渡された場合 → Place Details API からピンポイント詳細取得
/// 2. [placeId] なし または Details API 失敗 → Nearby Search でフォールバック
/// 3. Nearby Search 失敗 → Nominatim 逆ジオコーディングにフォールバック
///
/// [onRouteRequested] が指定された場合、場所名右隣に「ルート」ボタンを表示する。
Future<void> showPlaceInfoSheet({
  required BuildContext context,
  required LatLng tappedPoint,
  String? placeId,
  void Function(LatLng destination, String destinationName)? onRouteRequested,
}) async {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => PointerInterceptor(
      child: _PlaceInfoSheet(
        tappedPoint: tappedPoint,
        placeId: placeId,
        onRouteRequested: onRouteRequested,
      ),
    ),
  );
}

class _PlaceInfoSheet extends ConsumerStatefulWidget {
  final LatLng tappedPoint;
  final String? placeId;
  final void Function(LatLng destination, String destinationName)? onRouteRequested;

  const _PlaceInfoSheet({
    required this.tappedPoint,
    this.placeId,
    this.onRouteRequested,
  });

  @override
  ConsumerState<_PlaceInfoSheet> createState() => _PlaceInfoSheetState();
}

class _PlaceInfoSheetState extends ConsumerState<_PlaceInfoSheet> {
  PlaceDetail? _placeDetail;
  bool _isLoading = true;

  static const String _nominatimUserAgent = 'SafeWay-App/1.0 (GPA2026)';

  @override
  void initState() {
    super.initState();
    _fetchPlaceDetail();
  }

  Future<void> _fetchPlaceDetail() async {
    // 1. placeId がある場合は Place Details API から優先取得
    if (widget.placeId != null) {
      final detailsResult =
          await _fetchFromPlaceDetailsApi(widget.placeId!);
      if (detailsResult != null) {
        if (mounted) {
          setState(() {
            _placeDetail = detailsResult;
            _isLoading = false;
          });
        }
        return;
      }
    }

    // 2. Nearby Search で周辺施設を検索
    final placesResult = await _fetchFromPlacesApi();
    if (placesResult != null) {
      if (mounted) {
        setState(() {
          _placeDetail = placesResult;
          _isLoading = false;
        });
      }
      return;
    }

    // 3. Nominatim 逆ジオコーディングにフォールバック
    final nominatimResult = await _fetchFromNominatim();
    if (mounted) {
      setState(() {
        _placeDetail = nominatimResult;
        _isLoading = false;
      });
    }
  }

  /// バックエンドプロキシ経由で詳細情報を取得
  ///
  /// 電話番号・ウェブサイト・営業時間の曜日テキストを含む詳細を返す。
  Future<PlaceDetail?> _fetchFromPlaceDetailsApi(String placeId) async {
    try {
      final result = await ApiService().getPlaceDetails(placeId);
      if (result == null) return null;

      final photos = (result['photos'] as List<dynamic>?)
              ?.map((p) => p['photo_reference'] as String)
              .take(5)
              .toList() ??
          [];

      final openingHours =
          result['opening_hours'] as Map<String, dynamic>?;
      final isOpenNow = openingHours?['open_now'] as bool?;
      final weekdayText =
          (openingHours?['weekday_text'] as List<dynamic>?)
              ?.cast<String>()
              .toList();

      final types =
          (result['types'] as List<dynamic>?)?.cast<String>() ?? [];
      final category = types.isNotEmpty ? types.first : null;

      return PlaceDetail(
        name: result['name'] as String? ?? 'この場所',
        address: result['formatted_address'] as String? ??
            result['vicinity'] as String? ??
            '',
        category: category,
        rating: (result['rating'] as num?)?.toDouble(),
        userRatingsTotal: result['user_ratings_total'] as int?,
        isOpenNow: isOpenNow,
        photoReferences: photos,
        fromPlacesApi: true,
        phoneNumber: result['formatted_phone_number'] as String?,
        website: result['website'] as String?,
        weekdayText: weekdayText,
      );
    } catch (e) {
      debugPrint('Place Details API error: $e');
      return null;
    }
  }

  /// バックエンドプロキシ経由で周辺施設を取得 (フォールバック)
  Future<PlaceDetail?> _fetchFromPlacesApi() async {
    try {
      final lat = widget.tappedPoint.latitude;
      final lng = widget.tappedPoint.longitude;

      final nearbyResult = await ApiService().getNearbyPoi(
        lat: lat,
        lng: lng,
        radius: 50.0,
      );
      
      if (nearbyResult == null) return null;

      final placeId = nearbyResult['placeId'] as String?;
      if (placeId != null) {
        // Nearby Searchで見つかった一番近い場所の placeId を使って詳細を取得
        return _fetchFromPlaceDetailsApi(placeId);
      }
      return null;
    } catch (e) {
      debugPrint('Nearby API error: $e');
      return null;
    }
  }

  /// Nominatim 逆ジオコーディングで住所情報を取得（フォールバック）
  Future<PlaceDetail?> _fetchFromNominatim() async {
    try {
      final uri = Uri.https(
        'nominatim.openstreetmap.org',
        '/reverse',
        {
          'lat': widget.tappedPoint.latitude.toString(),
          'lon': widget.tappedPoint.longitude.toString(),
          'format': 'json',
          'accept-language': 'ja',
        },
      );

      final response = await http
          .get(uri, headers: {'User-Agent': _nominatimUserAgent})
          .timeout(const Duration(seconds: 6));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final address = data['address'] as Map<String, dynamic>? ?? {};

        final name = data['name'] as String? ??
            address['road'] as String? ??
            address['neighbourhood'] as String? ??
            'この場所';

        final parts = <String>[];
        if (address['state'] != null) {
          parts.add(address['state'] as String);
        }
        if (address['city'] != null) {
          parts.add(address['city'] as String);
        }
        if (address['suburb'] != null) {
          parts.add(address['suburb'] as String);
        }
        if (address['road'] != null) {
          parts.add(address['road'] as String);
        }
        if (address['house_number'] != null) {
          parts.add(address['house_number'] as String);
        }

        return PlaceDetail(
          name: name,
          address: parts.isNotEmpty ? parts.join(' ') : '住所情報なし',
          category: data['type'] as String?,
        );
      }
    } catch (_) {}

    // 最終フォールバック：座標のみ表示
    return PlaceDetail(
      name: 'この場所',
      address: '緯度: ${widget.tappedPoint.latitude.toStringAsFixed(5)}, '
          '経度: ${widget.tappedPoint.longitude.toStringAsFixed(5)}',
    );
  }

  /// バックエンドプロキシ経由で写真 URL を構築
  String _buildPhotoUrl(String photoRef) {
    return '${ApiService.baseUrl}/places/photo?photo_reference=$photoRef';
  }

  @override
  Widget build(BuildContext context) {
    final isDark = ref.watch(mapThemeProvider);
    final bgColor = isDark ? AppColors.darkSurface : Colors.white;
    final handleColor = isDark ? AppColors.darkBorder : Colors.grey.shade300;
    
    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.72,
      ),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // ハンドルバー
          Container(
            margin: const EdgeInsets.only(top: 12),
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: handleColor,
              borderRadius: BorderRadius.circular(2),
            ),
          ),

          if (_isLoading)
            const Padding(
              padding: EdgeInsets.all(32),
              child: Column(
                children: [
                  CircularProgressIndicator(),
                  SizedBox(height: 12),
                  Text(
                    '場所情報を取得中...',
                    style: TextStyle(color: Colors.grey),
                  ),
                ],
              ),
            )
          else
            Flexible(
              child: SingleChildScrollView(
                child: _buildContent(),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildContent() {
    final detail = _placeDetail!;
    final isDark = ref.watch(mapThemeProvider);
    final textColor = isDark ? AppColors.darkTextPrimary : Colors.black87;
    final subTextColor = isDark ? AppColors.darkTextSecondary : Colors.grey.shade500;
    final categoryBgColor = isDark ? AppColors.darkCard : AppColors.primaryNavy.withValues(alpha: 0.1);
    final categoryTextColor = isDark ? AppColors.blueAccentLight : AppColors.primaryNavy;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 写真カルーセル（取得できた場合のみ）
        if (detail.photoReferences.isNotEmpty) _buildPhotoCarousel(detail),

        Padding(
          padding: EdgeInsets.fromLTRB(
            20,
            16,
            20,
            MediaQuery.of(context).viewInsets.bottom + 24,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // カテゴリバッジ
              if (detail.category != null) ...[
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 10, vertical: 3),
                  decoration: BoxDecoration(
                    color: categoryBgColor,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    _formatCategory(detail.category!),
                    style: TextStyle(
                      fontSize: 11,
                      color: categoryTextColor,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const SizedBox(height: 8),
              ],

              // ── 場所名 + ルートボタン ──
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(
                    child: Text(
                      detail.name,
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                        color: textColor,
                      ),
                    ),
                  ),
                  if (widget.onRouteRequested != null) ...[
                    const SizedBox(width: 8),
                    FilledButton.icon(
                      onPressed: () {
                        Navigator.pop(context);
                        widget.onRouteRequested!(widget.tappedPoint, detail.name);
                      },
                      style: FilledButton.styleFrom(
                        backgroundColor: AppColors.primaryNavy,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(20),
                        ),
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      icon: const Icon(
                        Icons.directions,
                        size: 16,
                        color: Colors.white,
                      ),
                      label: const Text(
                        'ルート',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ],
                ],
              ),

              const SizedBox(height: 8),

              // 評価 ＋ 営業中バッジ
              if (detail.rating != null || detail.isOpenNow != null) ...[
                Row(
                  children: [
                    if (detail.rating != null) ...[
                      Icon(
                        Icons.star_rounded,
                        size: 17,
                        color: Colors.amber.shade600,
                      ),
                      const SizedBox(width: 3),
                      Text(
                        detail.rating!.toStringAsFixed(1),
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          color: textColor,
                        ),
                      ),
                      if (detail.userRatingsTotal != null) ...[
                        const SizedBox(width: 2),
                        Text(
                          '(${_formatCount(detail.userRatingsTotal!)})',
                          style: TextStyle(
                            fontSize: 12,
                            color: subTextColor,
                          ),
                        ),
                      ],
                    ],
                    if (detail.rating != null && detail.isOpenNow != null)
                      const SizedBox(width: 12),
                    if (detail.isOpenNow != null) ...[
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: detail.isOpenNow!
                              ? Colors.green.shade50
                              : Colors.red.shade50,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: detail.isOpenNow!
                                ? Colors.green.shade200
                                : Colors.red.shade200,
                          ),
                        ),
                        child: Text(
                          detail.isOpenNow! ? '営業中' : '営業時間外',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: detail.isOpenNow!
                                ? Colors.green.shade700
                                : Colors.red.shade700,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 10),
              ],

              // 住所
              if (detail.address.isNotEmpty) ...[
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(
                      Icons.location_on_outlined,
                      size: 16,
                      color: Colors.grey,
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        detail.address,
                        style: TextStyle(
                          fontSize: 13,
                          color: subTextColor,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
              ],

              // 座標（小さめ）
              Row(
                children: [
                  const Icon(Icons.my_location,
                      size: 13, color: Colors.grey),
                  const SizedBox(width: 4),
                  Text(
                    '${widget.tappedPoint.latitude.toStringAsFixed(5)}, '
                    '${widget.tappedPoint.longitude.toStringAsFixed(5)}',
                    style: TextStyle(
                      fontSize: 11,
                      color: subTextColor,
                      fontFamily: 'monospace',
                    ),
                  ),
                ],
              ),

              // ── 詳細情報セクション（電話・ウェブ・営業時間） ──
              _buildAdditionalInfoSection(detail),

              const SizedBox(height: 20),
              const Divider(height: 1),
              const SizedBox(height: 8),

              // 閉じるボタン
              SizedBox(
                width: double.infinity,
                child: TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: Text(
                    '閉じる',
                    style: TextStyle(color: subTextColor),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// 詳細情報セクション：電話番号・ウェブサイト・営業時間アコーディオン
  Widget _buildAdditionalInfoSection(PlaceDetail detail) {
    final hasAdditional = detail.phoneNumber != null ||
        detail.website != null ||
        (detail.weekdayText != null && detail.weekdayText!.isNotEmpty);

    if (!hasAdditional) return const SizedBox.shrink();

    final isDark = ref.watch(mapThemeProvider);
    final textColor = isDark ? AppColors.darkTextPrimary : Colors.black87;
    final subTextColor = isDark ? AppColors.darkTextSecondary : Colors.grey.shade700;
    final dividerColor = isDark ? AppColors.darkBorder : null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Divider(height: 1, color: dividerColor),
        ),

        // 電話番号
        if (detail.phoneNumber != null) ...[
          Row(
            children: [
              const Icon(Icons.phone_outlined,
                  size: 16, color: Colors.grey),
              const SizedBox(width: 8),
              Text(
                detail.phoneNumber!,
                style: TextStyle(
                    fontSize: 13, color: textColor),
              ),
            ],
          ),
          const SizedBox(height: 10),
        ],

        // 公式ウェブサイト
        if (detail.website != null) ...[
          InkWell(
            onTap: () async {
              final Uri url = Uri.parse(detail.website!);
              if (await canLaunchUrl(url)) {
                await launchUrl(url, mode: LaunchMode.externalApplication);
              }
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4.0),
              child: Row(
                children: [
                  const Icon(Icons.language_outlined,
                      size: 16, color: Colors.grey),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      detail.website!,
                      style: TextStyle(
                        fontSize: 13,
                        color: isDark ? AppColors.blueAccentLight : Colors.blue,
                        decoration: TextDecoration.underline,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 4),
        ],

        // 営業時間（アコーディオン形式）
        if (detail.weekdayText != null &&
            detail.weekdayText!.isNotEmpty) ...[
          Theme(
            // ExpansionTile のデフォルト仕切り線を非表示にして視覚ノイズを排除
            data: Theme.of(context)
                .copyWith(dividerColor: Colors.transparent),
            child: ExpansionTile(
              leading: const Icon(Icons.access_time_outlined,
                  size: 16, color: Colors.grey),
              title: Text(
                '営業時間を確認',
                style: TextStyle(fontSize: 13, color: textColor),
              ),
              tilePadding: EdgeInsets.zero,
              childrenPadding:
                  const EdgeInsets.only(left: 24, bottom: 8),
              expandedAlignment: Alignment.topLeft,
              children: detail.weekdayText!.map((text) {
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Text(
                    text,
                    style: TextStyle(
                        fontSize: 12, color: subTextColor),
                  ),
                );
              }).toList(),
            ),
          ),
        ],
      ],
    );
  }

  /// 写真の横スクロールカルーセル
  Widget _buildPhotoCarousel(PlaceDetail detail) {
    return SizedBox(
      height: 180,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
        itemCount: detail.photoReferences.length,
        itemBuilder: (context, index) {
          final url = _buildPhotoUrl(detail.photoReferences[index]);
          return Container(
            margin: const EdgeInsets.only(right: 8),
            width: 240,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              color: Colors.grey.shade200,
            ),
            clipBehavior: Clip.hardEdge,
            child: Image.network(
              url,
              fit: BoxFit.cover,
              loadingBuilder: (context, child, loadingProgress) {
                if (loadingProgress == null) return child;
                return Center(
                  child: CircularProgressIndicator(
                    value: loadingProgress.expectedTotalBytes != null
                        ? loadingProgress.cumulativeBytesLoaded /
                            loadingProgress.expectedTotalBytes!
                        : null,
                    strokeWidth: 2,
                    color: AppColors.primaryNavy,
                  ),
                );
              },
              errorBuilder: (context, error, stack) => Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.image_not_supported_outlined,
                      color: Colors.grey.shade400,
                      size: 32,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '画像を読み込めません',
                      style: TextStyle(
                        fontSize: 10,
                        color: Colors.grey.shade400,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  /// レビュー数を見やすく変換（例: 1234 → 1.2K）
  String _formatCount(int count) {
    if (count >= 1000) {
      return '${(count / 1000).toStringAsFixed(1)}K';
    }
    return count.toString();
  }

  /// カテゴリコードを日本語に変換
  String _formatCategory(String category) {
    const categories = {
      'restaurant': '飲食店',
      'food': '飲食店',
      'cafe': 'カフェ',
      'bar': 'バー',
      'bakery': 'パン屋',
      'meal_takeaway': 'テイクアウト',
      'meal_delivery': 'デリバリー',
      'convenience_store': 'コンビニ',
      'supermarket': 'スーパー',
      'grocery_or_supermarket': 'スーパー',
      'shopping_mall': 'ショッピングモール',
      'department_store': 'デパート',
      'store': '店舗',
      'shop': '店舗',
      'clothing_store': 'アパレル',
      'electronics_store': '家電量販店',
      'book_store': '書店',
      'gas_station': 'ガソリンスタンド',
      'bank': '銀行',
      'atm': 'ATM',
      'hospital': '病院',
      'doctor': '病院・クリニック',
      'dentist': '歯科',
      'pharmacy': '薬局',
      'school': '学校',
      'university': '大学',
      'park': '公園',
      'museum': '博物館・美術館',
      'library': '図書館',
      'hotel': 'ホテル',
      'lodging': '宿泊施設',
      'transit_station': '交通機関',
      'subway_station': '地下鉄駅',
      'train_station': '電車駅',
      'bus_station': 'バス停',
      'airport': '空港',
      'parking': '駐車場',
      'gym': 'ジム',
      'hair_care': '美容院',
      'beauty_salon': 'サロン',
      'spa': 'スパ',
      'church': '教会',
      'temple': '寺院',
      'shrine': '神社',
      'point_of_interest': '観光スポット',
      'establishment': '施設',
      'road': '道路',
      'residential': '住宅地',
      'administrative': '行政区域',
      'water': '水域',
    };
    return categories[category] ?? category;
  }
}
