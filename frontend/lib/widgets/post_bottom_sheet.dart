import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:pointer_interceptor/pointer_interceptor.dart';
import 'dart:io' show File;
import '../core/theme.dart';
import '../providers/map_theme_provider.dart';

class PostBottomSheet extends ConsumerStatefulWidget {
  const PostBottomSheet({super.key});

  @override
  ConsumerState<PostBottomSheet> createState() => _PostBottomSheetState();
}

class _PostBottomSheetState extends ConsumerState<PostBottomSheet> {
  final TextEditingController _textController = TextEditingController();
  final ImagePicker _picker = ImagePicker();
  XFile? _selectedImage;

  void _onAddPhotoTap() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (BuildContext context) {
        return Consumer(
          builder: (context, ref, child) {
            final isDark = ref.watch(mapThemeProvider);
            final bgColor = isDark ? AppColors.darkSurface : Colors.white;
            final textColor = isDark ? AppColors.darkTextPrimary : AppColors.primaryNavy;
            final iconColor = isDark ? AppColors.blueAccentLight : AppColors.primaryNavy;

            return Container(
              decoration: BoxDecoration(
                color: bgColor,
                borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
              ),
              child: SafeArea(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      child: Text(
                        '写真を追加',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: textColor,
                        ),
                      ),
                    ),
                    ListTile(
                      leading: Icon(Icons.camera_alt, color: iconColor),
                      title: Text('カメラで撮影', style: TextStyle(color: textColor)),
                      onTap: () {
                        Navigator.pop(context);
                        _pickImage(ImageSource.camera);
                      },
                    ),
                    ListTile(
                      leading: Icon(Icons.photo_library, color: iconColor),
                      title: Text('ギャラリーから選択', style: TextStyle(color: textColor)),
                      onTap: () {
                        Navigator.pop(context);
                        _pickImage(ImageSource.gallery);
                      },
                    ),
                    const SizedBox(height: 8),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _pickImage(ImageSource source) async {
    try {
      final XFile? image = await _picker.pickImage(source: source);
      if (image != null) {
        setState(() {
          _selectedImage = image;
        });
      }
    } catch (e) {
      debugPrint('画像選択エラー: $e');
    }
  }

  void _clearImage() {
    setState(() {
      _selectedImage = null;
    });
  }

  void _onPostTap() {
    debugPrint('[PostBottomSheet] 投稿ボタンがタップされました: ${_textController.text}');
    Navigator.of(context).pop();
  }

  @override
  void dispose() {
    _textController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // キーボードが表示された際にボトムシートを押し上げるための余白
    final bottomPadding = MediaQuery.of(context).viewInsets.bottom;
    
    final isDark = ref.watch(mapThemeProvider);
    final bgColor = isDark ? AppColors.darkSurface : Colors.white;
    final textColor = isDark ? AppColors.darkTextPrimary : AppColors.primaryNavy;
    final hintColor = isDark ? AppColors.darkTextSecondary : Colors.grey.shade400;
    final borderColor = isDark ? AppColors.darkBorder : Colors.grey.shade300;
    final photoBoxColor = isDark ? AppColors.darkCard : Colors.grey.shade50;

    return PointerInterceptor(
      child: GestureDetector(
        onTap: () => FocusScope.of(context).unfocus(),
        behavior: HitTestBehavior.opaque,
        child: Container(
          padding: EdgeInsets.only(
            left: 20,
            right: 20,
            top: 16,
            bottom: bottomPadding + 20,
          ),
        decoration: BoxDecoration(
          color: bgColor,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // ヘッダー
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    '状況をシェアする',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: textColor,
                    ),
                  ),
                  IconButton(
                    icon: Icon(Icons.close, color: isDark ? Colors.grey.shade400 : Colors.grey),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
              const SizedBox(height: 16),

              // 写真選択エリア
              if (_selectedImage == null)
                GestureDetector(
                  onTap: _onAddPhotoTap,
                  child: Container(
                    height: 120,
                    decoration: BoxDecoration(
                      color: photoBoxColor,
                      border: Border.all(color: borderColor, width: 2), // 枠線
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.add_a_photo, color: isDark ? Colors.grey.shade400 : Colors.grey, size: 36),
                        const SizedBox(height: 8),
                        Text(
                          'タップして写真を追加',
                          style: TextStyle(color: isDark ? Colors.grey.shade400 : Colors.grey, fontSize: 14),
                        ),
                      ],
                    ),
                  ),
                )
              else
                Stack(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: SizedBox(
                        height: 200,
                        width: double.infinity,
                        child: kIsWeb
                            ? Image.network(
                                _selectedImage!.path,
                                fit: BoxFit.cover,
                              )
                            : Image.file(
                                File(_selectedImage!.path),
                                fit: BoxFit.cover,
                              ),
                      ),
                    ),
                    Positioned(
                      top: 8,
                      right: 8,
                      child: GestureDetector(
                        onTap: _clearImage,
                        child: Container(
                          padding: const EdgeInsets.all(4),
                          decoration: const BoxDecoration(
                            color: Colors.black54,
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(
                            Icons.close,
                            color: Colors.white,
                            size: 20,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              const SizedBox(height: 20),

              // テキスト入力欄
              TextField(
                controller: _textController,
                maxLines: 4,
                minLines: 3,
                style: TextStyle(color: isDark ? AppColors.darkTextPrimary : Colors.black87),
                decoration: InputDecoration(
                  hintText: '冠水、工事中、落とし物など、街の状況を詳しく教えてください...',
                  hintStyle: TextStyle(color: hintColor),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(color: borderColor),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(color: borderColor),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(color: AppColors.blueAccentLight, width: 2),
                  ),
                  contentPadding: const EdgeInsets.all(16),
                  fillColor: isDark ? AppColors.darkCard : null,
                  filled: isDark,
                ),
              ),
              const SizedBox(height: 24),

              // 投稿ボタン
              ElevatedButton(
                onPressed: _onPostTap,
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.emeraldGreen,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  elevation: 0,
                ),
                child: const Text(
                  '投稿する',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ),
        ),
      ),
    ));
  }
}
