import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';
import 'package:http/http.dart' as http;
import '../core/theme.dart';

/// Nominatim 逆ジオコーディングの結果
class PlaceDetail {
  final String name;
  final String address;
  final String? category;

  const PlaceDetail({
    required this.name,
    required this.address,
    this.category,
  });
}

/// 地図タップ時に下から出るボトムシート
///
/// タップした座標を Nominatim Reverse Geocoding で住所に変換して表示する。
Future<void> showPlaceInfoSheet({
  required BuildContext context,
  required LatLng tappedPoint,
  required VoidCallback onUploadPhoto,
}) async {
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _PlaceInfoSheet(
      tappedPoint: tappedPoint,
      onUploadPhoto: onUploadPhoto,
    ),
  );
}

class _PlaceInfoSheet extends StatefulWidget {
  final LatLng tappedPoint;
  final VoidCallback onUploadPhoto;

  const _PlaceInfoSheet({
    required this.tappedPoint,
    required this.onUploadPhoto,
  });

  @override
  State<_PlaceInfoSheet> createState() => _PlaceInfoSheetState();
}

class _PlaceInfoSheetState extends State<_PlaceInfoSheet> {
  PlaceDetail? _placeDetail;
  bool _isLoading = true;

  static const String _userAgent = 'SafeWay-App/1.0 (GPA2026)';

  @override
  void initState() {
    super.initState();
    _fetchPlaceDetail();
  }

  /// Nominatim 逆ジオコーディングで住所を取得
  Future<void> _fetchPlaceDetail() async {
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

      final response = await http.get(
        uri,
        headers: {'User-Agent': _userAgent},
      );

      if (!mounted) return;

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final address = data['address'] as Map<String, dynamic>? ?? {};

        // 名称の優先順で取得
        final name = data['name'] as String? ??
            address['road'] as String? ??
            address['neighbourhood'] as String? ??
            'この場所';

        // 住所の組み立て
        final parts = <String>[];
        if (address['state'] != null) parts.add(address['state'] as String);
        if (address['city'] != null) parts.add(address['city'] as String);
        if (address['suburb'] != null) parts.add(address['suburb'] as String);
        if (address['road'] != null) parts.add(address['road'] as String);
        if (address['house_number'] != null) {
          parts.add(address['house_number'] as String);
        }
        final addressStr =
            parts.isNotEmpty ? parts.join(' ') : '住所情報を取得できませんでした';

        final category = data['type'] as String?;

        setState(() {
          _placeDetail = PlaceDetail(
            name: name,
            address: addressStr,
            category: category,
          );
          _isLoading = false;
        });
      } else {
        setState(() {
          _placeDetail = PlaceDetail(
            name: 'この場所',
            address:
                '緯度: ${widget.tappedPoint.latitude.toStringAsFixed(5)}, '
                '経度: ${widget.tappedPoint.longitude.toStringAsFixed(5)}',
          );
          _isLoading = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _placeDetail = PlaceDetail(
            name: 'この場所',
            address:
                '緯度: ${widget.tappedPoint.latitude.toStringAsFixed(5)}, '
                '経度: ${widget.tappedPoint.longitude.toStringAsFixed(5)}',
          );
          _isLoading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
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
                  Text('場所情報を取得中...', style: TextStyle(color: Colors.grey)),
                ],
              ),
            )
          else
            _buildContent(),
        ],
      ),
    );
  }

  Widget _buildContent() {
    final detail = _placeDetail!;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        20,
        16,
        20,
        MediaQuery.of(context).viewInsets.bottom + 24,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // カテゴリバッジ
          if (detail.category != null)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
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

          // 場所名
          Text(
            detail.name,
            style: const TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.bold,
              color: Colors.black87,
            ),
          ),

          const SizedBox(height: 6),

          // 住所
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

          // 座標
          Row(
            children: [
              const Icon(Icons.my_location, size: 14, color: Colors.grey),
              const SizedBox(width: 4),
              Text(
                '${widget.tappedPoint.latitude.toStringAsFixed(5)}, '
                '${widget.tappedPoint.longitude.toStringAsFixed(5)}',
                style: TextStyle(
                  fontSize: 12,
                  color: Colors.grey.shade500,
                  fontFamily: 'monospace',
                ),
              ),
            ],
          ),

          const SizedBox(height: 20),

          const Divider(height: 1),
          const SizedBox(height: 16),

          // 「この場所の写真を投稿する」ボタン
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: () {
                Navigator.pop(context);
                widget.onUploadPhoto();
              },
              icon: const Icon(Icons.camera_alt, size: 18),
              label: const Text(
                'この場所の写真を投稿する',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.emeraldGreen,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                elevation: 2,
              ),
            ),
          ),

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
    );
  }

  String _formatCategory(String category) {
    const categories = {
      'road': '道路',
      'residential': '住宅地',
      'park': '公園',
      'school': '学校',
      'hospital': '病院',
      'shop': '店舗',
      'restaurant': '飲食店',
      'convenience': 'コンビニ',
      'station': '駅',
      'university': '大学',
      'administrative': '行政区域',
      'water': '水域',
    };
    return categories[category] ?? category;
  }
}
