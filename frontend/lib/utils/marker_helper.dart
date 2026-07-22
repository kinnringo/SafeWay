import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

Future<BitmapDescriptor> createBearMarker({required int size}) async {
  final ui.PictureRecorder pictureRecorder = ui.PictureRecorder();
  final Canvas canvas = Canvas(pictureRecorder);

  // 1. 背景の白い円を描画
  final Paint paint = Paint()..color = const Color(0xFFFFFFFF);
  final double radius = size / 2;
  canvas.drawCircle(Offset(radius, radius), radius, paint);

  // 2. クマの画像をロード
  final ByteData data = await rootBundle.load('assets/images/bear.png');
  final ui.Codec codec = await ui.instantiateImageCodec(
    data.buffer.asUint8List(),
    targetWidth: (size * 0.7).toInt(), // 円の中に収まるように縮小
  );
  final ui.FrameInfo fi = await codec.getNextFrame();
  final ui.Image image = fi.image;

  // 3. 画像を円の中央に描画
  final double offset = (size - image.width) / 2;
  canvas.drawImage(image, Offset(offset, offset), Paint());

  // 4. BitmapDescriptor に変換
  final ui.Image markerAsImage = await pictureRecorder.endRecording().toImage(size, size);
  final ByteData? byteData = await markerAsImage.toByteData(format: ui.ImageByteFormat.png);
  final Uint8List uint8List = byteData!.buffer.asUint8List();

  return BitmapDescriptor.bytes(uint8List);
}
