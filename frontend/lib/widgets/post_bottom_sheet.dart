import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:pointer_interceptor/pointer_interceptor.dart';
import 'dart:io' show File;
import '../core/theme.dart';
import '../providers/map_theme_provider.dart';
import '../services/api_service.dart';
import '../services/auth_service.dart';

class PostBottomSheet extends ConsumerStatefulWidget {
  const PostBottomSheet({super.key});

  @override
  ConsumerState<PostBottomSheet> createState() => _PostBottomSheetState();
}

class _PostBottomSheetState extends ConsumerState<PostBottomSheet> {
  final ImagePicker _picker = ImagePicker();
  XFile? _selectedImage;
  bool _isPosting = false;

  void _onAddPhotoTap() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (BuildContext context) {
        return Consumer(
          builder: (context, ref, child) {
            final isDark = ref.watch(mapThemeProvider);
            final bgColor = isDark ? AppColors.darkSurface : Colors.white;
            final textColor =
                isDark ? AppColors.darkTextPrimary : AppColors.primaryNavy;
            final iconColor =
                isDark ? AppColors.blueAccentLight : AppColors.primaryNavy;

            return Container(
              decoration: BoxDecoration(
                color: bgColor,
                borderRadius:
                    const BorderRadius.vertical(top: Radius.circular(20)),
              ),
              // Material(color: transparent) を挟むことで ListTile の
              // ink splash（波紋エフェクト）が正常に描画される。
              // Container 側の BoxDecoration が背景色を担うため透明で OK。
              child: Material(
                color: Colors.transparent,
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
                        title: Text('カメラで撮影',
                            style: TextStyle(color: textColor)),
                        onTap: () {
                          Navigator.pop(context);
                          _pickImage(ImageSource.camera);
                        },
                      ),
                      ListTile(
                        leading: Icon(Icons.photo_library, color: iconColor),
                        title: Text('ギャラリーから選択',
                            style: TextStyle(color: textColor)),
                        onTap: () {
                          Navigator.pop(context);
                          _pickImage(ImageSource.gallery);
                        },
                      ),
                      const SizedBox(height: 8),
                    ],
                  ),
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

  Future<void> _onPostTap() async {
    // 画像未選択の場合は早期リターン
    if (_selectedImage == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('写真を選択してください。'),
          backgroundColor: Colors.orange,
          duration: Duration(seconds: 2),
        ),
      );
      return;
    }

    // ローディング開始
    setState(() {
      _isPosting = true;
    });

    try {
      // EXIF情報依存のモードB API呼び出し（現在地は送信しない）
      final token = ref.read(authProvider).token;
      final result = await ref
          .read(apiServiceProvider)
          .analyzeImageGallery(
            imageFile: _selectedImage!,
            token: token,
          );

      if (!mounted) return;

      // 成功: シートを閉じてから SnackBar を表示
      Navigator.of(context).pop();

      final detectionCount = result.detections.length;
      final message = detectionCount > 0
          ? '投稿が完了しました！（$detectionCount件の対象を検出）'
          : '投稿が完了しました！（検出対象なし）';

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: AppColors.emeraldGreen,
          duration: const Duration(seconds: 3),
        ),
      );

      // コイン獲得UIの追加
      if (result.earnedCoins > 0) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Row(
              children: [
                const Text('🎉 ', style: TextStyle(fontSize: 18)),
                Text('+${result.earnedCoins} コイン獲得！', style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.white)),
              ],
            ),
            backgroundColor: Colors.amber.shade700,
            duration: const Duration(seconds: 4),
          ),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            '投稿に失敗しました。EXIF情報を含む写真をお試しください。',
          ),
          backgroundColor: Colors.red,
          duration: Duration(seconds: 4),
        ),
      );
    } finally {
      // シートが閉じられた後は setState を呼ばない
      if (mounted) {
        setState(() {
          _isPosting = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    // キーボードが表示された際にボトムシートを押し上げるための余白
    final bottomPadding = MediaQuery.of(context).viewInsets.bottom;

    final isDark = ref.watch(mapThemeProvider);
    final bgColor = isDark ? AppColors.darkSurface : Colors.white;
    final textColor =
        isDark ? AppColors.darkTextPrimary : AppColors.primaryNavy;
    final borderColor = isDark ? AppColors.darkBorder : Colors.grey.shade300;
    final photoBoxColor = isDark ? AppColors.darkCard : Colors.grey.shade50;

    // 投稿ボタンが有効かどうか（画像選択済み かつ 投稿中でない）
    final bool isPostEnabled = _selectedImage != null && !_isPosting;

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
            borderRadius:
                const BorderRadius.vertical(top: Radius.circular(20)),
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
                      icon: Icon(
                        Icons.close,
                        color:
                            isDark ? Colors.grey.shade400 : Colors.grey,
                      ),
                      onPressed:
                          _isPosting ? null : () => Navigator.of(context).pop(),
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
                        border: Border.all(color: borderColor, width: 2),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.add_a_photo,
                            color: isDark
                                ? Colors.grey.shade400
                                : Colors.grey,
                            size: 36,
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'タップして写真を追加',
                            style: TextStyle(
                              color: isDark
                                  ? Colors.grey.shade400
                                  : Colors.grey,
                              fontSize: 14,
                            ),
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
                          onTap: _isPosting ? null : _clearImage,
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
                const SizedBox(height: 24),

                // 投稿ボタン
                // - _isPosting: onPressed = null にしてタップ不可、インジケーター表示
                // - 画像未選択: disabledBackgroundColor でグレーアウト
                ElevatedButton(
                  onPressed: isPostEnabled ? _onPostTap : null,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.emeraldGreen,
                    // 画像未選択または投稿中は半透明グレーアウト
                    disabledBackgroundColor:
                        AppColors.emeraldGreen.withValues(alpha: 0.4),
                    foregroundColor: Colors.white,
                    disabledForegroundColor: Colors.white70,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    elevation: 0,
                  ),
                  child: _isPosting
                      ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : Text(
                          _selectedImage == null ? '写真を選択してください' : '投稿する',
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
