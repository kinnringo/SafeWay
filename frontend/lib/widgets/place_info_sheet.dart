import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:http/http.dart' as http;
import '../core/theme.dart';
import '../core/api_config.dart';
import 'package:pointer_interceptor/pointer_interceptor.dart';

/// 場所情報のデータモデル
class PlaceDetail {
  final String name;
  final String address;
  final String? category;
  final double? rating;
  final int? userRatingsTotal;
  final bool? isOpenNow;
  final List<String> photoReferences; // Google Places API の photo_reference
  final bool fromPlacesApi;

  const PlaceDetail({
    required this.name,
    required this.address,
    this.category,
    this.rating,
    this.userRatingsTotal,
    this.isOpenNow,
    this.photoReferences = const [],
    this.fromPlacesApi = false,
  });
}

/// 地図タップ時に下から出るボトムシート
///
/// 1. Google Places API Nearby Search で周辺施設を検索
/// 2. 施設が見つかれば：名称・評価・営業状況・写真を表示
/// 3. 施設がなければ：Nominatim 逆ジオコーディングで住所のみ表示
Future<void> showPlaceInfoSheet({
  required BuildContext context,
  required LatLng tappedPoint,
}) async {
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => PointerInterceptor(
      child: _PlaceInfoSheet(tappedPoint: tappedPoint),
    ),
  );
}

class _PlaceInfoSheet extends StatefulWidget {
  final LatLng tappedPoint;

  const _PlaceInfoSheet({required this.tappedPoint});

  @override
  State<_PlaceInfoSheet> createState() => _PlaceInfoSheetState();
}

class _PlaceInfoSheetState extends State<_PlaceInfoSheet> {
  PlaceDetail? _placeDetail;
  bool _isLoading = true;

  static const String _nominatimUserAgent = 'SafeWay-App/1.0 (GPA2026)';

  @override
  void initState() {
    super.initState();
    _fetchPlaceDetail();
  }

  Future<void> _fetchPlaceDetail() async {
    // 1. Google Places API で周辺施設を検索
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

    // 2. Places で見つからなかった場合は Nominatim にフォールバック
    final nominatimResult = await _fetchFromNominatim();
    if (mounted) {
      setState(() {
        _placeDetail = nominatimResult;
        _isLoading = false;
      });
    }
  }

  /// Google Places API Nearby Search で施設情報を取得
  Future<PlaceDetail?> _fetchFromPlacesApi() async {
    // APIキーが未設定の場合はスキップ
    const key = ApiConfig.googleMapsApiKey;
    if (key == 'YOUR_GOOGLE_MAPS_API_KEY_HERE' || key.isEmpty) {
      return null;
    }

    try {
      final lat = widget.tappedPoint.latitude;
      final lng = widget.tappedPoint.longitude;

      final uri = Uri.https(
        'maps.googleapis.com',
        '/maps/api/place/nearbysearch/json',
        {
          'location': '$lat,$lng',
          'radius': '50', // タップ地点から50m以内の施設を検索
          'language': 'ja',
          'key': key,
        },
      );

      final response =
          await http.get(uri).timeout(const Duration(seconds: 6));

      if (response.statusCode != 200) return null;

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final results = data['results'] as List<dynamic>?;

      if (results == null || results.isEmpty) return null;

      final place = results.first as Map<String, dynamic>;

      // 写真のphoto_referenceを最大5枚取得
      final photos = (place['photos'] as List<dynamic>?)
              ?.map((p) => p['photo_reference'] as String)
              .take(5)
              .toList() ??
          [];

      // 営業状況
      final openingHours =
          place['opening_hours'] as Map<String, dynamic>?;
      final isOpenNow = openingHours?['open_now'] as bool?;

      // カテゴリ（typesの先頭を使用）
      final types =
          (place['types'] as List<dynamic>?)?.cast<String>() ?? [];
      final category = types.isNotEmpty ? types.first : null;

      return PlaceDetail(
        name: place['name'] as String? ?? 'この場所',
        address: place['vicinity'] as String? ?? '',
        category: category,
        rating: (place['rating'] as num?)?.toDouble(),
        userRatingsTotal: place['user_ratings_total'] as int?,
        isOpenNow: isOpenNow,
        photoReferences: photos,
        fromPlacesApi: true,
      );
    } catch (_) {
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
        if (address['state'] != null) parts.add(address['state'] as String);
        if (address['city'] != null) parts.add(address['city'] as String);
        if (address['suburb'] != null) parts.add(address['suburb'] as String);
        if (address['road'] != null) parts.add(address['road'] as String);
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
      address:
          '緯度: ${widget.tappedPoint.latitude.toStringAsFixed(5)}, '
          '経度: ${widget.tappedPoint.longitude.toStringAsFixed(5)}',
    );
  }

  /// Google Places API の写真URL を構築
  String _buildPhotoUrl(String photoRef) {
    return 'https://maps.googleapis.com/maps/api/place/photo'
        '?maxwidth=400'
        '&photo_reference=$photoRef'
        '&key=${ApiConfig.googleMapsApiKey}';
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.72,
      ),
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
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
              color: Colors.grey.shade300,
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

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 写真カルーセル（Google Places API で取得できた場合のみ表示）
        if (detail.photoReferences.isNotEmpty) _buildPhotoCarousel(detail),

        Padding(
          padding: EdgeInsets.fromLTRB(
            20,
            detail.photoReferences.isEmpty ? 16 : 16,
            20,
            MediaQuery.of(context).viewInsets.bottom + 24,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // カテゴリバッジ
              if (detail.category != null) ...[
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                  decoration: BoxDecoration(
                    color: AppColors.primaryNavy.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    _formatCategory(detail.category!),
                    style: const TextStyle(
                      fontSize: 11,
                      color: AppColors.primaryNavy,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const SizedBox(height: 8),
              ],

              // 場所名
              Text(
                detail.name,
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  color: Colors.black87,
                ),
              ),

              const SizedBox(height: 8),

              // 評価 ＋ 営業状況
              if (detail.rating != null || detail.isOpenNow != null) ...[
                Row(
                  children: [
                    // 評価（星 + 数値 + レビュー数）
                    if (detail.rating != null) ...[
                      Icon(
                        Icons.star_rounded,
                        size: 17,
                        color: Colors.amber.shade600,
                      ),
                      const SizedBox(width: 3),
                      Text(
                        detail.rating!.toStringAsFixed(1),
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          color: Colors.black87,
                        ),
                      ),
                      if (detail.userRatingsTotal != null) ...[
                        const SizedBox(width: 2),
                        Text(
                          '(${_formatCount(detail.userRatingsTotal!)})',
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.grey.shade500,
                          ),
                        ),
                      ],
                    ],

                    if (detail.rating != null && detail.isOpenNow != null)
                      const SizedBox(width: 12),

                    // 営業中 / 営業時間外バッジ
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
                          color: Colors.grey.shade600,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
              ],

              // 座標（小さめに表示）
              Row(
                children: [
                  const Icon(Icons.my_location, size: 13, color: Colors.grey),
                  const SizedBox(width: 4),
                  Text(
                    '${widget.tappedPoint.latitude.toStringAsFixed(5)}, '
                    '${widget.tappedPoint.longitude.toStringAsFixed(5)}',
                    style: TextStyle(
                      fontSize: 11,
                      color: Colors.grey.shade400,
                      fontFamily: 'monospace',
                    ),
                  ),
                ],
              ),

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
                    style: TextStyle(color: Colors.grey.shade600),
                  ),
                ),
              ),
            ],
          ),
        ),
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
