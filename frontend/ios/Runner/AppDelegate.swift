import Flutter
import UIKit
import GoogleMaps

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // Secrets.plist からAPIキーを安全に読み込む（このファイルはGitignored）
    if let secretsPath = Bundle.main.path(forResource: "Secrets", ofType: "plist"),
       let secrets = NSDictionary(contentsOfFile: secretsPath),
       let apiKey = secrets["MAPS_API_KEY"] as? String,
       !apiKey.isEmpty,
       apiKey != "YOUR_GOOGLE_MAPS_API_KEY_HERE" {
      GMSServices.provideAPIKey(apiKey)
    } else {
      print("[SafeWay WARNING] Google Maps APIキーが未設定です。")
      print("  ios/Runner/Secrets.plist を作成し、MAPS_API_KEY にキーを設定してください。")
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
  }
}
