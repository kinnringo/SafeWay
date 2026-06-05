import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/image_provider.dart';
import '../models/analyze_result.dart';

class BoundingBoxPainter extends CustomPainter {
  final List<AnalyzeResult> results;

  BoundingBoxPainter(this.results);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.red
      ..strokeWidth = 2.0
      ..style = PaintingStyle.stroke;

    final textPainter = TextPainter(
      textDirection: TextDirection.ltr,
    );

    for (var result in results) {
      // 0.0〜1.0 の相対座標を画像の実際のピクセルサイズに変換
      final rect = Rect.fromLTRB(
        result.bbox.xmin * size.width,
        result.bbox.ymin * size.height,
        result.bbox.xmax * size.width,
        result.bbox.ymax * size.height,
      );
      
      // 枠線を描画
      canvas.drawRect(rect, paint);

      // ラベルと信頼度を描画
      final textSpan = TextSpan(
        text: '${result.label} ${(result.confidence * 100).toStringAsFixed(1)}%',
        style: const TextStyle(
          color: Colors.white,
          backgroundColor: Colors.red,
          fontSize: 10,
          fontWeight: FontWeight.bold,
        ),
      );
      textPainter.text = textSpan;
      textPainter.layout();
      
      // 文字の位置を枠の左上に
      textPainter.paint(
        canvas, 
        Offset(rect.left, rect.top > 12 ? rect.top - 12 : rect.top)
      );
    }
  }

  @override
  bool shouldRepaint(covariant BoundingBoxPainter oldDelegate) {
    return true; // データが変われば再描画
  }
}

class ImagePreviewCard extends ConsumerWidget {
  final ImageAnalyzeState imageState;

  const ImagePreviewCard({
    super.key,
    required this.imageState,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (imageState.image == null) return const SizedBox.shrink();

    return Positioned(
      left: 16,
      bottom: 16,
      child: SafeArea(
        child: Card(
          elevation: 10,
          shadowColor: Colors.black.withValues(alpha: 0.3),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          clipBehavior: Clip.antiAlias,
          child: Container(
            width: 140,
            height: 140,
            color: Colors.grey[200],
            child: Stack(
              fit: StackFit.expand,
              children: [
                // 1. 画像本体（Webとモバイルで出し分け）
                kIsWeb
                    ? Image.network(
                        imageState.image!.path,
                        fit: BoxFit.cover,
                      )
                    : Image.file(
                        File(imageState.image!.path),
                        fit: BoxFit.cover,
                      ),

                // 2. BBoxの描画（解析結果がある場合のみ）
                if (imageState.analyzeResult != null && imageState.analyzeResult!.results.isNotEmpty)
                  CustomPaint(
                    painter: BoundingBoxPainter(imageState.analyzeResult!.results),
                  ),

                // 3. ローディングインジケータ（解析中のみ）
                if (imageState.isAnalyzing)
                  Container(
                    color: Colors.black45,
                    child: const Center(
                      child: CircularProgressIndicator(
                        color: Colors.white,
                        strokeWidth: 3,
                      ),
                    ),
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
                    child: Text(
                      imageState.isAnalyzing ? 'YOLO解析中...' : '解析完了',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
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
