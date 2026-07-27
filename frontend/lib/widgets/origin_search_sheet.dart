import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/theme.dart';
import '../services/api_service.dart';
import '../providers/map_theme_provider.dart';
import 'search_bar_widget.dart'; // PlaceResult用
import 'package:pointer_interceptor/pointer_interceptor.dart';

class OriginSearchSheet extends ConsumerStatefulWidget {
  final String title;
  final String hintText;
  const OriginSearchSheet({
    super.key,
    this.title = '地点を選択',
    this.hintText = '場所の名前や住所を検索...',
  });

  @override
  ConsumerState<OriginSearchSheet> createState() => _OriginSearchSheetState();
}

class _OriginSearchSheetState extends ConsumerState<OriginSearchSheet> {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focusNode = FocusNode();
  List<PlaceResult> _results = [];
  bool _isLoading = false;
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    // 自動でキーボードを表示
    Future.delayed(const Duration(milliseconds: 100), () {
      if (mounted) _focusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    _debounce?.cancel();
    super.dispose();
  }

  void _onSearchChanged(String query) {
    if (_debounce?.isActive ?? false) _debounce!.cancel();
    
    if (query.isEmpty) {
      setState(() {
        _results = [];
        _isLoading = false;
      });
      return;
    }

    _debounce = Timer(const Duration(milliseconds: 500), () async {
      if (!mounted) return;
      setState(() => _isLoading = true);

      try {
        final apiService = ref.read(apiServiceProvider);
        // 現在地によるバイアスは不要なのでlat/lngは省略（または保持している現在地を渡すことも可能）
        final resultsRaw = await apiService.searchPlaces(query: query);
        
        if (mounted && resultsRaw != null) {
          final List<PlaceResult> parsedResults = [];
          for (var item in resultsRaw) {
            parsedResults.add(PlaceResult.fromGooglePlacesJson(item));
          }
          setState(() {
            _results = parsedResults;
          });
        }
      } catch (e) {
        debugPrint('Origin search error: $e');
      } finally {
        if (mounted) {
          setState(() => _isLoading = false);
        }
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final isDark = ref.watch(mapThemeProvider);
    final bgColor = isDark ? AppColors.darkSurface : Colors.white;
    final textColor = isDark ? AppColors.darkTextPrimary : Colors.black87;
    final hintColor = isDark ? AppColors.darkTextSecondary : Colors.grey;

    // ViewInsets for keyboard
    final bottomPadding = MediaQuery.of(context).viewInsets.bottom;

    return PointerInterceptor(
      child: Container(
        height: MediaQuery.of(context).size.height * 0.8,
        padding: EdgeInsets.only(bottom: bottomPadding),
        decoration: BoxDecoration(
          color: bgColor,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: Column(
          children: [
            const SizedBox(height: 12),
            // つまみ
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.grey.shade400,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 12),
            // シートタイトル
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Row(
                children: [
                  Icon(Icons.edit_location, color: textColor),
                  const SizedBox(width: 8),
                  Text(widget.title, style: TextStyle(color: textColor, fontSize: 18, fontWeight: FontWeight.bold)),
                  const Spacer(),
                  IconButton(icon: Icon(Icons.close, color: textColor), onPressed: () => Navigator.of(context).pop()),
                ],
              ),
            ),
            const SizedBox(height: 8),
            
            // 検索バー
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16.0),
              child: TextField(
                controller: _controller,
                focusNode: _focusNode,
                style: TextStyle(color: textColor),
                decoration: InputDecoration(
                  hintText: widget.hintText,
                  hintStyle: TextStyle(color: hintColor),
                  prefixIcon: const Icon(Icons.search, color: Colors.grey),
                  suffixIcon: _controller.text.isNotEmpty
                      ? IconButton(
                          icon: const Icon(Icons.clear, color: Colors.grey),
                          onPressed: () {
                            _controller.clear();
                            _onSearchChanged('');
                          },
                        )
                      : null,
                  filled: true,
                  fillColor: isDark ? AppColors.darkCard : Colors.grey.shade100,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                  contentPadding: const EdgeInsets.symmetric(vertical: 0),
                ),
                onChanged: _onSearchChanged,
              ),
            ),
            
            // 「現在地」を選ぶ選択肢
            ListTile(
              leading: const Icon(Icons.my_location, color: Colors.blue),
              title: Text('現在地を使用', style: TextStyle(color: textColor, fontWeight: FontWeight.bold)),
              onTap: () {
                Navigator.pop(context, 'CURRENT_LOCATION');
              },
            ),
            // 「地図上で選択」を選ぶ選択肢
            ListTile(
              leading: const Icon(Icons.edit_location_alt_rounded, color: Color(0xFF10B981)), // エメラルドグリーン
              title: Text('地図上で選択', style: TextStyle(color: textColor, fontWeight: FontWeight.bold)),
              onTap: () {
                Navigator.pop(context, 'SELECT_ON_MAP');
              },
            ),
            const Divider(height: 1),
            
            // 検索結果リスト
            Expanded(
              child: _isLoading
                  ? const Center(child: CircularProgressIndicator())
                  : ListView.builder(
                      itemCount: _results.length,
                      itemBuilder: (context, index) {
                        final r = _results[index];
                        return ListTile(
                          leading: const Icon(Icons.location_on, color: Colors.grey),
                          title: Text(r.shortName, style: TextStyle(color: textColor)),
                          subtitle: Text(
                            r.displayName,
                            style: TextStyle(color: hintColor, fontSize: 12),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          onTap: () {
                            Navigator.pop(context, r);
                          },
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
