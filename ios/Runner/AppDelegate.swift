import Flutter
import UIKit

// Native side of the "reelchecker" MethodChannel — the calls Dart
// makes through lib/services/platform.dart. Same channel name and
// method names as Android (MainActivity.kt):
//  - getDeviceId: identifierForVendor (stable per vendor on this
//    device; changes if all the vendor's apps are deleted)
//  - getDeviceModel: hardware identifier, e.g. "iPhone15,3"
//  - getVersionName / getVersionCode: Bundle short version / build
//  - getSharedText / saveToDownloads / updateApkPath / installApk:
//    not supported on iOS — Dart saves downloads to the app
//    documents folder and offers the system share sheet instead,
//    and APK install does not exist (updater reports "not
//    supported" to the page).

@main
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    if let controller = window?.rootViewController as? FlutterViewController {
      let channel = FlutterMethodChannel(
        name: "reelchecker",
        binaryMessenger: controller.binaryMessenger)
      channel.setMethodCallHandler { call, result in
        switch call.method {
        case "getDeviceId":
          result(UIDevice.current.identifierForVendor?.uuidString)
        case "getDeviceModel":
          result(AppDelegate.deviceModel())
        case "getVersionName":
          result(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String)
        case "getVersionCode":
          if let v = Bundle.main.infoDictionary?["CFBundleVersion"] as? String,
             let n = Int(v) {
            result(n)
          } else {
            result(0)
          }
        case "getSharedText":
          result(nil)
        case "saveToDownloads":
          result(false)
        case "updateApkPath":
          result("")
        case "installApk":
          result(false)
        default:
          result(FlutterMethodNotImplemented)
        }
      }
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  /// Hardware machine identifier, e.g. "iPhone15,3" / "iPad14,1".
  private static func deviceModel() -> String {
    var systemInfo = utsname()
    uname(&systemInfo)
    let mirror = Mirror(reflecting: systemInfo.machine)
    return mirror.children.reduce("") { id, element in
      guard let value = element.value as? Int8, value != 0 else { return id }
      return id + String(UnicodeScalar(UInt8(value)))
    }
  }
}
