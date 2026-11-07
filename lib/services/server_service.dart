// Server-first extraction (v4.2.0).
//
// Why this exists: the platforms fight anonymous in-app extraction —
// YouTube locks every InnerTube client without a session, Instagram
// rate-limits anonymous requests (429), TikTok blocks datacenter IPs.
// The user's own downloader server (yt-dlp, proven working for
// YouTube 1080p/2160p and Instagram direct mp4) does the hard work;
// the app only has to ask it.
//
// The server address lives in a tiny public config file so switching
// it on needs NO app rebuild: update server.json in reels_checker
// and every user's app picks the server up on its next check.
// While serverUrl is empty the app behaves exactly as before
// (in-app extraction only). Any server failure also falls back
// silently to the in-app extractors — the server never makes
// anything worse.

import 'dart:convert';

import 'package:http/http.dart' as http;

class ServerService {
  static const String _configUrl =
      'https://raw.githubusercontent.com/f0uri/reels_checker/main/server.json';

  static String? _serverUrl;
  static String? _apiKey;
  static int _loadedAt = 0;
  static bool _loading = false;

  /// Load server.json (5 s timeout), re-reading it when over 60 s
  /// old. Never throws. The old once-per-process load kept a stale
  /// empty config forever when server.json was filled while the app
  /// was already running — a restart was the only cure. Now every
  /// check picks a changed server up within a minute, no restart.
  static Future<void> ensureLoaded() async {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (_loading) return;
    if (_loadedAt > 0 && now - _loadedAt < 60000) return;
    _loading = true;
    try {
      final resp = await http
          .get(Uri.parse('$_configUrl?x=$now'))
          .timeout(const Duration(seconds: 5));
      if (resp.statusCode == 200) {
        final cfg = jsonDecode(resp.body) as Map<String, dynamic>;
        final u = (cfg['serverUrl'] as String?)?.trim() ?? '';
        final k = (cfg['apiKey'] as String?)?.trim() ?? '';
        if (u.startsWith('http://') || u.startsWith('https://')) {
          _serverUrl = u.replaceAll(RegExp(r'/+$'), '');
          _apiKey = k.isEmpty ? null : k;
        } else {
          _serverUrl = null;
          _apiKey = null;
        }
      }
    } catch (_) {
      // No config / no network: stay in-app only.
    } finally {
      _loading = false;
      _loadedAt = DateTime.now().millisecondsSinceEpoch;
    }
  }

  static bool get isConfigured => _serverUrl != null;

  /// Ask the server to parse [url]. Returns the app's standard meta
  /// map on success, null on ANY failure (caller falls back to the
  /// in-app extractors). Never throws.
  static Future<Map<String, dynamic>?> parseMedia(String url) async {
    final base = _serverUrl;
    if (base == null) return null;
    try {
      final resp = await http
          .post(
            Uri.parse('$base/api/parse'),
            headers: {
              'Content-Type': 'application/json',
              if (_apiKey != null) 'X-API-Key': _apiKey!,
            },
            body: jsonEncode({'url': url}),
          )
          .timeout(const Duration(seconds: 90));
      if (resp.statusCode != 200) return null;
      final data = jsonDecode(resp.body) as Map<String, dynamic>;
      if (data['ok'] != true) return null;
      final bestUrl = (data['bestUrl'] as String?) ?? '';
      if (bestUrl.isEmpty) return null;
      final platform = (data['platform'] as String?) ?? 'video';
      final id = (data['id'] as String?) ?? '';
      final meta = <String, dynamic>{
        'ok': true,
        'platform': platform,
        'title': (data['title'] as String?) ?? '',
        'thumbnail': (data['thumbnail'] as String?) ?? '',
        'videoUrl': bestUrl,
        'mediaType': 'video',
        'uploader': (data['uploader'] as String?) ?? '',
        'duration': data['duration'],
        'qualityLabel': (data['bestLabel'] as String?) ?? '',
        'viaServer': true,
      };
      if (platform == 'instagram') meta['shortcode'] = id;
      if (platform == 'youtube') meta['videoId'] = id;
      return meta;
    } catch (_) {
      return null;
    }
  }
}
