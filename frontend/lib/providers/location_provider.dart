import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';

/// GPSによる現在地情報をリアルタイムで監視するStreamProvider
///
/// 権限拒否・サービス無効・予期しない例外のいずれが発生しても、
/// `throw` せず `debugPrint` でログに記録してストリームを静かに終了する。
/// これにより iOS クラッシュを防ぎ、UIは error 状態にフォールバックする。
final locationStreamProvider = StreamProvider<Position>((ref) async* {
  try {
    // 1. 位置情報サービスが有効かチェック
    final bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      debugPrint('[LocationProvider] 位置情報サービスが無効です。');
      return; // throwせずに終了
    }

    // 2. パーミッションの確認
    LocationPermission permission = await Geolocator.checkPermission();

    // 3. 未決（denied）の場合はダイアログを出してリクエスト
    if (permission == LocationPermission.denied) {
      debugPrint('[LocationProvider] 位置情報が拒否されています。許可をリクエストします。');
      permission = await Geolocator.requestPermission();
    }

    // 4. リクエスト後も拒否された場合
    if (permission == LocationPermission.denied) {
      debugPrint('[LocationProvider] 位置情報の利用権限がユーザーに拒否されました。');
      return; // throwせずに終了
    }

    // 5. 永続的に拒否されている場合（設定画面からしか変更不可）
    if (permission == LocationPermission.deniedForever) {
      debugPrint('[LocationProvider] 位置情報の利用権限が永久に拒否されています。設定から許可してください。');
      return; // throwせずに終了
    }

    // 6. 権限取得成功: リアルタイムの位置情報ストリームを流す
    // 精度: High (高精度), 位置が2メートル以上動いたら更新
    const locationSettings = LocationSettings(
      accuracy: LocationAccuracy.high,
      distanceFilter: 2,
    );

    yield* Geolocator.getPositionStream(locationSettings: locationSettings);
  } catch (e, stackTrace) {
    // 予期しないエラー（権限API例外、プラットフォームエラー等）はクラッシュさせない
    debugPrint('[LocationProvider] 予期しないエラーが発生しました: $e');
    debugPrint('[LocationProvider] StackTrace: $stackTrace');
    // throwせずに終了: StreamProvider は error 状態になり、UIは適切にフォールバックする
    return;
  }
});

