import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/image_provider.dart';
import '../models/analyze_result.dart';
import '../core/theme.dart';

/// BoundingBoxを画像上に描画するPainter
///
/// バックエンドから返ってくるbboxはピクセル座標 [x1, y1, x2, y2] 形式。
/// 画像の実際の表示サイズ (size) に合わせてスケールして描画する。
class BoundingBoxPainter extends CustomPainter {
  final List<Detection> detections;

  /// バックエンドから返ってきた元画像のサイズ（ピクセル）
  /// 不明の場合はnull（スケールなしで描画）
  final Size? originalImageSize;

  BoundingBoxPainter(this.detections, {this.originalImageSize});

  @override
  void paint(Canvas canvas, Size size) {
    for (var detection in detections) {
      final isHighAccuracy = detection.positionAccuracy == 'high';

      // 精度によって色を変える（high=緑, low=半透明オレンジ）
      final color = isHighAccuracy
          ? AppColors.emeraldGreen
          : Colors.orange.withValues(alpha: 0.7);

      final boxPaint = Paint()
        ..color = color
        ..strokeWidth = 2.5
        ..style = PaintingStyle.stroke;

      // ピクセル座標を表示サイズにスケール変換
      final double scaleX = originalImageSize != null
          ? size.width / originalImageSize!.width
          : size.width / 1920; // fallback: 撮影最大サイズ
      final double scaleY = originalImageSize != null
          ? size.height / originalImageSize!.height
          : size.height / 1920;

      final rect = Rect.fromLTRB(
        detection.bbox.x1 * scaleX,
        detection.bbox.y1 * scaleY,
        detection.bbox.x2 * scaleX,
        detection.bbox.y2 * scaleY,
      );

      // 枠を描画
      canvas.drawRect(rect, boxPaint);

      // コーナーの強調（カメラアプリ風）
      _drawCorners(canvas, rect, color);

      // ラベルと信頼度テキスト
      final labelBg = Paint()..color = color.withValues(alpha: 0.85);
      final label =
          '${_formatLabel(detection.label)} ${(detection.confidence * 100).toStringAsFixed(0)}%';

      final textPainter = TextPainter(
        text: TextSpan(
          text: label,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 9,
            fontWeight: FontWeight.bold,
          ),
        ),
        textDirection: TextDirection.ltr,
      );
      textPainter.layout();

      final labelRect = Rect.fromLTWH(
        rect.left,
        rect.top > 16 ? rect.top - 16 : rect.bottom,
        textPainter.width + 6,
        14,
      );
      canvas.drawRect(labelRect, labelBg);
      textPainter.paint(canvas, Offset(labelRect.left + 3, labelRect.top + 2));
    }
  }

  /// コーナーを強調する線を描画（カメラアプリ風のUI）
  void _drawCorners(Canvas canvas, Rect rect, Color color) {
    final cornerPaint = Paint()
      ..color = color
      ..strokeWidth = 4.0
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    const cornerLength = 12.0;

    // 左上
    canvas.drawLine(rect.topLeft, rect.topLeft.translate(cornerLength, 0), cornerPaint);
    canvas.drawLine(rect.topLeft, rect.topLeft.translate(0, cornerLength), cornerPaint);
    // 右上
    canvas.drawLine(rect.topRight, rect.topRight.translate(-cornerLength, 0), cornerPaint);
    canvas.drawLine(rect.topRight, rect.topRight.translate(0, cornerLength), cornerPaint);
    // 左下
    canvas.drawLine(rect.bottomLeft, rect.bottomLeft.translate(cornerLength, 0), cornerPaint);
    canvas.drawLine(rect.bottomLeft, rect.bottomLeft.translate(0, -cornerLength), cornerPaint);
    // 右下
    canvas.drawLine(rect.bottomRight, rect.bottomRight.translate(-cornerLength, 0), cornerPaint);
    canvas.drawLine(rect.bottomRight, rect.bottomRight.translate(0, -cornerLength), cornerPaint);
  }

  String _formatLabel(String label) {
    final labels = {
      'streetlight': '街灯',
      'obstacle': '障害物',
      'puddle': '水たまり',
      'crack': 'ひび割れ',
      'hole': '穴',
    };
    return labels[label] ?? label;
  }

  @override
  bool shouldRepaint(covariant BoundingBoxPainter oldDelegate) => true;
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

    final hasResult = imageState.analyzeResult != null;
    final hasDetections =
        hasResult && imageState.analyzeResult!.detections.isNotEmpty;
    final hasError = imageState.errorMessage != null;

    return Positioned(
      left: 12,
      bottom: 16,
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            // 解析結果のフィードバックテキスト（仕様書 Section 6-5 準拠）
            if (hasResult || hasError)
              _buildFeedbackBadge(context),

            const SizedBox(height: 6),

            // 画像プレビューカード
            Card(
              elevation: 10,
              shadowColor: Colors.black.withValues(alpha: 0.3),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
              clipBehavior: Clip.antiAlias,
              child: SizedBox(
                width: 150,
                height: 150,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    // 画像本体（Webとモバイルで出し分け）
                    kIsWeb
                        ? Image.network(
                            imageState.image!.path,
                            fit: BoxFit.cover,
                            errorBuilder: (_, __, ___) =>
                                const Icon(Icons.broken_image, size: 40),
                          )
                        : Image.file(
                            File(imageState.image!.path),
                            fit: BoxFit.cover,
                          ),

                    // BBoxの描画（解析結果がある場合のみ）
                    if (hasDetections)
                      CustomPaint(
                        painter: BoundingBoxPainter(
                          imageState.analyzeResult!.detections,
                        ),
                      ),

                    // ローディングインジケータ（解析中のみ）
                    if (imageState.isAnalyzing)
                      Container(
                        color: Colors.black54,
                        child: const Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              CircularProgressIndicator(
                                color: Colors.white,
                                strokeWidth: 2.5,
                              ),
                              SizedBox(height: 8),
                              Text(
                                'AI解析中...',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 10,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),

                    // 右上の「×」ボタン
                    Positioned(
                      top: 6,
                      right: 6,
                      child: GestureDetector(
                        onTap: () {
                          ref
                              .read(selectedImageProvider.notifier)
                              .clearImage();
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
                            size: 14,
                          ),
                        ),
                      ),
                    ),

                    // 下部ステータスバー
                    if (!imageState.isAnalyzing)
                      Positioned(
                        bottom: 0,
                        left: 0,
                        right: 0,
                        child: Container(
                          color: hasError
                              ? Colors.red.withValues(alpha: 0.85)
                              : hasDetections
                                  ? AppColors.emeraldGreen.withValues(alpha: 0.85)
                                  : Colors.black54,
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: Text(
                            hasError
                                ? 'エラー'
                                : hasDetections
                                    ? '${imageState.analyzeResult!.detections.length}件検出'
                                    : '検出なし',
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
          ],
        ),
      ),
    );
  }

  /// 解析完了後のフィードバックバッジ
  Widget _buildFeedbackBadge(BuildContext context) {
    final hasError = imageState.errorMessage != null;
    final detections = imageState.analyzeResult?.detections ?? [];

    if (hasError) {
      return _badge(
        icon: Icons.error_outline,
        color: Colors.red.shade700,
        text: 'GPS情報が必要です',
      );
    }

    if (detections.isEmpty) {
      return _badge(
        icon: Icons.search_off,
        color: Colors.grey.shade700,
        text: '検出対象がありません',
      );
    }

    // 最初の検出物の情報を表示
    final first = detections.first;
    final isHigh = first.positionAccuracy == 'high';
    final distText = first.estimatedDistanceM != null
        ? '約${first.estimatedDistanceM!.toStringAsFixed(0)}m先'
        : '付近';

    return _badge(
      icon: isHigh ? Icons.location_on : Icons.location_searching,
      color: isHigh ? AppColors.emeraldGreen : Colors.orange.shade700,
      text: '${_formatLabel(first.label)}を${distText}に登録しました',
    );
  }

  Widget _badge({
    required IconData icon,
    required Color color,
    required String text,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.2),
            blurRadius: 4,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: Colors.white, size: 14),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              text,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 11,
                fontWeight: FontWeight.bold,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  String _formatLabel(String label) {
    const labels = {
      'streetlight': '街灯',
      'obstacle': '障害物',
      'puddle': '水たまり',
      'crack': 'ひび割れ',
      'hole': '穴',
    };
    return labels[label] ?? label;
  }
}
