// v4.4.6: license check — the app asks the user's own SnapDeploy
// server on launch (and before each reel check when the cached
// verdict is stale) whether this device may use the servers. The
// server checks the CI-injected app secret (a build from cloned
// source has an empty secret) plus the device allowlist, so the
// owner can revoke a single device even after the APK leaked.
//
// Design notes:
// - The license endpoint lives on the SnapDeploy server, NOT on the
//   parse backend in server.json (Lovable, which cannot be edited).
//   The gate is enforced in the app, so it covers every backend.
// - The verdict is cached (licensed: 7 days, refused: 24 h). When
//   the server cannot be reached (asleep container, offline) the
//   app uses the cache, and allows once when there is no verdict
//   yet — a sleeping server must never brick the genuine app.
// - A device with no ID (iOS) cannot be checked and is allowed.

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'platform.dart';

class LicenseService {
  static const String _licenseUrl =
      'https://downloader-server-946e7.containers.snapdeploy.app/api/license';

  /// Injected by CI from the GitHub Secret REELCHECKER_APP_SECRET
  /// (--dart-define). Empty in any build from cloned source.
  static const String _appSecret =
      String.fromEnvironment('APP_SECRET', defaultValue: '');

  static const String _kLicensed = 'license_ok';
  static const String _kLicensedAt = 'license_ok_at';
  static const Duration _licensedTtl = Duration(days: 7);
  static const Duration _refusedTtl = Duration(hours: 24);

  static bool? _cachedOk;
  static int _cachedAt = 0;

  /// Ask the license server now. True = licensed, false = refused,
  /// null = server could not be reached (no verdict stored).
  static Future<bool?> refresh() async {
    try {
      final deviceId = await NativePlatform.getDeviceId();
      if (deviceId.isEmpty) return true;
      final resp = await http
          .post(
            Uri.parse(_licenseUrl),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(
                {'device_id': deviceId, 'app_secret': _appSecret}),
          )
          .timeout(const Duration(seconds: 10));
      if (resp.statusCode != 200) return null;
      final data = jsonDecode(resp.body) as Map<String, dynamic>;
      final ok = data['licensed'] == true;
      await _store(ok);
      return ok;
    } catch (_) {
      return null;
    }
  }

  static Future<void> _store(bool ok) async {
    _cachedOk = ok;
    _cachedAt = DateTime.now().millisecondsSinceEpoch;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kLicensed, ok);
      await prefs.setInt(_kLicensedAt, _cachedAt);
    } catch (_) {}
  }

  static Future<(bool, Duration)?> _readCache() async {
    if (_cachedOk != null) {
      final age = DateTime.now().millisecondsSinceEpoch - _cachedAt;
      return (_cachedOk!, Duration(milliseconds: age));
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      final ok = prefs.getBool(_kLicensed);
      final at = prefs.getInt(_kLicensedAt) ?? 0;
      if (ok == null || at == 0) return null;
      _cachedOk = ok;
      _cachedAt = at;
      final age = DateTime.now().millisecondsSinceEpoch - at;
      return (ok, Duration(milliseconds: age));
    } catch (_) {
      return null;
    }
  }

  /// Whether this device may use the servers right now. Uses the
  /// cached verdict when fresh; otherwise asks the server; when the
  /// server cannot be reached, falls back to any cached verdict and
  /// allows once when there is none yet.
  static Future<bool> isAllowed() async {
    final cached = await _readCache();
    if (cached != null) {
      final (ok, age) = cached;
      if (ok && age < _licensedTtl) return true;
      if (!ok && age < _refusedTtl) return false;
    }
    final fresh = await refresh();
    if (fresh != null) return fresh;
    if (cached != null) return cached.$1;
    return true;
  }
}
