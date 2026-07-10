import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:http/http.dart' as http;
import '../core/theme.dart';
import 'package:pointer_interceptor/pointer_interceptor.dart';

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
/// 検索サジェストは Flutter Overlay に表示することで、
/// GoogleMap（PlatformView）のタッチ横取り問題を回避する。
class MapSearchBar extends StatefulWidget {
  final GoogleMapController? mapController;

  /// サジェストリストの表示／非表示が切り替わった時に呼ばれるコールバック
  /// true = 表示中、false = 非表示
  final ValueChanged<bool>? onSuggestionsVisibilityChanged;

  const MapSearchBar({
    super.key,
    required this.mapController,
    this.onSuggestionsVisibilityChanged,
  });

  @override
  State<MapSearchBar> createState() => _MapSearchBarState();
}

class _MapSearchBarState extends State<MapSearchBar> {
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _focusNode = FocusNode();

  /// CompositedTransformTarget/Follower で検索バーの位置に
  /// Overlay を追従させるための LayerLink
  final LayerLink _layerLink = LayerLink();

  OverlayEntry? _overlayEntry;
  bool _isSearching = false;
  Timer? _debounceTimer;

  // Nominatim API の利用規約上、User-Agent は必須
  static const String _userAgent = 'SafeWay-App/1.0 (GPA2026)';

  @override
  void initState() {
    super.initState();
    _focusNode.addListener(() {
      if (!_focusNode.hasFocus) {
        // フォーカスが外れたらサジェストを閉じる
        _hideOverlay();
      }
    });
  }

  @override
  void dispose() {
    _hideOverlay();
    _debounceTimer?.cancel();
    _searchController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  // ─────────────────────────────────────────
  // Overlay 操作
  // ─────────────────────────────────────────

  /// サジェストリストを Flutter Overlay に表示する
  ///
  /// Overlay はアプリのウィジェットツリー最上位に挿入されるため、
  /// GoogleMap（PlatformView）のタッチ横取りの影響を受けない。
  void _showOverlay(List<PlaceResult> results) {
    _hideOverlay();
    if (results.isEmpty || !mounted) return;

    _overlayEntry = OverlayEntry(
      builder: (ctx) {
        final screenWidth = MediaQuery.sizeOf(ctx).width;
        return Positioned(
          // CompositedTransformFollower の位置決めに必要な起点
          top: 0,
          left: 0,
          child: CompositedTransformFollower(
            link: _layerLink,
            showWhenUnlinked: false,
            // 検索バーの下端を基準に追従
            targetAnchor: Alignment.bottomLeft,
            followerAnchor: Alignment.topLeft,
            offset: const Offset(0, 6),
            child: SizedBox(
              // 検索バーと同じ幅（left:12, right:12 で 24px 引く）
              width: screenWidth - 24,
              child: PointerInterceptor(
                child: Material(
                  elevation: 8,
                  borderRadius: BorderRadius.circular(14),
                  clipBehavior: Clip.hardEdge,
                  child: ListView.separated(
                    padding: EdgeInsets.zero,
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    itemCount: results.length,
                    separatorBuilder: (_, __) => Divider(
                      height: 1,
                      color: Colors.grey.shade200,
                    ),
                    itemBuilder: (context, index) {
                      final place = results[index];
                      return _SearchResultTile(
                        place: place,
                        onTap: () => _selectPlace(place),
                      );
                    },
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );

    Overlay.of(context).insert(_overlayEntry!);
    widget.onSuggestionsVisibilityChanged?.call(true);
  }

  /// サジェストリストを閉じる
  void _hideOverlay() {
    _overlayEntry?.remove();
    _overlayEntry = null;
    widget.onSuggestionsVisibilityChanged?.call(false);
  }

  // ─────────────────────────────────────────
  // 検索ロジック
  // ─────────────────────────────────────────

  /// Nominatim API で検索（300ms のデバウンス付き）
  Future<void> _search(String query) async {
    _debounceTimer?.cancel();
    if (query.trim().isEmpty) {
      _hideOverlay();
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
          final newResults = data
              .map((e) => PlaceResult.fromJson(e as Map<String, dynamic>))
              .toList();

          setState(() => _isSearching = false);

          // 結果を Overlay に表示
          _showOverlay(newResults);
        } else {
          setState(() => _isSearching = false);
        }
      } catch (_) {
        if (mounted) setState(() => _isSearching = false);
      }
    });
  }

  /// 検索結果の場所を選択して Google Maps カメラを移動
  void _selectPlace(PlaceResult place) {
    widget.mapController?.animateCamera(
      CameraUpdate.newLatLngZoom(LatLng(place.lat, place.lng), 16.0),
    );
    _searchController.text = place.shortName;
    _focusNode.unfocus();
    _hideOverlay();
  }

  // ─────────────────────────────────────────
  // UI
  // ─────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Positioned(
      top: 12,
      left: 12,
      right: 12,
      child: SafeArea(
        child: PointerInterceptor(
          child: CompositedTransformTarget(
            link: _layerLink,
            child: Container(
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
                            _hideOverlay();
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
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────
// 検索結果タイル
// ─────────────────────────────────────────

class _SearchResultTile extends StatelessWidget {
  final PlaceResult place;
  final VoidCallback onTap;

  const _SearchResultTile({required this.place, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
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
