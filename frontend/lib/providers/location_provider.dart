import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';

/// GPSによる現在地情報をリアルタイムで監視するStreamProvider
final locationStreamProvider = StreamProvider<Position>((ref) async* {
  bool serviceEnabled;
  LocationPermission permission;

  // 位置情報サービスが有効かチェック
  serviceEnabled = await Geolocator.isLocationServiceEnabled();
  if (!serviceEnabled) {
    throw Exception('位置情報サービスが無効になっています。設定から有効にしてください。');
  }

  // パーミッションの確認
  permission = await Geolocator.checkPermission();
  if (permission == LocationPermission.denied) {
    // 拒否されている場合は権限を要求
    permission = await Geolocator.requestPermission();
    if (permission == LocationPermission.denied) {
      throw Exception('位置情報の利用権限が拒否されました。');
    }
  }

  if (permission == LocationPermission.deniedForever) {
    throw Exception('位置情報の利用権限が永久に拒否されています。アプリの設定画面から許可してください。');
  }

  // リアルタイムの位置情報ストリームを流す
  // 精度: High (高精度), 位置が2メートル以上動いたら更新
  const locationSettings = LocationSettings(
    accuracy: LocationAccuracy.high,
    distanceFilter: 2,
  );

  yield* Geolocator.getPositionStream(locationSettings: locationSettings);
});
