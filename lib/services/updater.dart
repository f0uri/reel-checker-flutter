// OTA updater + remote kill switch + device reporting — Dart port of
// the updater/control section of MainActivity.java (v2.2–v3.12).
//
// - version.json: cache-busted fetch, 10s timeouts, 2 attempts with a
//   3s gap. A newer versionCode stores the pending update and the gold
//   button is delivered to the page via onUpdateAvailable.
// - control.json: same cache-busting; disabled=true stops everyone,
//   or this device's id in blockedDevices. The merged blocked state
//   (control.json OR device store) is persisted locally so a block
//   stays in force before the first network check (fail-open if the
//   fetch fails and nothing is stored).
// - Device store: restful-api.dev object — GET + read-modify-write
//   PUT, firstSeen kept from the first report, lastSeen refreshed.
// - APK download/install is Android-only: the APK streams to the
//   app-private external files dir with real 0–100% progress, then
//   the installer is offered once via FileProvider. On iOS these
//   methods just report "not supported" to the page.

import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'instagram_service.dart';
import 'platform.dart';

class Updater {
  static const String updateUrl =
      'https://raw.githubusercontent.com/f0uri/reels_checker/main/version.json';
  static const String controlUrl =
      'https://raw.githubusercontent.com/f0uri/reels_checker/main/control.json';
  static const String deviceStoreUrl =
      'https://api.restful-api.dev/objects/ff808181a09d98f701a1af83b9a44cf3';
  static const String deviceStoreName = 'reelchecker-devices';
  static const String updateFileName = 'reel-checker-update.apk';
  static const int timeoutMs = 10000;
  static const int deviceStoreTimeoutMs = 10000;

  /// Block message (v2.7): shown on every block path. Two lines only.
  static const String blockMessage =
      'صلي على النبي ﷺ واستغفر الله.\nلقد تم حظرك من استخدام التطبيق من طرف المالك.';

  WebViewController? _controller;
  bool pageLoaded = false;

  bool controlBlocked = false;
  bool _jsonBlocked = false;
  bool _storeBlocked = false;
  bool _controlCheckRunning = false;
  int _lastControlCheckAt = 0;
  String _lastControlMessage = '';

  bool _updateCheckRunning = false;
  bool _updateShown = false;
  int _lastUpdateCheckAt = 0;
  String? pendingUpdateName;
  String? pendingUpdateApkUrl;
  String? pendingUpdateUrl;

  bool _deviceReportRunning = false;
  bool _manualCheckRunning = false;

  void attach(WebViewController controller) {
    _controller = controller;
  }

  // ================= JS callbacks =================

  Future<void> _runJs(String script) async {
    final c = _controller;
    if (c == null) return;
    try {
      await c.runJavaScript(script);
    } catch (_) {}
  }

  Future<void> _postJsonCallback(
      String fn, Map<String, dynamic> payload) async {
    final json = jsonEncode(payload);
    await _runJs('window.$fn && $fn(${jsonEncode(json)});');
  }

  Future<void> postControlResult(bool blocked, String message) async {
    await _postJsonCallback(
        'onControlResult', {'blocked': blocked, 'message': message});
  }

  Future<void> postUpdateCheckResult(Map<String, dynamic> payload) async {
    await _postJsonCallback('onUpdateCheckResult', payload);
  }

  Future<void> postUpdateResult(Map<String, dynamic> payload) async {
    await _postJsonCallback('onUpdateResult', payload);
  }

  Future<void> postDownloadProgress(int percent) async {
    await _runJs('window.onDownloadProgress && onDownloadProgress($percent);');
  }

  Future<void> deliverUpdateButton() async {
    if (controlBlocked) return;
    if (pendingUpdateName == null || pendingUpdateApkUrl == null) return;
    if (_updateShown) return;
    if (!pageLoaded) return; // sent from onPageFinished once ready
    _updateShown = true;
    final name = pendingUpdateName!;
    final apkUrl = pendingUpdateApkUrl!;
    await _runJs(
        'window.onUpdateAvailable && onUpdateAvailable(${jsonEncode(name)}, ${jsonEncode(apkUrl)});');
  }

  // ================= lifecycle =================

  /// Called from onPageFinished: deliver a stored update, check the
  /// kill switch first (a blocked app never gets the update), check
  /// for an update, and report the device.
  Future<void> onPageLoaded() async {
    pageLoaded = true;
    await deliverUpdateButton();
    await checkControl();
    await checkForUpdate();
    await reportDevice();
  }

  /// Called from app resume: re-check if the last check is over a
  /// minute old and the button was never shown / control not checked.
  Future<void> onResume() async {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (!_updateShown &&
        _lastUpdateCheckAt > 0 &&
        now - _lastUpdateCheckAt > 60000) {
      await deliverUpdateButton();
      await checkForUpdate();
    }
    if (_lastControlCheckAt > 0 && now - _lastControlCheckAt > 60000) {
      await checkControl();
      await reportDevice();
    }
  }

  /// Restore the last saved blocked state at startup, so a block
  /// stays in force from the first moment, before the network check.
  Future<void> restoreBlockedState() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      controlBlocked = prefs.getBool('control_blocked') ?? false;
      _lastControlMessage = prefs.getString('control_message') ?? '';
      _jsonBlocked = controlBlocked;
    } catch (_) {}
  }

  // ================= version.json =================

  /// Silent update check — if there is no internet or no manifest,
  /// nothing shows. One retry after 3s on failure. A blocked app
  /// does not check at all.
  Future<void> checkForUpdate() async {
    if (controlBlocked) return;
    if (_updateCheckRunning) return;
    _updateCheckRunning = true;
    _lastUpdateCheckAt = DateTime.now().millisecondsSinceEpoch;
    try {
      for (var attempt = 0; attempt < 2; attempt++) {
        if (attempt > 0) {
          await Future.delayed(const Duration(seconds: 3));
        }
        if (await _fetchUpdateManifest()) return;
      }
    } finally {
      _updateCheckRunning = false;
    }
  }

  /// Fetch the manifest once. Returns true if it was read
  /// successfully (even with no new update).
  Future<bool> _fetchUpdateManifest() async {
    final manifest = await fetchManifestJson();
    if (manifest == null) return false;
    applyManifest(manifest);
    return true;
  }

  /// One manifest request with cache-busting (?t=now + no-cache
  /// headers). Returns the parsed JSON on success, null on failure.
  Future<Map<String, dynamic>?> fetchManifestJson() async {
    try {
      final url = '$updateUrl?t=${DateTime.now().millisecondsSinceEpoch}';
      final resp = await IgHttp.get(url,
          headers: const {
            'Cache-Control': 'no-cache',
            'Pragma': 'no-cache',
          },
          connectTimeout: const Duration(milliseconds: timeoutMs),
          readTimeout: const Duration(milliseconds: timeoutMs));
      if (resp.statusCode < 200 || resp.statusCode >= 300) return null;
      return jsonDecode(resp.body) as Map<String, dynamic>;
    } catch (_) {
      // Silent: no update shows unless the manifest is available
      // and valid.
      return null;
    }
  }

  /// Read the manifest and store the update if it is newer than the
  /// installed version. Returns true if the manifest holds a newer
  /// update.
  Future<bool> applyManifest(Map<String, dynamic> manifest) async {
    final remoteCode = (manifest['versionCode'] as num?)?.toInt() ?? 0;
    final remoteName = (manifest['versionName'] as String?) ?? '';
    final apkUrl = (manifest['apkUrl'] as String?) ?? '';
    if (remoteCode <= 0 || apkUrl.isEmpty) return false;
    final currentCode = await NativePlatform.getVersionCode();
    if (remoteCode > currentCode) {
      pendingUpdateUrl = apkUrl;
      pendingUpdateApkUrl = apkUrl;
      pendingUpdateName =
          remoteName.isEmpty ? remoteCode.toString() : remoteName;
      await deliverUpdateButton();
      return true;
    }
    return false;
  }

  /// Manual check from the ⟳ button (bottom-left): same manifest
  /// fetch, result sent to the page as a toast payload
  /// (update available / latest version / check failed). A found
  /// update also shows the gold button at the same time.
  Future<void> checkUpdateManually() async {
    if (_manualCheckRunning) return;
    _manualCheckRunning = true;
    try {
      for (var attempt = 0; attempt < 2; attempt++) {
        if (attempt > 0) {
          await Future.delayed(const Duration(seconds: 3));
        }
        final manifest = await fetchManifestJson();
        if (manifest == null) continue; // failed: retry once
        final hasUpdate = await applyManifest(manifest);
        final name = (manifest['versionName'] as String?) ?? '';
        await postUpdateCheckResult(
            {'hasUpdate': hasUpdate, 'versionName': name});
        return;
      }
      await postUpdateCheckResult({'error': 'CHECK_FAILED'});
    } finally {
      _manualCheckRunning = false;
    }
  }

  // ================= control.json (kill switch) =================

  /// Remote kill-switch check: fetch control.json cache-busted and
  /// see whether the app is stopped entirely (disabled=true) or this
  /// device is in blockedDevices. The result is saved locally so the
  /// last state stays in force without internet. If the fetch fails
  /// and nothing is stored, the app works normally (fail-open — the
  /// app needs internet to work with Instagram anyway).
  Future<void> checkControl() async {
    if (_controlCheckRunning) return;
    _controlCheckRunning = true;
    _lastControlCheckAt = DateTime.now().millisecondsSinceEpoch;
    try {
      final control = await fetchControlJson();
      if (control == null) {
        // Fetch failed: use the last saved state
        final prefs = await SharedPreferences.getInstance();
        if (prefs.getBool('control_blocked') ?? false) {
          _jsonBlocked = true;
          await applyBlockedState(
              prefs.getString('control_message') ?? '');
        }
        return;
      }
      final disabled = control['disabled'] as bool? ?? false;
      final message = (control['message'] as String?) ?? '';
      var listed = false;
      final id = await NativePlatform.getDeviceId();
      if (id.isNotEmpty) {
        final blocked = control['blockedDevices'] as List?;
        if (blocked != null) {
          for (final b in blocked) {
            if (id == b) {
              listed = true;
              break;
            }
          }
        }
      }
      _jsonBlocked = disabled || listed;
      await applyBlockedState(message);
    } finally {
      _controlCheckRunning = false;
    }
  }

  /// One control.json request with cache-busting. Returns the parsed
  /// JSON on success, null on failure.
  Future<Map<String, dynamic>?> fetchControlJson() async {
    try {
      final url = '$controlUrl?t=${DateTime.now().millisecondsSinceEpoch}';
      final resp = await IgHttp.get(url,
          headers: const {
            'Cache-Control': 'no-cache',
            'Pragma': 'no-cache',
          },
          connectTimeout: const Duration(milliseconds: timeoutMs),
          readTimeout: const Duration(milliseconds: timeoutMs));
      if (resp.statusCode < 200 || resp.statusCode >= 300) return null;
      return jsonDecode(resp.body) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  /// Merge the two block sources (control.json + device store) into
  /// one effective state: controlBlocked = jsonBlocked ||
  /// storeBlocked. Persist the merged state and send it to the page
  /// (same block screen). Message: control.json's, unless the block
  /// is from the store only (then the v2.7 message). Old messages
  /// ("التطبيق متوقف حاليا…" / "تم إيقاف هذا الجهاز…" / the v2.5
  /// three-liner / the v2.6 "واو" one) are automatically replaced by
  /// the v2.7 message — even if saved locally or from an old
  /// control.json.
  Future<void> applyBlockedState(String? message) async {
    if (message != null && message.isNotEmpty) {
      _lastControlMessage = message;
    }
    final blocked = _jsonBlocked || _storeBlocked;
    controlBlocked = blocked;
    var msg = _jsonBlocked
        ? _lastControlMessage
        : (_storeBlocked ? blockMessage : _lastControlMessage);
    if (msg == 'التطبيق متوقف حاليا من طرف المالك' ||
        msg == 'تم إيقاف هذا الجهاز من طرف المالك' ||
        msg ==
            'صلي على النبي ﷺ\nاستغفر الله\nلقد تم حظرك من استخدام التطبيق من طرف المالك' ||
        (msg.contains('واو'))) {
      msg = blockMessage;
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('control_blocked', blocked);
      await prefs.setString('control_message', msg);
    } catch (_) {}
    await postControlResult(blocked, msg);
  }

  // ================= device store =================

  /// Report the device to the control-panel store + check the
  /// store's blocklist. Runs in the background, fully silent: on
  /// failure (no internet, store not answering) the app just
  /// carries on and nothing shows to the user. One retry after 3s.
  Future<void> reportDevice() async {
    if (_deviceReportRunning) return;
    final id = await NativePlatform.getDeviceId();
    if (id.isEmpty) return;
    _deviceReportRunning = true;
    try {
      for (var attempt = 0; attempt < 2; attempt++) {
        if (attempt > 0) {
          await Future.delayed(const Duration(seconds: 3));
        }
        if (await _reportDeviceOnce(id)) return;
      }
    } finally {
      _deviceReportRunning = false;
    }
  }

  /// Read the store + merge this device's record + write the whole
  /// store back. Returns true on success.
  /// Note: PUT replaces the whole object — if two devices report at
  /// the same moment, one can lose the other's record
  /// (read-modify-write). Rare with few devices; the proper fix is
  /// Supabase/Firebase with per-device keys.
  Future<bool> _reportDeviceOnce(String id) async {
    try {
      final doc = await fetchDeviceStoreDoc();
      if (doc == null) return false;
      final data = (doc['data'] as Map<String, dynamic>?) ?? {};
      final devices =
          (data['devices'] as Map<String, dynamic>?) ?? {};
      final blocked = (data['blockedDevices'] as List?) ?? [];
      // Is this device blocked from the control panel's store?
      var listed = false;
      for (final b in blocked) {
        if (id == b) {
          listed = true;
          break;
        }
      }
      _storeBlocked = listed;
      await applyBlockedState(null);
      // Merge this device's record — firstSeen kept from the first
      // report, lastSeen refreshed.
      final mine = devices[id] as Map<String, dynamic>?;
      var firstSeen = (mine?['firstSeen'] as String?) ?? '';
      if (firstSeen.isEmpty) firstSeen = _isoNow();
      final model = await NativePlatform.getDeviceModel();
      final versionName = await NativePlatform.getVersionName();
      final versionCode = await NativePlatform.getVersionCode();
      devices[id] = {
        'deviceId': id,
        'appVersion': versionName,
        'versionCode': versionCode,
        'model': model,
        'firstSeen': firstSeen,
        'lastSeen': _isoNow(),
      };
      data['devices'] = devices;
      data['blockedDevices'] = blocked;
      return await putDeviceStoreDoc({
        'name': deviceStoreName,
        'data': data,
      });
    } catch (_) {
      return false;
    }
  }

  /// One GET on the device store. Returns the whole object
  /// ({id, name, data}) or null on failure.
  Future<Map<String, dynamic>?> fetchDeviceStoreDoc() async {
    try {
      final resp = await IgHttp.get(deviceStoreUrl,
          headers: const {
            'Cache-Control': 'no-cache',
            'Pragma': 'no-cache',
          },
          connectTimeout:
              const Duration(milliseconds: deviceStoreTimeoutMs),
          readTimeout:
              const Duration(milliseconds: deviceStoreTimeoutMs));
      if (resp.statusCode < 200 || resp.statusCode >= 300) return null;
      return jsonDecode(resp.body) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  /// One PUT replacing the whole device store with the merged copy.
  /// Returns true if the server accepted (2xx).
  Future<bool> putDeviceStoreDoc(Map<String, dynamic> body) async {
    try {
      final resp = await IgHttp.put(deviceStoreUrl,
          headers: const {
            'Content-Type': 'application/json',
            'Cache-Control': 'no-cache',
          },
          body: jsonEncode(body),
          connectTimeout:
              const Duration(milliseconds: deviceStoreTimeoutMs),
          readTimeout:
              const Duration(milliseconds: deviceStoreTimeoutMs));
      return resp.statusCode >= 200 && resp.statusCode < 300;
    } catch (_) {
      return false;
    }
  }

  /// Current time as ISO 8601 UTC — e.g. "2026-11-06T06:20:00Z".
  String _isoNow() {
    final now = DateTime.now().toUtc();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${now.year}-${two(now.month)}-${two(now.day)}'
        'T${two(now.hour)}:${two(now.minute)}:${two(now.second)}Z';
  }

  // ================= APK download / install (Android-only) =================

  /// In-app update download (not DownloadManager) so the real
  /// download percentage shows on the button: streamed HTTP with
  /// Content-Length. When done, the installer opens once directly,
  /// and the button stays "تثبيت التحديث" if the user closes it.
  /// On iOS this just reports "not supported" to the page.
  Future<void> downloadUpdate(String? apkUrl) async {
    if (!Platform.isAndroid) {
      await postUpdateResult({'ok': false, 'error': 'UPDATE_UNSUPPORTED'});
      return;
    }
    final url = (apkUrl == null || apkUrl.trim().isEmpty)
        ? pendingUpdateUrl
        : apkUrl.trim();
    if (url == null ||
        url.isEmpty ||
        !(url.startsWith('http://') || url.startsWith('https://'))) {
      await postUpdateResult({'ok': false, 'error': 'UPDATE_NET'});
      return;
    }
    var failKind = 'NET';
    File? outFile;
    http.Client? client;
    try {
      final path = await NativePlatform.updateApkPath();
      if (path.isEmpty) throw Exception('NO_PATH');
      outFile = File(path);
      await outFile.parent.create(recursive: true);
      client = http.Client();
      final req = http.Request('GET', Uri.parse(url));
      req.headers['User-Agent'] = InstagramService.userAgents[0];
      final resp = await client
          .send(req)
          .timeout(const Duration(seconds: 30));
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        failKind = 'HTTP';
        throw Exception('HTTP ${resp.statusCode}');
      }
      failKind = 'WRITE';
      final total = resp.contentLength ?? -1; // -1 if size unknown
      var indeterminateSent = false;
      var downloaded = 0;
      var lastPercent = -1;
      final sink = outFile.openWrite();
      await for (final chunk in resp.stream
          .timeout(const Duration(seconds: 60))) {
        sink.add(chunk);
        downloaded += chunk.length;
        if (total > 0) {
          var pct = downloaded * 100 ~/ total;
          if (pct > 100) pct = 100;
          if (pct != lastPercent) {
            lastPercent = pct;
            await postDownloadProgress(pct);
          }
        } else if (!indeterminateSent) {
          indeterminateSent = true;
          await postDownloadProgress(-1); // no percentage — never invent one
        }
      }
      await sink.close();
      if (downloaded < 1024 * 100) {
        failKind = 'SMALL';
        throw Exception('FILE_TOO_SMALL');
      }
      await postDownloadProgress(100);
      await postUpdateResult(
          {'ok': true, 'state': 'downloaded', 'size': downloaded});
      await installUpdateApk(); // the installer opens once directly
    } catch (_) {
      if (outFile != null) {
        await outFile.delete().catchError((_) => outFile!);
      }
      await postDownloadProgress(-2); // failure signal to the page
      await postUpdateResult({'ok': false, 'error': 'UPDATE_$failKind'});
    } finally {
      client?.close();
    }
  }

  /// Open the Android installer on the downloaded APK via
  /// FileProvider. On iOS: reports "not supported".
  Future<void> installUpdate() async {
    await installUpdateApk();
  }

  Future<void> installUpdateApk() async {
    if (!Platform.isAndroid) {
      await postUpdateResult({'ok': false, 'error': 'UPDATE_UNSUPPORTED'});
      return;
    }
    try {
      final path = await NativePlatform.updateApkPath();
      final apk = File(path);
      if (path.isEmpty || !await apk.exists()) {
        await postUpdateResult({'ok': false, 'error': 'UPDATE_INSTALL'});
        return;
      }
      final ok = await NativePlatform.installApk();
      if (!ok) {
        await postUpdateResult({'ok': false, 'error': 'UPDATE_INSTALL'});
      }
    } catch (_) {
      await postUpdateResult({'ok': false, 'error': 'UPDATE_INSTALL'});
    }
  }
}
