// Native platform calls (MethodChannel "reelchecker").
// Android: Settings.Secure.ANDROID_ID, Build.MODEL, PackageManager version,
// MediaStore save to public Downloads, FileProvider APK install, shared
// text from the ACTION_SEND intent.
// iOS: identifierForVendor, UIDevice model, Bundle version; shared text and
// APK install are not supported (methods return null / false).

import 'package:flutter/services.dart';

class NativePlatform {
  static const MethodChannel _channel = MethodChannel('reelchecker');

  static Future<String> getDeviceId() async {
    try {
      final id = await _channel.invokeMethod<String>('getDeviceId');
      return id ?? '';
    } catch (_) {
      return '';
    }
  }

  static Future<String> getDeviceModel() async {
    try {
      final model = await _channel.invokeMethod<String>('getDeviceModel');
      return model ?? '';
    } catch (_) {
      return '';
    }
  }

  static Future<String> getVersionName() async {
    try {
      final name = await _channel.invokeMethod<String>('getVersionName');
      return name ?? '';
    } catch (_) {
      return '';
    }
  }

  static Future<int> getVersionCode() async {
    try {
      final code = await _channel.invokeMethod<int>('getVersionCode');
      return code ?? 0;
    } catch (_) {
      return 0;
    }
  }

  /// Text shared to the app (ACTION_SEND from Instagram), or null.
  /// Consumed once per launch — the native side clears it after read.
  static Future<String?> getSharedText() async {
    try {
      return await _channel.invokeMethod<String>('getSharedText');
    } catch (_) {
      return null;
    }
  }

  /// Copy a file already on disk into the public Downloads folder
  /// (Android: MediaStore.Downloads, IS_PENDING flow; iOS: not
  /// supported — the caller saves to documents and shares instead).
  /// Returns true on success.
  static Future<bool> saveToDownloads(
      String sourcePath, String fileName, String mimeType) async {
    try {
      final ok = await _channel.invokeMethod<bool>('saveToDownloads', {
        'sourcePath': sourcePath,
        'fileName': fileName,
        'mimeType': mimeType,
      });
      return ok ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Absolute path of the app-private file used for the update APK
  /// (Android: external files dir / reel-checker-update.apk).
  static Future<String> updateApkPath() async {
    try {
      final path = await _channel.invokeMethod<String>('updateApkPath');
      return path ?? '';
    } catch (_) {
      return '';
    }
  }

  /// Open the Android installer on the downloaded update APK.
  /// iOS: always false (install is Android-only).
  static Future<bool> installApk() async {
    try {
      final ok = await _channel.invokeMethod<bool>('installApk');
      return ok ?? false;
    } catch (_) {
      return false;
    }
  }
}
