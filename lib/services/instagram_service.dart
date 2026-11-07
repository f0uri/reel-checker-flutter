// Instagram fetch engine — faithful Dart port of the Android app's
// MainActivity.java engine (anonymous, no account, no session cookies).
// Same endpoints, headers, UA rotation, attempt order and timeouts.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

class ReelException implements Exception {
  final String code;
  ReelException(this.code);
  @override
  String toString() => 'ReelException($code)';
}

class AccountException implements Exception {
  final String code;
  AccountException(this.code);
  @override
  String toString() => 'AccountException($code)';
}

/// Minimal HTTP response (multi-value headers, final URL after redirects).
class IgResponse {
  final int statusCode;
  final Map<String, List<String>> headers;
  final String body;
  final Uri finalUri;
  final String contentType;
  IgResponse(this.statusCode, this.headers, this.body, this.finalUri,
      this.contentType);
}

/// Thin wrapper over dart:io HttpClient with explicit redirect control,
/// per-request timeouts and multi-value header access.
class IgHttp {
  static Future<IgResponse> get(
    String url, {
    Map<String, String> headers = const {},
    Duration connectTimeout = const Duration(seconds: 15),
    Duration readTimeout = const Duration(seconds: 15),
    bool followRedirects = true,
  }) async {
    return _request('GET', url,
        headers: headers,
        connectTimeout: connectTimeout,
        readTimeout: readTimeout,
        followRedirects: followRedirects);
  }

  static Future<IgResponse> post(
    String url, {
    Map<String, String> headers = const {},
    String body = '',
    Duration connectTimeout = const Duration(seconds: 8),
    Duration readTimeout = const Duration(seconds: 12),
  }) async {
    return _request('POST', url,
        headers: headers,
        body: body,
        connectTimeout: connectTimeout,
        readTimeout: readTimeout);
  }

  static Future<IgResponse> put(
    String url, {
    Map<String, String> headers = const {},
    String body = '',
    Duration connectTimeout = const Duration(seconds: 10),
    Duration readTimeout = const Duration(seconds: 10),
  }) async {
    return _request('PUT', url,
        headers: headers,
        body: body,
        connectTimeout: connectTimeout,
        readTimeout: readTimeout);
  }

  static Future<IgResponse> _request(
    String method,
    String url, {
    Map<String, String> headers = const {},
    String? body,
    Duration connectTimeout = const Duration(seconds: 15),
    Duration readTimeout = const Duration(seconds: 15),
    bool followRedirects = true,
  }) async {
    final client = HttpClient();
    client.connectionTimeout = connectTimeout;
    try {
      var current = Uri.parse(url);
      for (var hop = 0; hop <= 5; hop++) {
        final req = await client.openUrl(method, current);
        req.followRedirects = followRedirects;
        headers.forEach(req.headers.set);
        if (body != null) {
          final bytes = utf8.encode(body);
          req.headers.set(HttpHeaders.contentLengthHeader, bytes.length);
          req.add(bytes);
        }
        final resp = await req.close();
        final finalUri = resp.redirects.isEmpty
            ? current
            : resp.redirects.last.location;
        final status = resp.statusCode;
        if (!followRedirects &&
            (status == 301 ||
                status == 302 ||
                status == 303 ||
                status == 307 ||
                status == 308)) {
          final loc = resp.headers.value(HttpHeaders.locationHeader);
          if (loc == null || loc.isEmpty || hop == 5) {
            final text = await resp
                .transform(utf8.decoder)
                .join()
                .timeout(readTimeout);
            return _toResponse(status, resp, text, finalUri);
          }
          current = current.resolve(loc);
          continue;
        }
        final text =
            await resp.transform(utf8.decoder).join().timeout(readTimeout);
        return _toResponse(status, resp, text, finalUri);
      }
      throw const HttpException('REDIRECT_FAILED');
    } finally {
      client.close();
    }
  }

  static IgResponse _toResponse(
      int status, HttpClientResponse resp, String text, Uri finalUri) {
    final map = <String, List<String>>{};
    resp.headers.forEach((name, values) {
      map[name.toLowerCase()] = values;
    });
    return IgResponse(status, map, text, finalUri,
        resp.headers.contentType?.toString() ?? '');
  }
}

// ================= Anonymous warmup (no account) =================
// Before asking Instagram, fetch anonymous cookies (csrftoken / mid /
// ig_did) from the home page + /data/shared_data/ — exactly like a
// browser. These are NOT an account session: no user identity in them,
// so plain SharedPreferences storage is enough. Fresh for 6 hours.

class IgAnonWarmup {
  static const _keyCsrf = 'csrf';
  static const _keyMid = 'mid';
  static const _keyDid = 'did';
  static const _keyUa = 'ua';
  static const _keyT = 't';

  static String _warmCsrf = '';
  static String _warmMid = '';
  static String _warmDid = '';
  static int _warmAt = 0;
  static int _lastAttemptAt = 0;

  static String cookieHeader() {
    final parts = <String>[];
    if (_warmCsrf.isNotEmpty) parts.add('csrftoken=$_warmCsrf');
    if (_warmMid.isNotEmpty) parts.add('mid=$_warmMid');
    if (_warmDid.isNotEmpty) parts.add('ig_did=$_warmDid');
    return parts.join('; ');
  }

  static String csrfToken() => _warmCsrf;

  static Future<void> ensureWarmup() async {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (_warmAt > 0 &&
        now - _warmAt < InstagramService.warmupMaxAgeMs &&
        _warmCsrf.isNotEmpty) {
      return;
    }
    if (now - _lastAttemptAt < 5 * 60 * 1000) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final t = prefs.getInt(_keyT) ?? 0;
      final csrf = prefs.getString(_keyCsrf) ?? '';
      if (t > 0 &&
          now - t < InstagramService.warmupMaxAgeMs &&
          csrf.isNotEmpty) {
        _warmCsrf = csrf;
        _warmMid = prefs.getString(_keyMid) ?? '';
        _warmDid = prefs.getString(_keyDid) ?? '';
        _warmAt = t;
        return;
      }
    } catch (_) {}
    await _doWarmupLocked();
  }

  /// Clear old cookies and warm up fresh (on 401/403/429) — one attempt.
  /// Network warmup at most once a minute app-wide: if less than a
  /// minute passed since the last attempt, old cookies are just cleared
  /// and the fetch continues without them.
  static Future<void> rewarmup() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.clear();
    } catch (_) {}
    _warmCsrf = '';
    _warmMid = '';
    _warmDid = '';
    _warmAt = 0;
    if (DateTime.now().millisecondsSinceEpoch - _lastAttemptAt <
        InstagramService.rewarmMinGapMs) {
      return;
    }
    _lastAttemptAt = 0;
    await ensureWarmup();
  }

  static Future<void> _doWarmupLocked() async {
    _lastAttemptAt = DateTime.now().millisecondsSinceEpoch;
    final ua = InstagramService.userAgents[
        Random().nextInt(InstagramService.userAgents.length)];
    await _warmupGet('https://www.instagram.com/', ua);
    await _warmupGet('https://www.instagram.com/data/shared_data/', ua);
    if (_warmCsrf.isNotEmpty) {
      _warmAt = DateTime.now().millisecondsSinceEpoch;
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(_keyCsrf, _warmCsrf);
        await prefs.setString(_keyMid, _warmMid);
        await prefs.setString(_keyDid, _warmDid);
        await prefs.setString(_keyUa, ua);
        await prefs.setInt(_keyT, _warmAt);
      } catch (_) {}
    }
  }

  /// One GET with manual redirect following (up to 4 hops) so
  /// Set-Cookie headers from every hop are collected.
  static Future<void> _warmupGet(String urlStr, String ua) async {
    var url = urlStr;
    for (var hop = 0; hop < 4; hop++) {
      try {
        final resp = await IgHttp.get(url,
            headers: {
              'User-Agent': ua,
              'Accept-Language': 'en-US,en;q=0.9',
              'Accept': '*/*',
            },
            connectTimeout:
                const Duration(milliseconds: InstagramService.timeoutMs),
            readTimeout:
                const Duration(milliseconds: InstagramService.timeoutMs),
            followRedirects: false);
        _collectCookies(resp);
        final code = resp.statusCode;
        if (code >= 300 && code < 400) {
          final loc = resp.headers['location']?.firstOrNull ?? '';
          if (loc.isEmpty) return;
          url = loc.startsWith('/')
              ? 'https://www.instagram.com$loc'
              : loc;
          continue;
        }
        return;
      } catch (_) {
        return;
      }
    }
  }

  static void _collectCookies(IgResponse resp) {
    final setCookies = resp.headers['set-cookie'];
    if (setCookies == null) return;
    for (final sc in setCookies) {
      final nv = sc.split(';')[0].trim();
      final eq = nv.indexOf('=');
      if (eq <= 0) continue;
      final name = nv.substring(0, eq).trim();
      final value = nv.substring(eq + 1).trim();
      if (value.isEmpty) continue;
      if (name == 'csrftoken') {
        _warmCsrf = value;
      } else if (name == 'mid') {
        _warmMid = value;
      } else if (name == 'ig_did') {
        _warmDid = value;
      }
    }
  }
}

class InstagramService {
  // ---- constants (same values as the Android engine) ----
  static const List<String> userAgents = [
    'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15',
    'Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)',
    'curl/8.4.0',
  ];
  static const String iphoneUa =
      'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1';
  static const String igAppId = '936619743392459';
  static const String igGraphqlDocId = '8845758582119845';
  static const String igAsbdId = '129477';
  static const int warmupMaxAgeMs = 6 * 3600 * 1000;
  static const int timeoutMs = 15000;
  static const int imgConnectTimeoutMs = 8000;
  static const int imgReadTimeoutMs = 12000;
  static const int reelConnectTimeoutMs = 8000;
  static const int reelReadTimeoutMs = 12000;
  static const int rewarmMinGapMs = 60000;
  static const int maxDuration = 180;

  // ================= header helpers =================

  static bool _isIgWebHost(String urlStr) {
    try {
      final host = Uri.parse(urlStr).host.toLowerCase();
      return host == 'instagram.com' || host.endsWith('.instagram.com');
    } catch (_) {
      return false;
    }
  }

  static bool _isIgAuthHost(String urlStr) {
    try {
      final host = Uri.parse(urlStr).host.toLowerCase();
      return host == 'instagram.com' ||
          host.endsWith('.instagram.com') ||
          host.endsWith('.cdninstagram.com') ||
          host.endsWith('.fbcdn.net');
    } catch (_) {
      return false;
    }
  }

  static Map<String, String> _apiHeaders(String referer) {
    final h = <String, String>{
      'X-IG-App-ID': igAppId,
      'X-Requested-With': 'XMLHttpRequest',
      'X-ASBD-ID': igAsbdId,
      'Referer': referer,
      'Origin': 'https://www.instagram.com',
    };
    final csrf = IgAnonWarmup.csrfToken();
    if (csrf.isNotEmpty) h['X-CSRFToken'] = csrf;
    return h;
  }

  /// User-Agent + anonymous warmup cookies (Instagram hosts only —
  /// never sent to any other host). The app is fully anonymous: no
  /// account session cookie ever exists.
  static Map<String, String> _igHeaders(String urlStr, String ua) {
    final h = <String, String>{'User-Agent': ua};
    if (!_isIgAuthHost(urlStr)) return h;
    if (_isIgWebHost(urlStr)) {
      final wc = IgAnonWarmup.cookieHeader();
      if (wc.isNotEmpty) h['Cookie'] = wc;
    }
    return h;
  }

  static bool _isLoginRedirect(IgResponse resp) {
    try {
      final p = resp.finalUri.path;
      if (p.contains('/accounts/login')) return true;
    } catch (_) {}
    return resp.statusCode == 401;
  }

  static Future<void> _sleepQuietly(int ms) async {
    try {
      await Future<void>.delayed(Duration(milliseconds: ms));
    } catch (_) {}
  }

  // ================= text helpers =================

  static String? pick(String text, String pattern, {bool dotAll = false}) {
    final m = RegExp(pattern, dotAll: dotAll).firstMatch(text);
    return m?.group(1);
  }

  static String pickNum(String text, String pattern) {
    return pick(text, pattern) ?? '0';
  }

  /// Decode HTML entities (&#064; = @, &amp; = &, &#x2022; = •, ...).
  /// Code points above 0xFFFF (emoji, fancy letters) keep their full
  /// surrogate pair — a plain char cast would corrupt them.
  static String htmlUnescape(String? s) {
    if (s == null) return '';
    var out = s
        .replaceAll('&amp;', '&')
        .replaceAll('&quot;', '"')
        .replaceAll('&#039;', "'")
        .replaceAll('&apos;', "'")
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&nbsp;', ' ');
    out = out.replaceAllMapped(RegExp(r'&#(\d+);'), (m) {
      final cp = int.tryParse(m.group(1) ?? '') ?? -1;
      if (cp < 0 || cp > 0x10FFFF) return '';
      return String.fromCharCode(cp);
    });
    out = out.replaceAllMapped(RegExp(r'&#x([0-9a-fA-F]+);'), (m) {
      final cp = int.tryParse(m.group(1) ?? '', radix: 16) ?? -1;
      if (cp < 0 || cp > 0x10FFFF) return '';
      return String.fromCharCode(cp);
    });
    return out.trim();
  }

  /// "686M" / "32K" / "8,636" -> approximate number.
  static int parseCount(String? s) {
    if (s == null) return 0;
    final v = s.trim().replaceAll(',', '').replaceAll(' ', '');
    try {
      if (v.endsWith('B')) {
        return (double.parse(v.substring(0, v.length - 1)) * 1000000000)
            .toInt();
      }
      if (v.endsWith('M')) {
        return (double.parse(v.substring(0, v.length - 1)) * 1000000).toInt();
      }
      if (v.endsWith('K')) {
        return (double.parse(v.substring(0, v.length - 1)) * 1000).toInt();
      }
      return int.parse(v);
    } catch (_) {
      return 0;
    }
  }

  /// Clean a search input: accepts @user, a profile link or a plain name.
  static String? cleanUsername(String? raw) {
    if (raw == null) return null;
    var v = raw.trim();
    if (v.isEmpty) return null;
    v = v.replaceAll(
        RegExp(r'^https?://(www\.)?instagram\.com/', caseSensitive: false),
        '');
    v = v.replaceAll(RegExp(r'/.*$'), '');
    v = v.replaceAll(RegExp(r'^@'), '');
    v = v.trim();
    if (!RegExp(r'^[A-Za-z0-9._]{1,30}$').hasMatch(v)) return null;
    if (v.startsWith('.') || v.endsWith('.') || v.contains('..')) {
      return null;
    }
    return v;
  }

  /// Extract a reel shortcode from shared text — a bare link or a link
  /// inside longer text (as it comes from Instagram's share sheet).
  static String? extractShortcodeFromText(String? text) {
    if (text == null) return null;
    final value = text.trim();
    if (value.isEmpty) return null;
    if (RegExp(r'^[A-Za-z0-9_-]{6,20}$').hasMatch(value)) return value;
    var m = RegExp(
            r'instagram\.com/(?:reels?|p|tv)/([A-Za-z0-9_-]{6,20})',
            caseSensitive: false)
        .firstMatch(value);
    if (m != null) return m.group(1);
    final s = RegExp(r'instagr\.am/p/([A-Za-z0-9_-]{6,20})',
            caseSensitive: false)
        .firstMatch(value);
    if (s != null) return s.group(1);
    return null;
  }

  /// Unescape a JSON string embedded in a JS string (up to 4 passes).
  static String deepUnescape(String raw) {
    var text = raw;
    var previous = '';
    var guard = 0;
    while (text != previous && guard < 4) {
      previous = text;
      text = _unescapeOnce(text);
      guard++;
    }
    return text;
  }

  static String _unescapeOnce(String text) {
    var out = text.replaceAllMapped(RegExp(r'\\u([0-9a-fA-F]{4})'), (m) {
      final cp = int.tryParse(m.group(1) ?? '', radix: 16) ?? 0;
      return String.fromCharCode(cp);
    });
    out = out.replaceAll(r'\/', '/').replaceAll(r'\"', '"');
    return out;
  }

  /// Clean text with several layers of escaping.
  static String cleanText(String? raw) {
    if (raw == null) return '';
    var out = raw
        .replaceAll(RegExp(r'\\+n'), ' ')
        .replaceAll(RegExp(r'\\+r'), ' ');
    for (var i = 0; i < 6; i++) {
      out = _unescapeOnce(out).replaceAllMapped(RegExp(r'\\(.)'), (m) {
        return m.group(1) ?? '';
      });
    }
    return out.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  // ================= reel engine =================

  /// Read a full HTML page — one retry on blocks (429/403) after a 2s
  /// pause. An auth barrier (401/redirect) is treated like a block:
  /// fresh warmup + one more anonymous attempt.
  static Future<String> fetchHtml(String urlStr, String ua, int timeoutMs,
      {int connectMs = -1,
      int readMs = -1,
      int maxAttempts = 2}) async {
    final cMs = connectMs < 0 ? timeoutMs : connectMs;
    final rMs = readMs < 0 ? timeoutMs : readMs;
    await IgAnonWarmup.ensureWarmup();
    var lastError = 'INSTAGRAM_ERROR';
    var rewarmed = false;
    for (var attempt = 0; attempt < maxAttempts; attempt++) {
      if (attempt > 0) await _sleepQuietly(2000);
      try {
        final resp = await IgHttp.get(urlStr,
            headers: {
              ..._igHeaders(urlStr, ua),
              'Accept': 'text/html,application/xhtml+xml,application/json',
            },
            connectTimeout: Duration(milliseconds: cMs),
            readTimeout: Duration(milliseconds: rMs));
        if (_isLoginRedirect(resp)) {
          if (!rewarmed) {
            rewarmed = true;
            await IgAnonWarmup.rewarmup();
          }
          lastError = 'INSTAGRAM_BLOCKED';
          continue;
        }
        final code = resp.statusCode;
        if (code == 401) {
          if (!rewarmed) {
            rewarmed = true;
            await IgAnonWarmup.rewarmup();
          }
          lastError = 'INSTAGRAM_BLOCKED';
          continue;
        }
        if (code == 429 || code == 403) {
          if (!rewarmed) {
            rewarmed = true;
            await IgAnonWarmup.rewarmup();
          }
          lastError = 'INSTAGRAM_BLOCKED';
          continue;
        }
        if (code == 404) throw AccountException('ACCOUNT_NOT_FOUND');
        if (code < 200 || code >= 300) {
          lastError = 'INSTAGRAM_ERROR';
          continue;
        }
        return resp.body;
      } on AccountException {
        rethrow;
      } on TimeoutException {
        lastError = 'INSTAGRAM_TIMEOUT';
      } catch (_) {
        lastError = 'INSTAGRAM_UNREACHABLE';
      }
    }
    throw AccountException(lastError);
  }

  /// One attempt at a reel embed page: returns the HTML if it contains
  /// video_url, or a photo page (display_url) for parseReelMeta to
  /// decide (photo / carousel / not a post). Throws ReelException with
  /// the exact reason on failure.
  static Future<String> fetchEmbedOnce(
      String path, String ua, int connectMs, int readMs) async {
    final urlStr = 'https://www.instagram.com/$path/';
    try {
      final resp = await IgHttp.get(urlStr,
          headers: {
            ..._igHeaders(urlStr, ua),
            'Accept': 'text/html,application/xhtml+xml',
          },
          connectTimeout: Duration(milliseconds: connectMs),
          readTimeout: Duration(milliseconds: readMs));
      if (_isLoginRedirect(resp)) throw ReelException('INSTAGRAM_BLOCKED');
      final code = resp.statusCode;
      if (code == 401) throw ReelException('INSTAGRAM_BLOCKED');
      if (code == 404) throw ReelException('REEL_NOT_FOUND');
      if (code == 429 || code == 403) {
        throw ReelException('INSTAGRAM_BLOCKED');
      }
      if (code < 200 || code >= 300) throw ReelException('INSTAGRAM_ERROR');
      final html = resp.body;
      if (html.contains('video_url')) return html;
      if (html.contains('"display_url"')) return html;
      if (html.contains('/accounts/login') ||
          html.contains('login_required') ||
          html.contains('checkpoint')) {
        throw ReelException('INSTAGRAM_BLOCKED');
      }
      throw ReelException('REEL_NOT_FOUND');
    } on ReelException {
      rethrow;
    } on TimeoutException {
      throw ReelException('INSTAGRAM_TIMEOUT');
    } catch (_) {
      throw ReelException('INSTAGRAM_UNREACHABLE');
    }
  }

  /// Try several User-Agents and paths until the reel JSON is found.
  /// 5 attempts, no sleeps between them. Order: reel path first with
  /// every UA — the p path returns the exact same page for the same
  /// code. One p attempt stays last as a fallback.
  static Future<String> fetchEmbedHtml(String shortcode) async {
    await IgAnonWarmup.ensureWarmup();
    var lastError = 'INSTAGRAM_ERROR';
    var rewarmed = false;
    final attempts = [
      ['reel/$shortcode/embed/captioned', userAgents[0]],
      ['reel/$shortcode/embed/captioned', userAgents[1]],
      ['reel/$shortcode/embed/captioned', userAgents[2]],
      ['reel/$shortcode/embed', userAgents[0]],
      ['p/$shortcode/embed/captioned', userAgents[0]],
    ];
    for (final a in attempts) {
      try {
        return await fetchEmbedOnce(
            a[0], a[1], reelConnectTimeoutMs, reelReadTimeoutMs);
      } on ReelException catch (e) {
        if (e.code == 'NOT_A_VIDEO') rethrow;
        lastError = e.code;
        if (lastError == 'INSTAGRAM_BLOCKED' && !rewarmed) {
          rewarmed = true;
          await IgAnonWarmup.rewarmup();
        }
      }
    }
    throw ReelException(lastError);
  }

  /// Fallback: GraphQL xdt_shortcode_media (doc_id from ig_anon).
  /// Returns a result in the same shape as parseReelMeta, or null on
  /// failure. Stays in place (after embed, before the p/ page).
  static Future<Map<String, dynamic>?> fetchReelGraphQL(
      String shortcode) async {
    await IgAnonWarmup.ensureWarmup();
    try {
      final variables = jsonEncode({
        'shortcode': shortcode,
        'fetch_tagged_user_count': null,
        'hoisted_comment_id': null,
        'hoisted_reply_id': null,
      });
      final body =
          'variables=${Uri.encodeComponent(variables)}&doc_id=$igGraphqlDocId';
      final resp = await IgHttp.post('https://www.instagram.com/graphql/query',
          headers: {
            ..._igHeaders('https://www.instagram.com/graphql/query',
                userAgents[0]),
            ..._apiHeaders('https://www.instagram.com/reel/$shortcode/'),
            'Content-Type': 'application/x-www-form-urlencoded',
            'Accept': 'application/json',
          },
          body: body,
          connectTimeout:
              const Duration(milliseconds: reelConnectTimeoutMs),
          readTimeout: const Duration(milliseconds: reelReadTimeoutMs));
      if (_isLoginRedirect(resp)) return null;
      if (resp.statusCode != 200) return null;
      final root = jsonDecode(resp.body) as Map<String, dynamic>;
      final data = root['data'] as Map<String, dynamic>?;
      final m = data?['xdt_shortcode_media'] as Map<String, dynamic>?;
      if (m == null) return null;
      final videoUrl = (m['video_url'] as String?) ?? '';
      if (videoUrl.isEmpty) {
        final imgs = <String>[];
        final sidecar =
            m['edge_sidecar_to_children'] as Map<String, dynamic>?;
        final sedges = sidecar?['edges'] as List?;
        if (sedges != null) {
          for (var i = 0; i < sedges.length && imgs.length < 10; i++) {
            final snode = sedges[i] as Map<String, dynamic>?;
            final u = bestImageFromNode(
                snode?['node'] as Map<String, dynamic>?);
            if (u.isNotEmpty) imgs.add(u);
          }
        }
        if (imgs.isEmpty) {
          final u = bestImageFromNode(m);
          if (u.isNotEmpty) imgs.add(u);
        }
        if (imgs.isEmpty) return null;
        var thumbUrl = (m['display_url'] as String?) ?? '';
        if (thumbUrl.isEmpty) thumbUrl = imgs[0];
        final dims = m['dimensions'] as Map<String, dynamic>?;
        final height = (dims?['height'] as num?)?.toInt() ?? 0;
        final width = (dims?['width'] as num?)?.toInt() ?? 0;
        final owner = m['owner'] as Map<String, dynamic>?;
        final author = (owner?['username'] as String?) ?? '';
        return {
          'ok': true,
          'shortcode': shortcode,
          'mediaType': imgs.length > 1 ? 'carousel' : 'image',
          'videoUrl': '',
          'imageUrls': imgs,
          'thumbUrl': thumbUrl,
          'duration': 0,
          'width': width == 0 ? 9 : width,
          'height': height == 0 ? 16 : height,
          'author': cleanText(author),
          'caption': '',
          'viewCount': 0,
          'permalink': 'https://www.instagram.com/p/$shortcode/',
        };
      }
      final duration = (m['video_duration'] as num?)?.toDouble() ?? 0;
      if (duration > maxDuration) throw ReelException('REEL_TOO_LONG');
      final thumbUrl = (m['display_url'] as String?) ?? '';
      final dims = m['dimensions'] as Map<String, dynamic>?;
      final height = (dims?['height'] as num?)?.toInt() ?? 0;
      final width = (dims?['width'] as num?)?.toInt() ?? 0;
      final owner = m['owner'] as Map<String, dynamic>?;
      final author = (owner?['username'] as String?) ?? '';
      var caption = '';
      final capEdges = m['edge_media_to_caption'] as Map<String, dynamic>?;
      final edges = capEdges?['edges'] as List?;
      if (edges != null && edges.isNotEmpty) {
        final edge0 = edges[0] as Map<String, dynamic>?;
        final node = edge0?['node'] as Map<String, dynamic>?;
        if (node != null) caption = (node['text'] as String?) ?? '';
      }
      final viewCount = (m['video_view_count'] as num?)?.toInt() ?? 0;
      var cleanCaption = cleanText(caption);
      if (cleanCaption.length > 600) {
        cleanCaption = cleanCaption.substring(0, 600);
      }
      return {
        'ok': true,
        'shortcode': shortcode,
        'mediaType': 'video',
        'videoUrl': videoUrl,
        'imageUrls': <String>[],
        'thumbUrl': thumbUrl,
        'duration': duration,
        'width': width == 0 ? 9 : width,
        'height': height == 0 ? 16 : height,
        'author': cleanText(author),
        'caption': cleanCaption,
        'viewCount': viewCount,
        'permalink': 'https://www.instagram.com/reel/$shortcode/',
      };
    } on ReelException {
      rethrow;
    } catch (_) {
      return null;
    }
  }

  /// Last fallback: the public post page instagram.com/p/<code>/ and
  /// its og:video / og:image meta. Returns a result or null if there
  /// is no video — no duration or author (the meta has none).
  static Future<Map<String, dynamic>?> fetchReelHtmlFallback(
      String shortcode) async {
    await IgAnonWarmup.ensureWarmup();
    try {
      final urlStr = 'https://www.instagram.com/p/$shortcode/';
      final resp = await IgHttp.get(urlStr,
          headers: {
            ..._igHeaders(urlStr, userAgents[0]),
            'Accept': 'text/html',
          },
          connectTimeout:
              const Duration(milliseconds: imgConnectTimeoutMs),
          readTimeout: const Duration(milliseconds: imgReadTimeoutMs));
      if (_isLoginRedirect(resp)) return null;
      if (resp.statusCode != 200) return null;
      final html = resp.body;
      var videoUrl = pick(
          html, r'<meta property="og:video:secure_url" content="([^"]+)"');
      videoUrl ??= pick(
          html, r'<meta property="og:video" content="([^"]+)"');
      if (videoUrl == null || videoUrl.isEmpty) {
        final owner = extractPostOwnerUsername(html);
        if (html.contains(
            '"xig_polaris_media":{"__typename":"XIGPolarisImageMedia"')) {
          final mediaUrl = await resolvePostMediaUrl(shortcode);
          if (mediaUrl != null && mediaUrl.isNotEmpty) {
            return imageResult(shortcode, owner ?? '', {
              'images': [mediaUrl],
              'carousel': false,
            });
          }
        }
        if (owner != null && owner.isNotEmpty) {
          try {
            final full = await fetchImagesViaProfileEmbed(owner, shortcode);
            if (full != null) {
              final urls = full['images'] as List?;
              if (urls != null && urls.isNotEmpty) {
                return imageResult(shortcode, owner, full);
              }
            }
          } catch (_) {}
        }
        try {
          final postEmb = await fetchImagesViaPostEmbed(shortcode);
          if (postEmb != null) {
            final urls = postEmb['images'] as List?;
            if (urls != null && urls.isNotEmpty) {
              return imageResult(shortcode, owner ?? '', postEmb);
            }
          }
        } catch (_) {}
        final mediaUrl = await resolvePostMediaUrl(shortcode);
        if (mediaUrl != null && mediaUrl.isNotEmpty) {
          return imageResult(shortcode, owner ?? '', {
            'images': [mediaUrl],
            'carousel': false,
          });
        }
        final img = pick(
            html, r'<meta property="og:image" content="([^"]+)"');
        if (img == null || img.isEmpty) return null;
        throw ReelException('FULL_IMAGE_UNAVAILABLE');
      }
      videoUrl = videoUrl.replaceAll('&amp;', '&');
      var thumbUrl = pick(
              html, r'<meta property="og:image" content="([^"]+)"') ??
          '';
      thumbUrl = thumbUrl.replaceAll('&amp;', '&');
      return {
        'ok': true,
        'shortcode': shortcode,
        'mediaType': 'video',
        'videoUrl': videoUrl,
        'imageUrls': <String>[],
        'thumbUrl': thumbUrl,
        'duration': 0,
        'width': 9,
        'height': 16,
        'author': '',
        'caption': '',
        'viewCount': 0,
        'permalink': 'https://www.instagram.com/reel/$shortcode/',
      };
    } on ReelException {
      rethrow;
    } catch (_) {
      return null;
    }
  }

  /// Get reel info and verify it. Order: (1) the proven embed first,
  /// always, (2) if it fails without being "not a video" or "too
  /// long": GraphQL, (3) the p/ page and og:video.
  static Future<Map<String, dynamic>> fetchReelMeta(
      String shortcode) async {
    var lastError = 'INSTAGRAM_ERROR';
    try {
      return parseReelMeta(await fetchEmbedHtml(shortcode), shortcode);
    } on ReelException catch (e) {
      if (e.code == 'REEL_TOO_LONG') rethrow;
      lastError = e.code;
    }
    try {
      final g = await fetchReelGraphQL(shortcode);
      if (g != null) return g;
    } on ReelException {
      rethrow;
    } catch (_) {}
    try {
      final h = await fetchReelHtmlFallback(shortcode);
      if (h != null) return h;
    } on ReelException catch (e) {
      if (e.code == 'FULL_IMAGE_UNAVAILABLE') rethrow;
    } catch (_) {}
    throw ReelException(lastError);
  }

  /// Start of the requested post's window in the text: the first
  /// occurrence of the shortcode whose window (up to the next
  /// shortcode or +12000 chars) contains display_url.
  static int findMediaWindowStart(String text, String shortcode) {
    final needle = '"shortcode":"$shortcode"';
    var from = 0;
    while (true) {
      final idx = text.indexOf(needle, from);
      if (idx < 0) return -1;
      final next = text.indexOf(needle, idx + needle.length);
      var end = next >= 0 ? next : text.length;
      if (end > idx + 12000) end = idx + 12000;
      if (end > idx &&
          text.substring(idx, end).contains('"display_url"')) {
        return idx;
      }
      if (next < 0) return -1;
      from = next;
    }
  }

  /// Find the matching closing bracket — ignoring brackets inside
  /// string literals (captions can contain { } [ ]). Returns the index
  /// just after the closing bracket, or -1 if not found.
  static int findMatchingBracket(
      String text, int openPos, String open, String close) {
    if (openPos < 0 || openPos >= text.length) return -1;
    var depth = 0;
    var inStr = false;
    var esc = false;
    for (var i = openPos; i < text.length; i++) {
      final ch = text[i];
      if (inStr) {
        if (esc) {
          esc = false;
        } else if (ch == '\\') {
          esc = true;
        } else if (ch == '"') {
          inStr = false;
        }
      } else {
        if (ch == '"') {
          inStr = true;
        } else if (ch == open) {
          depth++;
        } else if (ch == close) {
          depth--;
          if (depth == 0) return i + 1;
        }
      }
    }
    return -1;
  }

  /// Bounds of the post's (node) object containing the requested
  /// shortcode: start = the last '{"__typename":"Graph' before the
  /// shortcode, end = the matching closing bracket.
  static List<int>? findMediaNodeBounds(String text, String shortcode) {
    final mediaStart = findMediaWindowStart(text, shortcode);
    if (mediaStart < 0) return null;
    var nodeStart = mediaStart;
    final idx = text.lastIndexOf('{"__typename":"Graph', mediaStart);
    if (idx >= 0 && mediaStart - idx <= 3000) nodeStart = idx;
    var nodeEnd = findMatchingBracket(text, nodeStart, '{', '}');
    if (nodeEnd < 0) {
      nodeEnd = mediaStart + 60000;
      if (nodeEnd > text.length) nodeEnd = text.length;
    }
    return [nodeStart, nodeEnd];
  }

  /// The post's owner from the p/<code>/ page: first from the
  /// logged-out dialog block, else the first "username" in the text.
  static String? extractPostOwnerUsername(String? html) {
    if (html == null) return null;
    for (final text in [deepUnescape(html), html]) {
      final di = text.indexOf('xig_logged_out_dynamic_dialog_info');
      if (di >= 0) {
        final end = di + 2000 < text.length ? di + 2000 : text.length;
        final u = pick(text.substring(di, end),
            r'"username":"([A-Za-z0-9_.]{1,30})"');
        if (u != null && u.isNotEmpty) return u;
      }
      final u = pick(text, r'"username":"([A-Za-z0-9_.]{1,30})"');
      if (u != null && u.isNotEmpty) return u;
    }
    return null;
  }

  /// The post's full images from the owner's embed page
  /// (/<username>/embed/) — the largest display_resources from the
  /// post's own object. Returns {"images":[...],"carousel":bool} or
  /// null if the post is not found on the page.
  static Future<Map<String, dynamic>?> fetchImagesViaProfileEmbed(
      String username, String shortcode) async {
    for (final ua in userAgents) {
      try {
        final html = await fetchHtml(
            'https://www.instagram.com/$username/embed/', ua, timeoutMs,
            connectMs: imgConnectTimeoutMs,
            readMs: imgReadTimeoutMs,
            maxAttempts: 1);
        final text = deepUnescape(html);
        final bounds = findMediaNodeBounds(text, shortcode);
        if (bounds == null) continue;
        final imgs = extractPostImages(text, bounds[0], bounds[1]);
        final images = imgs['images'] as List?;
        if (images != null && images.isNotEmpty) return imgs;
      } catch (_) {}
    }
    return null;
  }

  /// Build the photo/album result (same shape in every p/ branch):
  /// imageUrls + mediaType + thumbUrl = first image.
  static Map<String, dynamic> imageResult(
      String shortcode, String owner, Map<String, dynamic> imgs) {
    final urls = (imgs['images'] as List?) ?? <dynamic>[];
    return {
      'ok': true,
      'shortcode': shortcode,
      'mediaType': (imgs['carousel'] as bool? ?? false)
          ? 'carousel'
          : 'image',
      'videoUrl': '',
      'imageUrls': urls,
      'thumbUrl': urls.isNotEmpty ? urls[0] as String : '',
      'duration': 0,
      'width': 9,
      'height': 16,
      'author': owner,
      'caption': '',
      'viewCount': 0,
      'permalink': 'https://www.instagram.com/p/$shortcode/',
    };
  }

  /// The post's full images from the post's own embed page
  /// (/p/<code>/embed/) — sometimes works (especially for albums).
  static Future<Map<String, dynamic>?> fetchImagesViaPostEmbed(
      String shortcode) async {
    for (final ua in userAgents) {
      try {
        final html = await fetchHtml(
            'https://www.instagram.com/p/$shortcode/embed/', ua, timeoutMs,
            connectMs: imgConnectTimeoutMs,
            readMs: imgReadTimeoutMs,
            maxAttempts: 1);
        final text = deepUnescape(html);
        final bounds = findMediaNodeBounds(text, shortcode);
        if (bounds == null) continue;
        final imgs = extractPostImages(text, bounds[0], bounds[1]);
        final images = imgs['images'] as List?;
        if (images != null && images.isNotEmpty) return imgs;
      } catch (_) {}
    }
    return null;
  }

  /// Resolve /p/<code>/media/?size=l to the final CDN URL of the full
  /// image (or the album cover): 200 + image/* + CDN host, else null.
  static Future<String?> resolvePostMediaUrl(String shortcode) async {
    try {
      await IgAnonWarmup.ensureWarmup();
      final urlStr = 'https://www.instagram.com/p/$shortcode/media/?size=l';
      final resp = await IgHttp.get(urlStr,
          headers: {
            ..._igHeaders(urlStr, userAgents[0]),
            'Accept': 'image/*',
          },
          connectTimeout:
              const Duration(milliseconds: imgConnectTimeoutMs),
          readTimeout: const Duration(milliseconds: imgReadTimeoutMs));
      if (_isLoginRedirect(resp)) return null;
      if (resp.statusCode != 200) return null;
      final ct = resp.contentType.toLowerCase();
      if (!ct.startsWith('image/')) return null;
      final host = resp.finalUri.host.toLowerCase();
      if (!host.endsWith('.cdninstagram.com') &&
          !host.endsWith('.fbcdn.net')) {
        return null;
      }
      return resp.finalUri.toString();
    } catch (_) {
      return null;
    }
  }

  /// Parse the embed page and verify the reel.
  static Map<String, dynamic> parseReelMeta(
      String html, String shortcode) {
    final text = deepUnescape(html);
    final mediaStart = findMediaWindowStart(text, shortcode);
    if (mediaStart < 0) throw ReelException('REEL_NOT_FOUND');
    var mediaEnd = mediaStart + 60000;
    if (mediaEnd > text.length) mediaEnd = text.length;
    final mediaWin = text.substring(mediaStart, mediaEnd);
    final videoUrl = pick(mediaWin, r'"video_url":"([^"]+)"');
    final thumbUrl = pick(mediaWin, r'"display_url":"([^"]+)"');
    var duration = 0.0;
    try {
      duration =
          double.parse(pickNum(text, r'"video_duration":([0-9.]+)'));
    } catch (_) {}
    var height = 0;
    var width = 0;
    try {
      height = int.parse(pickNum(text, r'"dimensions":\{"height":(\d+)'));
    } catch (_) {}
    try {
      width = int.parse(
          pickNum(text, r'"dimensions":\{"height":\d+,"width":(\d+)'));
    } catch (_) {}
    var author =
        pick(text, r'"owner":\{"id":"\d+","username":"([^"]+)"');
    author ??= pick(text, r'"username":"([^"]+)"');
    var caption = pick(text,
            r'"edge_media_to_caption":\{"edges":\[\{"node":\{"text":"([^"]*)"') ??
        '';
    var viewCount = 0;
    try {
      viewCount = int.parse(pickNum(text, r'"video_view_count":(\d+)'));
    } catch (_) {}

    var cleanCaption = cleanText(caption);
    if (cleanCaption.length > 600) {
      cleanCaption = cleanCaption.substring(0, 600);
    }

    if (videoUrl != null && videoUrl.isNotEmpty) {
      if (duration > maxDuration) throw ReelException('REEL_TOO_LONG');
      return {
        'ok': true,
        'shortcode': shortcode,
        'mediaType': 'video',
        'videoUrl': videoUrl,
        'imageUrls': <String>[],
        'thumbUrl': thumbUrl ?? '',
        'duration': duration,
        'width': width == 0 ? 9 : width,
        'height': height == 0 ? 16 : height,
        'author': author == null ? '' : cleanText(author),
        'caption': cleanCaption,
        'viewCount': viewCount,
        'permalink': 'https://www.instagram.com/reel/$shortcode/',
      };
    }
    final bounds = findMediaNodeBounds(text, shortcode);
    final imgs = bounds != null
        ? extractPostImages(text, bounds[0], bounds[1])
        : extractPostImages(text, mediaStart, mediaEnd);
    final imageUrls = imgs['images'] as List?;
    if (imageUrls == null || imageUrls.isEmpty) {
      throw ReelException('NOT_A_VIDEO');
    }
    final carousel = imgs['carousel'] as bool? ?? false;
    final firstImage = imageUrls[0] as String;
    return {
      'ok': true,
      'shortcode': shortcode,
      'mediaType': carousel ? 'carousel' : 'image',
      'videoUrl': '',
      'imageUrls': imageUrls,
      'thumbUrl': (thumbUrl == null || thumbUrl.isEmpty)
          ? firstImage
          : thumbUrl,
      'duration': 0,
      'width': width == 0 ? 9 : width,
      'height': height == 0 ? 16 : height,
      'author': author == null ? '' : cleanText(author),
      'caption': cleanCaption,
      'viewCount': viewCount,
      'permalink': 'https://www.instagram.com/p/$shortcode/',
    };
  }

  /// Best image from a block of JSON with display_resources: the
  /// largest config_width. Links come with a stray backslash before
  /// %3D — the image CDN returns 400 on those, so all backslashes
  /// are stripped.
  static String bestDisplayResource(String text) {
    var best = '';
    var bestW = -1;
    final matches = RegExp(r'\{[^\{\}]*?"src":"([^"]+)"[^\{\}]*?\}')
        .allMatches(text);
    for (final match in matches) {
      final entry = match.group(0) ?? '';
      final src = match.group(1) ?? '';
      var w = 0;
      final wm =
          RegExp(r'"config_width":(\d+)').firstMatch(entry);
      if (wm != null) {
        w = int.tryParse(wm.group(1) ?? '') ?? 0;
      }
      if (src.isNotEmpty && w > bestW) {
        bestW = w;
        best = src;
      }
    }
    if (best.isEmpty) return '';
    return best.replaceAll('\\', '');
  }

  /// Best image from a GraphQL node: largest display_resources,
  /// else display_url.
  static String bestImageFromNode(Map<String, dynamic>? node) {
    if (node == null) return '';
    var best = '';
    var bestW = -1;
    final res = node['display_resources'] as List?;
    if (res != null) {
      for (final r in res) {
        final rm = r as Map<String, dynamic>?;
        if (rm == null) continue;
        final src = (rm['src'] as String?) ?? '';
        final w = (rm['config_width'] as num?)?.toInt() ?? 0;
        if (src.isNotEmpty && w > bestW) {
          bestW = w;
          best = src;
        }
      }
    }
    if (best.isEmpty) best = (node['display_url'] as String?) ?? '';
    if (best.isEmpty) return '';
    return best.replaceAll('\\', '');
  }

  /// Extract a post's images from the post's own object (after
  /// deepUnescape): {"images":[...],"carousel":true/false}.
  /// - Album: edge_sidecar_to_children — the best image from each
  ///   child (up to 10), from the album's own edges array (bound by
  ///   its closing bracket).
  /// - Single photo: the best display_resources in the object, else
  ///   display_url.
  /// Extraction is bound to the post object's bounds. og:image is
  /// never used as a download source: it is a square crop, and
  /// stripping stp returns 403 "Bad URL hash" from the CDN.
  static Map<String, dynamic> extractPostImages(
      String text, int nodeStart, int nodeEnd) {
    final images = <String>[];
    var carousel = false;
    try {
      final seen = <String>{};
      final start = nodeStart >= 0 ? nodeStart : 0;
      var end = nodeEnd > start ? nodeEnd : start + 60000;
      if (end > text.length) end = text.length;
      final node = text.substring(start, end);
      final sc = node.indexOf('"edge_sidecar_to_children"');
      if (sc >= 0) {
        final e = node.indexOf('"edges":[', sc);
        if (e >= 0) {
          final arrOpen = node.indexOf('[', e);
          final arrEnd = findMatchingBracket(node, arrOpen, '[', ']');
          if (arrEnd > 0) {
            final edges = node.substring(arrOpen, arrEnd);
            final matches = RegExp(r'"display_resources":\[(.*?)\]',
                    dotAll: true)
                .allMatches(edges);
            for (final match in matches) {
              if (images.length >= 10) break;
              final best = bestDisplayResource(match.group(1) ?? '');
              if (best.isNotEmpty && seen.add(best)) images.add(best);
            }
            if (images.length > 1) carousel = true;
          }
        }
      }
      if (images.isEmpty) {
        var best = bestDisplayResource(node);
        if (best.isEmpty) {
          best = pick(node, r'"display_url":"([^"]+)"') ?? '';
          best = best.replaceAll('\\', '');
        }
        if (best.isNotEmpty && seen.add(best)) images.add(best);
      }
    } catch (_) {}
    return {
      'images': images,
      'carousel': carousel,
    };
  }

  // ================= account search =================

  /// Pagination state for the current account search (same fields as
  /// the Java activity: currentAccountUsername/UserId/Cursor/HasMore).
  static String? currentAccountUsername;
  static String currentAccountUserId = '';
  static String currentPostsCursor = '';
  static bool currentPostsHasMore = false;

  /// Parse edges of edge_owner_to_timeline_media into a uniform shape:
  /// {"posts":[{shortcode,thumbUrl,hdUrl,isVideo,videoUrl}],
  /// "endCursor":..,"hasNextPage":..}. max = posts per batch.
  static Map<String, dynamic> parseTimelineMedia(
      Map<String, dynamic>? timeline, int max) {
    final posts = <Map<String, dynamic>>[];
    var endCursor = '';
    var hasNext = false;
    try {
      if (timeline != null) {
        final pageInfo = timeline['page_info'] as Map<String, dynamic>?;
        if (pageInfo != null) {
          endCursor = (pageInfo['end_cursor'] as String?) ?? '';
          hasNext = pageInfo['has_next_page'] as bool? ?? false;
        }
        final edges = timeline['edges'] as List?;
        if (edges != null) {
          for (var i = 0; i < edges.length && posts.length < max; i++) {
            final edge = edges[i] as Map<String, dynamic>?;
            final node = edge?['node'] as Map<String, dynamic>?;
            if (node == null) continue;
            var thumb = (node['display_url'] as String?) ?? '';
            if (thumb.isEmpty) {
              thumb = (node['thumbnail_src'] as String?) ?? '';
            }
            final code = (node['shortcode'] as String?) ?? '';
            if (thumb.isEmpty || code.isEmpty) continue;
            // Highest quality: largest display_resources (usually
            // 1080) instead of the thumbnail. Instagram's display_url
            // in the API is small — that is what made download
            // quality bad. Without display_resources, hdUrl =
            // display_url.
            var hd = '';
            var bestW = -1;
            final res = node['display_resources'] as List?;
            if (res != null) {
              for (final r in res) {
                final rm = r as Map<String, dynamic>?;
                if (rm == null) continue;
                final w = (rm['config_width'] as num?)?.toInt() ?? 0;
                final src = (rm['src'] as String?) ?? '';
                if (src.isNotEmpty && w > bestW) {
                  bestW = w;
                  hd = src;
                }
              }
            }
            if (hd.isEmpty) hd = thumb;
            posts.add({
              'shortcode': code,
              'thumbUrl': thumb,
              'hdUrl': hd,
              'isVideo': node['is_video'] as bool? ?? false,
              'videoUrl': (node['video_url'] as String?) ?? '',
            });
          }
        }
      }
    } catch (_) {}
    return {
      'posts': posts,
      'endCursor': endCursor,
      'hasNextPage': hasNext && endCursor.isNotEmpty,
    };
  }

  /// Next batch via GraphQL (UserMedia query_hash) with the cursor.
  /// Returns null on failure (429/403/404/no edges) — the caller
  /// tries the other source.
  static Future<Map<String, dynamic>?> fetchMorePostsGraphQL(
      String userId, String cursor) async {
    try {
      final vars = jsonEncode({
        'id': userId,
        'first': 12,
        'after': cursor,
      });
      final url =
          'https://www.instagram.com/graphql/query/?query_hash=69cba40317214236af40e7efa697781'
          '&variables=${Uri.encodeComponent(vars)}';
      final resp = await IgHttp.get(url,
          headers: {
            ..._igHeaders(url, userAgents[0]),
            'Accept': 'application/json',
          },
          connectTimeout: const Duration(milliseconds: timeoutMs),
          readTimeout: const Duration(milliseconds: timeoutMs));
      if (_isLoginRedirect(resp)) return null;
      if (resp.statusCode == 401) return null;
      if (resp.statusCode < 200 || resp.statusCode >= 300) return null;
      final root = jsonDecode(resp.body) as Map<String, dynamic>;
      final data = root['data'] as Map<String, dynamic>?;
      final user = data?['user'] as Map<String, dynamic>?;
      final timeline =
          user?['edge_owner_to_timeline_media'] as Map<String, dynamic>?;
      if (timeline == null) return null;
      return parseTimelineMedia(timeline, 12);
    } catch (_) {
      return null;
    }
  }

  /// Next batch via feed/user with max_id (fallback if GraphQL
  /// fails). items[] hold code + image_versions2 + video_versions.
  static Future<Map<String, dynamic>?> fetchMorePostsFeed(
      String userId, String cursor) async {
    try {
      final url = 'https://i.instagram.com/api/v1/feed/user/$userId/'
          '?max_id=${Uri.encodeComponent(cursor)}';
      final resp = await IgHttp.get(url,
          headers: {
            ..._igHeaders(url, iphoneUa),
            'X-IG-App-ID': igAppId,
            'Accept': 'application/json',
          },
          connectTimeout: const Duration(milliseconds: timeoutMs),
          readTimeout: const Duration(milliseconds: timeoutMs));
      if (_isLoginRedirect(resp)) return null;
      if (resp.statusCode == 401) return null;
      if (resp.statusCode < 200 || resp.statusCode >= 300) return null;
      final root = jsonDecode(resp.body) as Map<String, dynamic>;
      final items = root['items'] as List?;
      final posts = <Map<String, dynamic>>[];
      if (items != null) {
        for (var i = 0; i < items.length && posts.length < 12; i++) {
          final item = items[i] as Map<String, dynamic>?;
          if (item == null) continue;
          final shortcode = (item['code'] as String?) ?? '';
          if (shortcode.isEmpty) continue;
          var thumb = '';
          final imgVersions =
              item['image_versions2'] as Map<String, dynamic>?;
          final cands = imgVersions?['candidates'] as List?;
          if (cands != null && cands.isNotEmpty) {
            thumb = (cands[0] as Map<String, dynamic>?)?['url'] as String? ??
                '';
          }
          if (thumb.isEmpty) continue;
          final isVideo = (item['media_type'] as num?)?.toInt() == 2;
          var videoUrl = '';
          if (isVideo) {
            final vvers = item['video_versions'] as List?;
            if (vvers != null && vvers.isNotEmpty) {
              videoUrl =
                  (vvers[0] as Map<String, dynamic>?)?['url'] as String? ??
                      '';
            }
          }
          posts.add({
            'shortcode': shortcode,
            'thumbUrl': thumb,
            'isVideo': isVideo,
            'videoUrl': videoUrl,
          });
        }
      }
      final nextMaxId = (root['next_max_id'] as String?) ?? '';
      return {
        'posts': posts,
        'endCursor': nextMaxId,
        'hasNextPage': nextMaxId.isNotEmpty,
      };
    } catch (_) {
      return null;
    }
  }

  /// Next batch of posts (scroll down / "عرض المزيد"). Tries
  /// GraphQL with the cursor first, then feed/user with max_id. If
  /// both fail, the result is NO_MORE — it never repeats a batch.
  static Future<Map<String, dynamic>> loadMorePosts() async {
    if (currentAccountUsername == null ||
        !currentPostsHasMore ||
        currentPostsCursor.isEmpty ||
        currentAccountUserId.isEmpty) {
      return {'ok': false, 'error': 'NO_MORE'};
    }
    final userId = currentAccountUserId;
    final cursor = currentPostsCursor;
    try {
      var batch = await fetchMorePostsGraphQL(userId, cursor);
      batch ??= await fetchMorePostsFeed(userId, cursor);
      if (batch == null) return {'ok': false, 'error': 'NO_MORE'};
      final posts = batch['posts'] as List?;
      if (posts == null || posts.isEmpty) {
        currentPostsHasMore = false;
        return {'ok': false, 'error': 'NO_MORE'};
      }
      currentPostsCursor = (batch['endCursor'] as String?) ?? '';
      currentPostsHasMore = (batch['hasNextPage'] as bool? ?? false) &&
          currentPostsCursor.isNotEmpty;
      return {
        'ok': true,
        'posts': posts,
        'hasMore': currentPostsHasMore,
      };
    } catch (_) {
      return {'ok': false, 'error': 'NO_MORE'};
    }
  }

  /// Parse the profile page's og meta. Returns null if there is no
  /// real profile.
  static Map<String, dynamic>? parseProfileOg(
      String html, String username) {
    final ogDesc = pick(
        html, r'<meta property="og:description" content="([^"]*)"');
    final ogTitle =
        pick(html, r'<meta property="og:title" content="([^"]*)"');
    if (ogDesc == null || ogTitle == null) return null;
    final desc = htmlUnescape(ogDesc);
    final title = htmlUnescape(ogTitle);
    // og:description = "686M Followers, 168 Following, 8,636 Posts - ..."
    final cm = RegExp(
            r'([0-9][0-9,.KMk]*?)\s*Followers,\s*([0-9][0-9,.KMk]*?)\s*Following,\s*([0-9][0-9,.KMk]*?)\s*Posts')
        .firstMatch(desc);
    if (cm == null) return null;
    final followers = parseCount(cm.group(1));
    final following = parseCount(cm.group(2));
    final posts = parseCount(cm.group(3));
    // og:title = "Full Name (@username) • Instagram photos and videos"
    var fullName = '';
    var uname = username;
    final tm = RegExp(r'^(.+?)\s*\(@([A-Za-z0-9._]+)\)').firstMatch(title);
    if (tm != null) {
      fullName = (tm.group(1) ?? '').trim();
      uname = tm.group(2) ?? username;
    }
    // Bio from the description meta: '... on Instagram: "bio text"'
    var bio = '';
    final descMeta =
        pick(html, r'<meta content="([^"]*)" name="description"');
    if (descMeta != null) {
      final d = htmlUnescape(descMeta);
      final bm = RegExp(r'on Instagram:\s*"(.*)"\s*$', dotAll: true)
          .firstMatch(d);
      if (bm != null) bio = (bm.group(1) ?? '').trim();
    }
    if (bio.length > 500) bio = bio.substring(0, 500);
    // The bio in the meta has a literal "\n" (backslash + n) — turn
    // it back into a real line break.
    bio = bio.replaceAll(r'\n', '\n');
    var pic =
        pick(html, r'<meta property="og:image" content="([^"]*)"');
    if (pic != null) {
      pic = htmlUnescape(pic).replaceAll('&amp;', '&');
      // The link is used exactly as-is: swapping s150x150 for
      // s320x320 returns 403 from Instagram's CDN (tested directly)
      // — that is what made the picture not show. The original link
      // returns 200.
    }
    // v3.13 — high-quality profile picture from the same page:
    // profile_pic_url_hd (320px) is in the page's own JSON, while
    // og:image is only 150px — that is what made profile-picture
    // downloads bad quality. Both the plain form and the escaped
    // (\\"...\\") form are tried. If it is not found, attachPosts
    // falls back to the API.
    String? hdPic =
        pick(html, r'"profile_pic_url_hd":"([^"]*)"');
    hdPic ??= pick(html, r'\\"profile_pic_url_hd\\":\\"([^\\"]*)\\"');
    if (hdPic != null) {
      hdPic = htmlUnescape(hdPic).replaceAll(r'\/', '/').replaceAll('\\', '');
      if (!hdPic.startsWith('http')) hdPic = null;
    }
    final isPrivate = html.contains('"is_private":true');
    return {
      'ok': true,
      'username': uname,
      'fullName': fullName,
      'bio': bio,
      'profilePicUrl': pic ?? '',
      'profilePicHdUrl': hdPic ?? '',
      'followers': followers,
      'followersText': cm.group(1),
      'following': following,
      'followingText': cm.group(2),
      'posts': posts,
      'postsText': cm.group(3),
      'isPrivate': isPrivate,
      'exactCounts': false, // big counts are rounded by Instagram
    };
  }

  /// One attempt at web_profile_info (structured JSON). Returns null
  /// if there is no such user.
  static Future<Map<String, dynamic>?> fetchAccountViaApiOnce(
      String username) async {
    await IgAnonWarmup.ensureWarmup();
    try {
      final urlStr =
          'https://i.instagram.com/api/v1/users/web_profile_info/?username=$username';
      final resp = await IgHttp.get(urlStr,
          headers: {
            ..._igHeaders(urlStr, iphoneUa),
            ..._apiHeaders('https://www.instagram.com/$username/'),
            'Accept': 'application/json',
          },
          connectTimeout: const Duration(milliseconds: timeoutMs),
          readTimeout: const Duration(milliseconds: timeoutMs));
      if (_isLoginRedirect(resp)) {
        throw AccountException('INSTAGRAM_BLOCKED');
      }
      final code = resp.statusCode;
      if (code == 401) throw AccountException('INSTAGRAM_BLOCKED');
      if (code == 429 || code == 403) {
        // Blocked: fresh warmup so the next attempt (in
        // fetchAccountViaApi) uses fresh cookies.
        await IgAnonWarmup.rewarmup();
        throw AccountException('INSTAGRAM_BLOCKED');
      }
      if (code == 404) return null;
      if (code < 200 || code >= 300) {
        throw AccountException('INSTAGRAM_ERROR');
      }
      final body = resp.body;
      final u = pick(body, r'"user":\{(.*)');
      if (u == null || !body.contains('"username":"$username"')) {
        return null;
      }
      final fullName = pick(body, r'"full_name":"([^"]*)"');
      final bio = pick(body, r'"biography":"([^"]*)"');
      var pic = pick(body, r'"profile_pic_url_hd":"([^"]*)"');
      pic ??= pick(body, r'"profile_pic_url":"([^"]*)"');
      var followers = 0;
      var following = 0;
      var posts = 0;
      try {
        followers = int.parse(pickNum(body, r'"follower_count":(\d+)'));
      } catch (_) {}
      try {
        following = int.parse(pickNum(body, r'"following_count":(\d+)'));
      } catch (_) {}
      try {
        posts = int.parse(pickNum(body, r'"media_count":(\d+)'));
      } catch (_) {}
      final isPrivate = body.contains('"is_private":true');
      final result = <String, dynamic>{
        'ok': true,
        'username': username,
        'fullName': fullName == null ? '' : cleanText(fullName),
        'bio': bio == null ? '' : cleanText(bio),
        'profilePicUrl': pic ?? '',
        'followers': followers,
        'followersText': '',
        'following': following,
        'followingText': '',
        'posts': posts,
        'postsText': '',
        'isPrivate': isPrivate,
        'exactCounts': true,
      };
      // Posts from the same API JSON
      final postsInfo = extractPostsFromApiBody(body);
      result['posts'] = postsInfo['posts'];
      result['postsState'] = postsInfo['state'];
      result['userId'] = postsInfo['userId'];
      result['postsCursor'] = postsInfo['endCursor'];
      result['postsHasMore'] = postsInfo['hasNextPage'];
      return result;
    } on AccountException {
      rethrow;
    } catch (_) {
      throw AccountException('INSTAGRAM_ERROR');
    }
  }

  /// web_profile_info with one retry: if the session expired we
  /// retry anonymously, if blocked (429/403) we retry after a 2s
  /// pause.
  static Future<Map<String, dynamic>?> fetchAccountViaApi(
      String username) async {
    AccountException? last;
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        return await fetchAccountViaApiOnce(username);
      } on AccountException catch (e) {
        if (e.code == 'INSTAGRAM_BLOCKED') {
          last = e;
          await _sleepQuietly(2000);
          continue;
        }
        rethrow;
      }
    }
    if (last != null) throw last;
    return null;
  }

  /// Parse the embed page's graphql_media. The page is double-encoded
  /// JSON (\\"...), so deepUnescape is used first (like
  /// parseReelMeta), then every shortcode is extracted with its
  /// display_resources by regex — no full JSON.parse, because
  /// media_preview holds random bytes that break the parser.
  static Map<String, dynamic>? parseEmbedPosts(String html) {
    try {
      final text = deepUnescape(html);
      final gi = text.indexOf('"graphql_media":[');
      if (gi < 0) return null; // no posts list on the page
      // The account's owner id (for pagination if the API works later)
      var ownerId = '';
      final om = RegExp(r'"owner":\{"id":"(\d+)"').firstMatch(text);
      if (om != null && om.start >= gi) ownerId = om.group(1) ?? '';
      final posts = <Map<String, dynamic>>[];
      final seen = <String>{};
      final sm = RegExp(r'"shortcode":"([A-Za-z0-9_-]+)"');
      var searchFrom = gi;
      while (posts.length < 14) {
        final m = sm.firstMatch(text.substring(searchFrom));
        if (m == null) break;
        final code = m.group(1) ?? '';
        final sPos = searchFrom + m.start;
        searchFrom = searchFrom + m.end;
        if (!seen.add(code)) continue;
        // This post's window: up to the next shortcode (or 12000 chars)
        var nextStart = text.length;
        final nm = RegExp(r'"shortcode":"[A-Za-z0-9_-]+"')
            .firstMatch(text.substring(searchFrom));
        if (nm != null) nextStart = searchFrom + nm.start;
        var end = nextStart < sPos + 12000 ? nextStart : sPos + 12000;
        if (end > text.length) end = text.length;
        final win = text.substring(sPos, end);
        final isVideo = win.contains('"is_video":true');
        var thumb = pick(win, r'"display_url":"([^"]+)"');
        var hd = '';
        var bestW = -1;
        final rm = RegExp(
                r'"config_width":(\d+),"config_height":\d+,"src":"([^"]+)"')
            .allMatches(win);
        for (final r in rm) {
          final w = int.tryParse(r.group(1) ?? '') ?? -1;
          if (w < 0) continue;
          if (w > bestW) {
            bestW = w;
            hd = r.group(2) ?? '';
          }
        }
        if (hd.isEmpty) hd = thumb ?? '';
        if (thumb == null || thumb.isEmpty) thumb = hd;
        // Links come from a double-encoded page and carry a stray
        // backslash before %3D (e.g. ig_cache_key=...NQ\%3D\%3D) —
        // the image CDN returns 400 on those, so the picture never
        // loads and the UI hides the post (img.onerror). Strip all
        // backslashes from the links: without the backslash the link
        // returns 200 and a real WebP image (tested directly on
        // f0uri). Video links do not need this (the video CDN
        // accepts them as-is — tested: 200 either way).
        if (thumb.isEmpty) thumb = thumb.replaceAll('\\', '');
        if (hd.isNotEmpty) hd = hd.replaceAll('\\', '');
        if (thumb.isEmpty) continue;
        posts.add({
          'shortcode': code,
          'thumbUrl': thumb,
          'hdUrl': hd,
          'isVideo': isVideo,
          'videoUrl': '',
        });
      }
      return {
        'posts': posts,
        'state': posts.isNotEmpty ? 'ok' : 'empty',
        'endCursor': '',
        'hasNextPage': false,
        'userId': ownerId,
      };
    } catch (_) {
      return null;
    }
  }

  /// The account's posts from the public embed page
  /// (/<user>/embed/) — the second source if web_profile_info fails
  /// (it returns 429 without a session, in the sandbox and on the
  /// user's phone). The page is public, no login, and holds
  /// "graphql_media" with the latest posts: tested directly — natgeo:
  /// 14 posts, f0uri: 3 posts, nonexistent account: 200 but no
  /// graphql_media. Each post has shortcode + is_video + display_url
  /// + display_resources (640/750/1080) — the largest is taken as
  /// hdUrl for high-quality download. No pagination (first 14 only),
  /// and no video_url for videos (fetched from the reel's embed page
  /// when downloading, as before). Returns
  /// {"posts":[...],"state":"ok"|"empty","userId":""} or null if the
  /// page has no graphql_media.
  static Future<Map<String, dynamic>?> fetchPostsFromEmbedPage(
      String username) async {
    for (final ua in userAgents) {
      try {
        final html = await fetchHtml(
            'https://www.instagram.com/$username/embed/', ua, timeoutMs);
        final parsed = parseEmbedPosts(html);
        if (parsed != null) return parsed;
        // The page loaded but without graphql_media — try the next UA
      } catch (_) {
        // Try the next UA
      }
    }
    return null;
  }

  /// Extract up to 9 posts from web_profile_info JSON:
  /// data.user.edge_owner_to_timeline_media.edges[].node
  /// (display_url or thumbnail_src + shortcode + is_video + video_url
  /// if present). Returns {"posts":[...],"state":"ok"|"empty"|
  /// "unavailable","endCursor":..,"hasNextPage":..,"userId":..} —
  /// it never invents posts: if the JSON has no edges, the result is
  /// unavailable.
  static Map<String, dynamic> extractPostsFromApiBody(String body) {
    try {
      final root = jsonDecode(body) as Map<String, dynamic>;
      final data = root['data'] as Map<String, dynamic>?;
      final user = data?['user'] as Map<String, dynamic>?;
      if (user == null) {
        return {
          'posts': <Map<String, dynamic>>[],
          'state': 'unavailable',
          'endCursor': '',
          'hasNextPage': false,
          'userId': '',
        };
      }
      final userId = (user['id'] as String?) ?? '';
      final timeline =
          user['edge_owner_to_timeline_media'] as Map<String, dynamic>?;
      if (timeline == null) {
        return {
          'posts': <Map<String, dynamic>>[],
          'state': 'unavailable',
          'endCursor': '',
          'hasNextPage': false,
          'userId': userId,
        };
      }
      final parsed = parseTimelineMedia(timeline, 12); // first 12 as in the script
      final posts = parsed['posts'] as List? ?? <dynamic>[];
      return {
        'posts': posts,
        'state': posts.isNotEmpty ? 'ok' : 'empty',
        'endCursor': parsed['endCursor'],
        'hasNextPage': parsed['hasNextPage'],
        'userId': userId,
      };
    } catch (_) {
      return {
        'posts': <Map<String, dynamic>>[],
        'state': 'unavailable',
        'endCursor': '',
        'hasNextPage': false,
        'userId': '',
      };
    }
  }

  /// Fetch the account's posts and attach them to the profile
  /// result. Private account → postsState=private with no attempt;
  /// any other failure → unavailable. Also stores userId +
  /// end_cursor so "عرض المزيد" can fetch the next batch.
  static Future<void> attachPosts(
      Map<String, dynamic> profile, String username) async {
    try {
      if (profile['isPrivate'] as bool? ?? false) {
        profile['posts'] = <Map<String, dynamic>>[];
        profile['postsState'] = 'private';
        currentAccountUsername = username;
        currentAccountUserId = '';
        currentPostsCursor = '';
        currentPostsHasMore = false;
        return;
      }
      // First source: web_profile_info (exact counts +
      // profile_pic_url_hd + pagination). If it works and gives
      // posts, use it as-is.
      var hdPic = '';
      Map<String, dynamic>? api;
      try {
        api = await fetchAccountViaApi(username);
      } catch (_) {
        api = null;
      }
      if (api != null) {
        final pic = (api['profilePicUrl'] as String?) ?? '';
        if (pic.isNotEmpty) hdPic = pic.replaceAll(r'\/', '/');
        final posts = api['posts'] as List?;
        final state = (api['postsState'] as String?) ?? 'unavailable';
        if (posts != null && posts.isNotEmpty && state == 'ok') {
          profile['posts'] = posts;
          profile['postsState'] = 'ok';
          profile['userId'] = api['userId'];
          profile['postsCursor'] = api['postsCursor'];
          profile['postsHasMore'] = api['postsHasMore'];
          if (hdPic.isNotEmpty &&
              (profile['profilePicHdUrl'] as String? ?? '').isEmpty) {
            profile['profilePicHdUrl'] = hdPic;
          }
          currentAccountUsername = username;
          currentAccountUserId = (api['userId'] as String?) ?? '';
          currentPostsCursor = (api['postsCursor'] as String?) ?? '';
          currentPostsHasMore =
              (api['postsHasMore'] as bool? ?? false) &&
                  currentPostsCursor.isNotEmpty;
          return;
        }
        // The API worked but without posts (429/no edges) — keep the
        // userId if available, and continue to the second source.
        final apiUserId = (api['userId'] as String?) ?? '';
        if (apiUserId.isNotEmpty) currentAccountUserId = apiUserId;
      }
      // Second source: the public embed page — tested directly
      // (natgeo 14, f0uri 3 posts) while web_profile_info returns
      // 429. No pagination: first 14 posts only, and "عرض المزيد"
      // is honestly hidden.
      final emb = await fetchPostsFromEmbedPage(username);
      if (emb != null) {
        profile['posts'] = emb['posts'];
        profile['postsState'] = emb['state'];
        profile['userId'] = emb['userId'];
        profile['postsCursor'] = '';
        profile['postsHasMore'] = false;
        if (hdPic.isNotEmpty &&
            (profile['profilePicHdUrl'] as String? ?? '').isEmpty) {
          profile['profilePicHdUrl'] = hdPic;
        }
        currentAccountUsername = username;
        if (currentAccountUserId.isEmpty) {
          currentAccountUserId = (emb['userId'] as String?) ?? '';
        }
        currentPostsCursor = '';
        currentPostsHasMore = false;
        return;
      }
      // Both sources failed
      profile['posts'] = <Map<String, dynamic>>[];
      profile['postsState'] = 'unavailable';
      profile['userId'] = '';
      profile['postsCursor'] = '';
      profile['postsHasMore'] = false;
      if (hdPic.isNotEmpty &&
          (profile['profilePicHdUrl'] as String? ?? '').isEmpty) {
        profile['profilePicHdUrl'] = hdPic;
      }
      currentAccountUsername = username;
      currentAccountUserId = '';
      currentPostsCursor = '';
      currentPostsHasMore = false;
    } catch (_) {
      profile['posts'] = <Map<String, dynamic>>[];
      profile['postsState'] = 'unavailable';
      profile['userId'] = '';
      profile['postsCursor'] = '';
      profile['postsHasMore'] = false;
      currentAccountUsername = username;
      currentAccountUserId = '';
      currentPostsCursor = '';
      currentPostsHasMore = false;
    }
  }

  /// Search for a public Instagram account: full name, bio, picture,
  /// post/follower/following counts — no login.
  /// First source: the public profile page (og:title / og:description
  /// / description / og:image) — these are what is actually on the
  /// page (tested directly: instagram and natgeo returned 200 with
  /// counts, a nonexistent account returned no og and no counts). If
  /// the page gives nothing, one attempt at web_profile_info
  /// (structured JSON, with is_private and exact counts). No login,
  /// public data only.
  static Future<Map<String, dynamic>> fetchAccountProfile(
      String rawInput) async {
    final username = cleanUsername(rawInput);
    if (username == null) throw AccountException('ACCOUNT_NOT_FOUND');
    // A new search = new pagination state (stays empty if the search fails)
    currentAccountUsername = username;
    currentAccountUserId = '';
    currentPostsCursor = '';
    currentPostsHasMore = false;
    var lastError = 'INSTAGRAM_ERROR';
    for (final ua in userAgents) {
      String html;
      try {
        html = await fetchHtml(
            'https://www.instagram.com/$username/', ua, timeoutMs);
      } on AccountException catch (e) {
        lastError = e.code;
        if (lastError == 'ACCOUNT_NOT_FOUND') rethrow;
        continue;
      }
      final parsed = parseProfileOg(html, username);
      if (parsed != null) {
        // Bio, picture and counts from the page; posts come from the
        // API (the public page has no posts) — one silent attempt,
        // if it fails the profile stays without posts with an honest
        // message in the UI.
        await attachPosts(parsed, username);
        return parsed;
      }
      // The page loaded but without profile data — possibly a
      // deleted/nonexistent account
      lastError = 'ACCOUNT_NOT_FOUND';
      break;
    }
    if (lastError == 'ACCOUNT_NOT_FOUND') {
      // Final confirmation via web_profile_info before judging
      // "doesn't exist"
      try {
        final api = await fetchAccountViaApi(username);
        if (api != null) {
          currentAccountUsername = username;
          currentAccountUserId = (api['userId'] as String?) ?? '';
          currentPostsCursor = (api['postsCursor'] as String?) ?? '';
          currentPostsHasMore =
              (api['postsHasMore'] as bool? ?? false) &&
                  currentPostsCursor.isNotEmpty;
          return api;
        }
      } on AccountException catch (e) {
        if (e.code == 'INSTAGRAM_BLOCKED') rethrow;
      } catch (_) {}
      throw AccountException('ACCOUNT_NOT_FOUND');
    }
    throw AccountException(lastError);
  }
}
