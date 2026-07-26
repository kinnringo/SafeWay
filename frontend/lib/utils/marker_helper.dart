import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

/// 白い円の背景に [assetPath] の画像を描画したカスタムマーカーを生成する汎用関数。
///
/// [size]      マーカー全体の正方形サイズ（論理ピクセル）
/// [assetPath] 表示する画像のアセットパス
/// [imageScale] 画像を円に対して何割のサイズにするか（デフォルト 0.7）
Future<BitmapDescriptor> createCircleIconMarker({
  required int size,
  required String assetPath,
  double imageScale = 0.7,
}) async {
  final ui.PictureRecorder pictureRecorder = ui.PictureRecorder();
  final Canvas canvas = Canvas(pictureRecorder);

  // 1. 背景の白い円を描画
  final Paint paint = Paint()..color = const Color(0xFFFFFFFF);
  final double radius = size / 2;
  canvas.drawCircle(Offset(radius, radius), radius, paint);

  // 2. 画像をロード
  final ByteData data = await rootBundle.load(assetPath);
  final ui.Codec codec = await ui.instantiateImageCodec(
    data.buffer.asUint8List(),
    targetWidth: (size * imageScale).toInt(),
  );
  final ui.FrameInfo fi = await codec.getNextFrame();
  final ui.Image image = fi.image;

  // 3. 画像を円の中央に描画
  final double offset = (size - image.width) / 2;
  canvas.drawImage(image, Offset(offset, offset), Paint());

  // 4. BitmapDescriptor に変換
  final ui.Image markerAsImage =
      await pictureRecorder.endRecording().toImage(size, size);
  final ByteData? byteData =
      await markerAsImage.toByteData(format: ui.ImageByteFormat.png);
  final Uint8List uint8List = byteData!.buffer.asUint8List();

  return BitmapDescriptor.bytes(uint8List);
}

/// クマのカスタムマーカー（後方互換のためラッパーとして維持）
Future<BitmapDescriptor> createBearMarker({required int size}) async {
  return createCircleIconMarker(
    size: size,
    assetPath: 'assets/images/bear.png',
  );
}

/// 街灯のカスタムマーカー
Future<BitmapDescriptor> createStreetlightMarker({required int size}) async {
  return createCircleIconMarker(
    size: size,
    assetPath: 'assets/images/Streetlight.png',
  );
}
