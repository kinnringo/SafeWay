import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:http/http.dart' as http;
import '../core/theme.dart';

/// 場所・住所の検索結果
class PlaceResult {
  final String displayName;
  final String shortName;
  final double lat;
  final double lng;

  const PlaceResult({
    required this.displayName,
    required this.shortName,
    required this.lat,
    required this.lng,
  });

  factory PlaceResult.fromJson(Map<String, dynamic> json) {
    final displayName = json['display_name'] as String? ?? '';
    // 表示名の最初の部分（施設名）を短縮名として使用
    final parts = displayName.split(', ');
    return PlaceResult(
      displayName: displayName,
      shortName: parts.isNotEmpty ? parts.first : displayName,
      lat: double.tryParse(json['lat'] as String? ?? '0') ?? 0.0,
      lng: double.tryParse(json['lon'] as String? ?? '0') ?? 0.0,
    );
  }
}

/// マップ上部に表示する検索バーWidget
///
/// OpenStreetMap Nominatim API（無料）を使って場所・住所を検索し、
/// 選択した場所に地図をズームさせる。
class MapSearchBar extends StatefulWidget {
  final MapController mapController;

  const MapSearchBar({super.key, required this.mapController});

  @override
  State<MapSearchBar> createState() => _MapSearchBarState();
}

class _MapSearchBarState extends State<MapSearchBar>
    with SingleTickerProviderStateMixin {
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _focusNode = FocusNode();
  late final AnimationController _animController;
  late final Animation<double> _fadeAnim;

  List<PlaceResult> _results = [];
  bool _isSearching = false;
  bool _isExpanded = false;
  Timer? _debounceTimer;

  // Nominatim API の利用規約上、User-Agent は必須
  static const String _userAgent = 'SafeWay-App/1.0 (GPA2026)';

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 250),
    );
    _fadeAnim = CurvedAnimation(parent: _animController, curve: Curves.easeOut);

    _focusNode.addListener(() {
      setState(() {
        _isExpanded = _focusNode.hasFocus;
      });
      if (_focusNode.hasFocus) {
        _animController.forward();
      } else {
        _animController.reverse();
        _results = [];
      }
    });
  }

  @override
  void dispose() {
    _debounceTimer?.cancel();
    _searchController.dispose();
    _focusNode.dispose();
    _animController.dispose();
    super.dispose();
  }

  /// Nominatim API で検索（300ms のデバウンス付き）
  Future<void> _search(String query) async {
    _debounceTimer?.cancel();
    if (query.trim().isEmpty) {
      setState(() => _results = []);
      return;
    }

    _debounceTimer = Timer(const Duration(milliseconds: 300), () async {
      if (!mounted) return;
      setState(() => _isSearching = true);

      try {
        final uri = Uri.https('nominatim.openstreetmap.org', '/search', {
          'q': query,
          'format': 'json',
          'limit': '5',
          'accept-language': 'ja',
          'countrycodes': 'jp', // 日本に絞る
        });

        final response = await http.get(
          uri,
          headers: {'User-Agent': _userAgent},
        );

        if (!mounted) return;

        if (response.statusCode == 200) {
          final List<dynamic> data = jsonDecode(response.body);
          setState(() {
            _results =
                data.map((e) => PlaceResult.fromJson(e as Map<String, dynamic>)).toList();
            _isSearching = false;
          });
        } else {
          setState(() => _isSearching = false);
        }
      } catch (_) {
        if (mounted) setState(() => _isSearching = false);
      }
    });
  }

  /// 検索結果の場所を選択して地図を移動
  void _selectPlace(PlaceResult place) {
    widget.mapController.move(LatLng(place.lat, place.lng), 16.0);
    _searchController.text = place.shortName;
    _focusNode.unfocus();
    setState(() => _results = []);
  }

  @override
  Widget build(BuildContext context) {
    return Positioned(
      top: 12,
      left: 12,
      right: 12,
      child: SafeArea(
        child: Column(
          children: [
            // 検索バー本体
            Container(
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(14),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.15),
                    blurRadius: 12,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: TextField(
                controller: _searchController,
                focusNode: _focusNode,
                onChanged: _search,
                style: const TextStyle(fontSize: 14, color: Colors.black87),
                decoration: InputDecoration(
                  hintText: '場所・住所を検索...',
                  hintStyle: TextStyle(
                    fontSize: 14,
                    color: Colors.grey.shade500,
                  ),
                  prefixIcon: _isSearching
                      ? const Padding(
                          padding: EdgeInsets.all(12.0),
                          child: SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        )
                      : const Icon(Icons.search, color: AppColors.primaryNavy),
                  suffixIcon: _searchController.text.isNotEmpty
                      ? IconButton(
                          icon: const Icon(Icons.clear, color: Colors.grey),
                          onPressed: () {
                            _searchController.clear();
                            setState(() => _results = []);
                          },
                        )
                      : null,
                  border: InputBorder.none,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 14,
                  ),
                ),
              ),
            ),

            // 検索結果リスト
            if (_results.isNotEmpty)
              FadeTransition(
                opacity: _fadeAnim,
                child: Container(
                  margin: const EdgeInsets.only(top: 6),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(14),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.12),
                        blurRadius: 12,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(14),
                    child: ListView.separated(
                      padding: EdgeInsets.zero,
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      itemCount: _results.length,
                      separatorBuilder: (_, __) => Divider(
                        height: 1,
                        color: Colors.grey.shade200,
                      ),
                      itemBuilder: (context, index) {
                        final place = _results[index];
                        return _SearchResultTile(
                          place: place,
                          onTap: () => _selectPlace(place),
                        );
                      },
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _SearchResultTile extends StatelessWidget {
  final PlaceResult place;
  final VoidCallback onTap;

  const _SearchResultTile({required this.place, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            const Icon(
              Icons.location_on_outlined,
              color: AppColors.primaryNavy,
              size: 20,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    place.shortName,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: Colors.black87,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    place.displayName,
                    style: TextStyle(
                      fontSize: 11,
                      color: Colors.grey.shade600,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            const Icon(
              Icons.chevron_right,
              color: Colors.grey,
              size: 18,
            ),
          ],
        ),
      ),
    );
  }
}
