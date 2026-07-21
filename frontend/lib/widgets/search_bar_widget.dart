import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:pointer_interceptor/pointer_interceptor.dart';
import '../core/theme.dart';
import '../services/api_service.dart';
import '../providers/map_theme_provider.dart';

/// 場所・住所の検索結果
class PlaceResult {
  final String displayName;
  final String shortName;
  final double lat;
  final double lng;
  final double? distanceMeters; // 現在地からの距離（メートル）
  final String? placeId; // Google Place ID

  const PlaceResult({
    required this.displayName,
    required this.shortName,
    required this.lat,
    required this.lng,
    this.distanceMeters,
    this.placeId,
  });

  PlaceResult copyWith({
    double? distanceMeters,
  }) {
    return PlaceResult(
      displayName: displayName,
      shortName: shortName,
      lat: lat,
      lng: lng,
      distanceMeters: distanceMeters ?? this.distanceMeters,
      placeId: placeId,
    );
  }

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

  // Google Places Text Search API の JSON 形式に対応
  factory PlaceResult.fromGooglePlacesJson(Map<String, dynamic> json) {
    final name = json['name'] as String? ?? '';
    final address = json['formatted_address'] as String? ?? '';
    // formatted_address には "日本、〒123-4567 東京都..." のように国名が含まれることが多いので整形可能
    final cleanAddress = address.replaceAll(RegExp(r'^日本、(〒\d{3}-\d{4}\s*)?'), '');

    final geometry = json['geometry'] as Map<String, dynamic>?;
    final location = geometry?['location'] as Map<String, dynamic>?;

    return PlaceResult(
      shortName: name,
      displayName: cleanAddress,
      lat: (location?['lat'] as num?)?.toDouble() ?? 0.0,
      lng: (location?['lng'] as num?)?.toDouble() ?? 0.0,
      placeId: json['place_id'] as String?,
    );
  }
}

/// マップ上部に表示する検索バーWidget
///
/// 検索サジェストは Flutter Overlay に表示することで、
/// GoogleMap（PlatformView）のタッチ横取り問題を回避する。
class MapSearchBar extends ConsumerStatefulWidget {
  final GoogleMapController? mapController;
  final LatLng? currentPosition;

  /// サジェストリストの表示／非表示が切り替わった時に呼ばれるコールバック
  /// true = 表示中、false = 非表示
  final ValueChanged<bool>? onSuggestionsVisibilityChanged;

  /// サジェストから場所が選択された時に呼ばれるコールバック
  final ValueChanged<PlaceResult>? onPlaceSelected;

  /// 検索結果のリストが取得された時に呼ばれるコールバック
  final ValueChanged<List<PlaceResult>>? onSearchResultsFetched;

  const MapSearchBar({
    super.key,
    required this.mapController,
    this.currentPosition,
    this.onSuggestionsVisibilityChanged,
    this.onPlaceSelected,
    this.onSearchResultsFetched,
  });

  @override
  ConsumerState<MapSearchBar> createState() => _MapSearchBarState();
}

class _MapSearchBarState extends ConsumerState<MapSearchBar> {
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _focusNode = FocusNode();

  /// CompositedTransformTarget/Follower で検索バーの位置に
  /// Overlay を追従させるための LayerLink
  final LayerLink _layerLink = LayerLink();

  OverlayEntry? _overlayEntry;
  bool _isSearching = false;
  Timer? _debounceTimer;

  // 最新の検索結果をキャッシュしておくリスト
  List<PlaceResult> _lastResults = [];

  @override
  void initState() {
    super.initState();
    _focusNode.addListener(() {
      if (_focusNode.hasFocus) {
        // フォーカスが当たった際、文字とキャッシュがあればサジェストを復活
        if (_searchController.text.isNotEmpty && _lastResults.isNotEmpty) {
          // すでに表示されていなければ再表示
          if (_overlayEntry == null) {
            _showOverlay(_lastResults);
          }
        }
      } else {
        // タップ完了(PointerUp)を待ってからオーバーレイを閉じる。
        // 即座に閉じると PointerDown でフォーカスが外れた時点でオーバーレイが
        // 消えてしまい、サジェストの onTap が届かなくなるため遅延を入れる。
        Future.delayed(const Duration(milliseconds: 250), () {
          if (mounted && !_focusNode.hasFocus) {
            _hideOverlay();
          }
        });
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

    widget.onSearchResultsFetched?.call(results);

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
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 300),
                child: PointerInterceptor(
                  child: Consumer(
                    builder: (context, ref, child) {
                      final isDark = ref.watch(mapThemeProvider);
                      return Material(
                        elevation: 8,
                        color: isDark ? AppColors.darkSurface : Colors.white,
                        borderRadius: BorderRadius.circular(14),
                        clipBehavior: Clip.hardEdge,
                        child: ListView.separated(
                          padding: EdgeInsets.zero,
                          shrinkWrap: true,
                          physics: const ClampingScrollPhysics(),
                          itemCount: results.length,
                          separatorBuilder: (context, index) => Divider(
                            height: 1,
                            color: isDark ? AppColors.darkBorder : Colors.grey.shade200,
                          ),
                          itemBuilder: (context, index) {
                            final place = results[index];
                            return _SearchResultTile(
                              place: place,
                              onTap: () => _selectPlace(place),
                            );
                          },
                        ),
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

  /// Google Places Text Search API で検索（300ms のデバウンス付き）
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
        double? lat;
        double? lng;
        if (widget.currentPosition != null) {
          lat = widget.currentPosition!.latitude;
          lng = widget.currentPosition!.longitude;
        }

        final results = await ApiService().searchPlaces(
          query: query,
          lat: lat,
          lng: lng,
          radius: 10000,
        );

        if (!mounted) return;

        if (results != null) {
          // JSON パースと距離計算
          List<PlaceResult> newResults = results
              .map((e) => PlaceResult.fromGooglePlacesJson(e as Map<String, dynamic>))
              .toList();

          if (widget.currentPosition != null) {
            final cur = widget.currentPosition!;
            newResults = newResults.map((place) {
              final dist = _calculateDistance(
                cur.latitude, cur.longitude, place.lat, place.lng,
              );
              return place.copyWith(distanceMeters: dist);
            }).toList();

            // 現在地からの距離順にソートして、近隣施設を上位に表示
            newResults.sort((a, b) =>
                (a.distanceMeters ?? 0.0).compareTo(b.distanceMeters ?? 0.0));
          }

          // 検索成功時に結果をキャッシュに保存
          _lastResults = newResults;
          _showOverlay(newResults);
        } else {
          // null が返ってきた場合はエラー
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('検索中にエラーが発生しました'),
                backgroundColor: Colors.red.shade700,
              ),
            );
          }
        }
      } catch (e, stackTrace) {
        debugPrint('[SearchBar] Exception: $e');
        debugPrint('[SearchBar] StackTrace: $stackTrace');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('予期せぬエラーが発生しました'),
              backgroundColor: Colors.red.shade700,
            ),
          );
        }
      } finally {
        if (mounted) {
          setState(() => _isSearching = false);
        }
      }
    });
  }

  /// 2点間の距離を計算 (Haversine formula, 単位: メートル)
  double _calculateDistance(
      double lat1, double lon1, double lat2, double lon2) {
    const p = 0.017453292519943295; // Math.PI / 180
    final a = 0.5 -
        math.cos((lat2 - lat1) * p) / 2 +
        math.cos(lat1 * p) *
            math.cos(lat2 * p) *
            (1 - math.cos((lon2 - lon1) * p)) /
            2;
    return 12742 * math.asin(math.sqrt(a)) * 1000;
  }

  /// 検索結果の場所を選択して Google Maps カメラを移動
  void _selectPlace(PlaceResult place) {
    widget.onPlaceSelected?.call(place);
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
    final isDark = ref.watch(mapThemeProvider);
    final bgColor = isDark ? AppColors.darkSurface : Colors.white;
    final textColor = isDark ? AppColors.darkTextPrimary : Colors.black87;
    final hintColor = isDark ? AppColors.darkTextSecondary : Colors.grey.shade500;
    final iconColor = isDark ? AppColors.blueAccentLight : AppColors.primaryNavy;

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
                color: bgColor,
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
                style: TextStyle(fontSize: 14, color: textColor),
                decoration: InputDecoration(
                  hintText: '場所・住所を検索...',
                  hintStyle: TextStyle(
                    fontSize: 14,
                    color: hintColor,
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
                      : Icon(Icons.search, color: iconColor),
                  suffixIcon: _searchController.text.isNotEmpty
                      ? IconButton(
                          icon: const Icon(Icons.clear, color: Colors.grey),
                          onPressed: () {
                            _searchController.clear();
                            // クリア時はキャッシュも完全に破棄する
                            _lastResults.clear();
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

class _SearchResultTile extends ConsumerWidget {
  final PlaceResult place;
  final VoidCallback onTap;

  const _SearchResultTile({required this.place, required this.onTap});

  String _formatDistance(double meters) {
    if (meters < 1000) {
      return '${meters.toStringAsFixed(0)}m';
    } else {
      final kms = meters / 1000;
      return '${kms.toStringAsFixed(1)}km';
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isDark = ref.watch(mapThemeProvider);
    final textColor = isDark ? AppColors.darkTextPrimary : Colors.black87;
    final subTextColor = isDark ? AppColors.darkTextSecondary : Colors.grey.shade600;
    final iconColor = isDark ? AppColors.blueAccentLight : AppColors.primaryNavy;

    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
        child: Row(
          children: [
            Icon(
              Icons.location_on_outlined,
              color: iconColor,
              size: 20,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    place.shortName,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: textColor,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    place.displayName,
                    style: TextStyle(
                      fontSize: 11,
                      color: subTextColor,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            if (place.distanceMeters != null) ...[
              const SizedBox(width: 8),
              Text(
                _formatDistance(place.distanceMeters!),
                style: TextStyle(
                  fontSize: 12,
                  color: subTextColor,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
            const SizedBox(width: 4),
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
