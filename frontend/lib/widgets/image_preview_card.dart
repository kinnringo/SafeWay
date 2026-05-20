import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import '../providers/image_provider.dart';

class ImagePreviewCard extends ConsumerWidget {
  final XFile imageFile;

  const ImagePreviewCard({
    super.key,
    required this.imageFile,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Positioned(
      left: 16,
      bottom: 16,
      // SafeAreaを使用してノッチやホームバーとの重なりを回避
      child: SafeArea(
        child: Card(
          elevation: 10,
          shadowColor: Colors.black.withValues(alpha: 0.3),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          clipBehavior: Clip.antiAlias,
          child: Container(
            width: 130,
            height: 130,
            color: Colors.grey[200],
            child: Stack(
              fit: StackFit.expand,
              children: [
                // 画像本体
                Image.file(
                  File(imageFile.path),
                  fit: BoxFit.cover,
                ),
                // 右上の丸い「×」ボタン
                Positioned(
                  top: 6,
                  right: 6,
                  child: GestureDetector(
                    onTap: () {
                      ref.read(selectedImageProvider.notifier).clearImage();
                    },
                    child: Container(
                      decoration: const BoxDecoration(
                        color: Colors.black54,
                        shape: BoxShape.circle,
                      ),
                      padding: const EdgeInsets.all(4),
                      child: const Icon(
                        Icons.close,
                        color: Colors.white,
                        size: 16,
                      ),
                    ),
                  ),
                ),
                // ラベル
                Positioned(
                  bottom: 0,
                  left: 0,
                  right: 0,
                  child: Container(
                    color: Colors.black54,
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: const Text(
                      'プレビュー画像',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                      ),
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
