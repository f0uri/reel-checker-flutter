// Multi-platform video extractor — YouTube, TikTok, Facebook.
// Anonymous only: no account, no session cookies, plain HTTP, the
// same approach as the Instagram engine (instagram_service.dart).
//
// Returns the SAME result shape as InstagramService.fetchReelMeta so
// the existing result card + download button work unchanged:
// {ok, shortcode, mediaType, videoUrl, imageUrls, thumbUrl, duration,
//  width, height, author, caption, viewCount, permalink, platform}.
//
// Honest status (2026-11-07, verified from the sandbox):
// - YouTube: the watch page parses fine but its only format is
//   signatureCipher-locked; every InnerTube client is rejected from
//   datacenter IPs. On the user's phone (residential/mobile IP) the
//   same requests often return direct URLs — the phone is the judge.
// - TikTok: the video page serves a shell without video data from
//   datacenter IPs; the rehydration JSON only carries video data on
//   friendlier networks. Same story: the phone may succeed.
// - Facebook: public videos expose og:video on their page; the
//   extractor reads that first, then playable_url/hd_src, then
//   mbasic as a fallback.
// Nothing here is claimed live-tested from the sandbox; every
// failure surfaces as a clear error code for the UI.

import 'dart:convert';

import 'instagram_service.dart';

class PlatformMediaException implements Exception {
  final String code;
  PlatformMediaException(this.code);
  @override
  String toString() => 'PlatformMediaException($code)';
}

class MultiPlatformService {
  static const String _browserUa =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0 Safari/537.36';
  static const String _iphoneUa =
      'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) '
      'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 '
      'Mobile/15E148 Safari/604.1';
  // The public InnerTube key shipped in YouTube's own web client.
  static const String _ytApiKey =
      'AIzaSyAO_FJ2SlqU8Q4STEHLGCilw_Y9_11qcW8';
  static const Duration _timeout = Duration(seconds: 15);

  // ================= platform detection =================

  static String? detectPlatform(String rawUrl) {
    var v = rawUrl.trim();
    if (v.isEmpty) return null;
    if (!v.contains('://')) v = 'https://$v';
    Uri? uri;
    try {
      uri = Uri.parse(v);
    } catch (_) {
      return null;
    }
    final host = uri.host.toLowerCase();
    if (host == 'youtube.com' ||
        host.endsWith('.youtube.com') ||
        host == 'youtu.be' ||
        host == 'www.youtu.be') {
      return 'youtube';
    }
    if (host == 'tiktok.com' ||
        host.endsWith('.tiktok.com') ||
        host == 'vm.tiktok.com' ||
        host == 'vt.tiktok.com') {
      return 'tiktok';
    }
    if (host == 'facebook.com' ||
        host.endsWith('.facebook.com') ||
        host == 'fb.watch') {
      return 'facebook';
    }
    return null;
  }

  static Future<Map<String, dynamic>> fetchMediaMeta(String rawUrl) async {
    final platform = detectPlatform(rawUrl);
    if (platform == null) {
      throw PlatformMediaException('MEDIA_UNSUPPORTED');
    }
    switch (platform) {
      case 'youtube':
        return _fetchYouTube(rawUrl.trim());
      case 'tiktok':
        return _fetchTikTok(rawUrl.trim());
      case 'facebook':
        return _fetchFacebook(rawUrl.trim());
      default:
        throw PlatformMediaException('MEDIA_UNSUPPORTED');
    }
  }

  // ================= small helpers =================

  static Future<String?> _getText(String url) async {
    return _getTextWith(url, _browserUa);
  }

  // TikTok session cookies (ttwid, msToken, ...) captured from the
  // page fetches. TikTok's video CDN rejects downloads that arrive
  // with a Referer but no session cookies, so the downloader sends
  // these back on TikTok hosts. Anonymous only: no account identity.
  static final Map<String, String> _tikTokCookies = {};

  static String get tikTokCookieHeader => _tikTokCookies.entries
      .map((e) => '${e.key}=${e.value}')
      .join('; ');

  static void _collectTikTokCookies(Map<String, List<String>> headers) {
    final setCookies = headers['set-cookie'];
    if (setCookies == null) return;
    for (final sc in setCookies) {
      final nv = sc.split(';')[0].trim();
      final eq = nv.indexOf('=');
      if (eq <= 0) continue;
      final name = nv.substring(0, eq).trim();
      final value = nv.substring(eq + 1).trim();
      if (name.isEmpty || value.isEmpty) continue;
      _tikTokCookies[name] = value;
    }
  }

  static Future<String?> _getTextWith(String url, String ua,
      {String? referer}) async {
    try {
      final headers = <String, String>{
        'User-Agent': ua,
        'Accept': 'text/html,application/xhtml+xml,application/json',
        'Accept-Language': 'en-US,en;q=0.9',
      };
      if (referer != null) headers['Referer'] = referer;
      final resp = await IgHttp.get(url,
          headers: headers,
          connectTimeout: _timeout,
          readTimeout: _timeout);
      if (resp.statusCode < 200 || resp.statusCode >= 300) return null;
      if ((Uri.tryParse(url)?.host.toLowerCase() ?? '')
          .contains('tiktok')) {
        _collectTikTokCookies(resp.headers);
      }
      return resp.body;
    } catch (_) {
      return null;
    }
  }

  static String _cleanUrl(String? raw) {
    if (raw == null) return '';
    return InstagramService.htmlUnescape(InstagramService.deepUnescape(raw))
        .replaceAll('&amp;', '&')
        .trim();
  }

  static Map<String, dynamic> _videoResult({
    required String shortcode,
    required String platform,
    required String videoUrl,
    required String thumbUrl,
    required double duration,
    required int width,
    required int height,
    required String author,
    required String caption,
    required int viewCount,
    required String permalink,
  }) {
    return {
      'ok': true,
      'shortcode': shortcode,
      'mediaType': 'video',
      'videoUrl': videoUrl,
      'imageUrls': <String>[],
      'thumbUrl': thumbUrl,
      'duration': duration,
      'width': width == 0 ? 16 : width,
      'height': height == 0 ? 9 : height,
      'author': author,
      'caption': caption,
      'viewCount': viewCount,
      'permalink': permalink,
      'platform': platform,
    };
  }

  // ================= YouTube =================

  static String? _youTubeId(String url) {
    var m = RegExp(
            r'(?:youtube\.com/(?:watch\?(?:.*&)?v=|shorts/|embed/|live/|v/)|youtu\.be/)([A-Za-z0-9_-]{11})',
            caseSensitive: false)
        .firstMatch(url);
    if (m != null) return m.group(1);
    m = RegExp(r'[?&]v=([A-Za-z0-9_-]{11})').firstMatch(url);
    return m?.group(1);
  }

  static Future<Map<String, dynamic>> _fetchYouTube(String url) async {
    final id = _youTubeId(url);
    if (id == null) throw PlatformMediaException('YOUTUBE_NOT_FOUND');
    // 1. Watch page (works on friendly networks; from datacenter IPs
    //    the formats come back cipher-locked or the page demands login).
    String? watchHtml;
    try {
      watchHtml =
          await _getText('https://www.youtube.com/watch?v=$id');
    } catch (_) {}
    if (watchHtml != null) {
      try {
        final meta = _youTubePlayerFromHtml(watchHtml, id);
        if (meta != null) return meta;
      } catch (_) {}
    }
    // 2. InnerTube ANDROID client (the one downloaders rely on:
    //    it returns direct muxed URLs on mobile IPs where the WEB
    //    client now answers UNPLAYABLE).
    try {
      final meta = await _youTubeFromInnerTube(id, android: true);
      if (meta != null) return meta;
    } catch (_) {}
    // 3. InnerTube WEB player request, with the visitorData from
    //    the watch page when available (a session makes the WEB
    //    client far more likely to answer OK).
    String? visitorData;
    if (watchHtml != null) {
      visitorData =
          InstagramService.pick(watchHtml, r'"visitorData":"([^"]+)"');
    }
    try {
      final meta = await _youTubeFromInnerTube(id,
          android: false, visitorData: visitorData);
      if (meta != null) return meta;
    } catch (_) {}
    // 4. Embed page (its player_response sometimes carries the
    //    formats when the watch page does not).
    try {
      final meta = await _youTubeFromEmbedPage(id);
      if (meta != null) return meta;
    } catch (_) {}
    throw PlatformMediaException('YOUTUBE_LOCKED');
  }

  /// Parse ytInitialPlayerResponse out of a YouTube page's HTML.
  static Map<String, dynamic>? _youTubePlayerFromHtml(
      String html, String id) {
    if (!html.contains('ytInitialPlayerResponse')) return null;
    final marker = html.indexOf('ytInitialPlayerResponse');
    final open = html.indexOf('{', marker);
    if (open < 0) return null;
    final end = InstagramService.findMatchingBracket(html, open, '{', '}');
    if (end < 0) return null;
    try {
      final pr =
          jsonDecode(html.substring(open, end)) as Map<String, dynamic>;
      return _youTubeFromPlayer(pr, id);
    } catch (_) {
      return null;
    }
  }

  static Future<Map<String, dynamic>?> _youTubeFromEmbedPage(
      String id) async {
    final html = await _getText('https://www.youtube.com/embed/$id');
    if (html == null) return null;
    final fromInitial = _youTubePlayerFromHtml(html, id);
    if (fromInitial != null) return fromInitial;
    final raw = InstagramService.pick(
        html, r'"player_response":"((?:[^"\\]|\\.)*)"');
    if (raw == null || raw.isEmpty) return null;
    try {
      final pr = jsonDecode(InstagramService.deepUnescape(raw))
          as Map<String, dynamic>;
      return _youTubeFromPlayer(pr, id);
    } catch (_) {
      return null;
    }
  }

  static Future<Map<String, dynamic>?> _youTubeFromInnerTube(String id,
      {bool android = false, String? visitorData}) async {
    try {
      final client = android
          ? {
              'clientName': 'ANDROID',
              'clientVersion': '19.09.37',
              'androidSdkVersion': 30,
              'hl': 'en',
              'gl': 'US',
            }
          : {
              'clientName': 'WEB',
              'clientVersion': '2.20240111.09.00',
              'hl': 'en',
              'gl': 'US',
              if (visitorData != null && visitorData.isNotEmpty)
                'visitorData': visitorData,
            };
      final body = jsonEncode({
        'context': {'client': client},
        'videoId': id,
        'racyCheckOk': true,
        'contentCheckOk': true,
      });
      final headers = <String, String>{
        'Content-Type': 'application/json',
        if (android) ...{
          'User-Agent':
              'com.google.android.youtube/19.09.37 (Linux; U; Android 11) gzip',
          'X-Goog-Api-Format-Version': '2',
        } else ...{
          'User-Agent': _browserUa,
          'Origin': 'https://www.youtube.com',
        },
      };
      final resp = await IgHttp.post(
          'https://www.youtube.com/youtubei/v1/player?key=$_ytApiKey',
          headers: headers,
          body: body,
          connectTimeout: _timeout,
          readTimeout: _timeout);
      if (resp.statusCode != 200) return null;
      final pr = jsonDecode(resp.body) as Map<String, dynamic>;
      return _youTubeFromPlayer(pr, id);
    } catch (_) {
      return null;
    }
  }

  /// Build the result from a player response. Returns null when the
  /// video is gated (login/bot check) or when no format carries a
  /// direct URL (cipher-locked). Only direct URLs are ever used:
  /// signature deciphering is deliberately NOT implemented here.
  static Map<String, dynamic>? _youTubeFromPlayer(
      Map<String, dynamic> pr, String id) {
    final status =
        pr['playabilityStatus'] as Map<String, dynamic>?;
    final playState = (status?['status'] as String?) ?? '';
    if (playState != 'OK') return null;
    final details = pr['videoDetails'] as Map<String, dynamic>?;
    if (details == null) return null;
    final sd = pr['streamingData'] as Map<String, dynamic>?;
    if (sd == null) return null;

    // Muxed formats (video + audio in one file) first — they play
    // with sound in the preview player and download as one file.
    String videoUrl = '';
    var width = 0;
    var height = 0;
    final muxed = sd['formats'] as List?;
    if (muxed != null) {
      var bestH = -1;
      for (final f in muxed) {
        final fm = f as Map<String, dynamic>?;
        if (fm == null) continue;
        final u = (fm['url'] as String?) ?? '';
        if (u.isEmpty) continue;
        final h = (fm['height'] as num?)?.toInt() ?? 0;
        if (h > bestH) {
          bestH = h;
          videoUrl = u;
          width = (fm['width'] as num?)?.toInt() ?? 0;
          height = h;
        }
      }
    }
    // Fallback: best adaptive video with a direct URL (video-only;
    // plays without sound, but still downloadable).
    if (videoUrl.isEmpty) {
      final adaptive = sd['adaptiveFormats'] as List?;
      if (adaptive != null) {
        var bestH = -1;
        for (final f in adaptive) {
          final fm = f as Map<String, dynamic>?;
          if (fm == null) continue;
          final mime = (fm['mimeType'] as String?) ?? '';
          if (!mime.startsWith('video/')) continue;
          final u = (fm['url'] as String?) ?? '';
          if (u.isEmpty) continue;
          final h = (fm['height'] as num?)?.toInt() ?? 0;
          if (h > bestH) {
            bestH = h;
            videoUrl = u;
            width = (fm['width'] as num?)?.toInt() ?? 0;
            height = h;
          }
        }
      }
    }
    if (videoUrl.isEmpty) return null;

    var thumb = '';
    final thumbs =
        (details['thumbnail'] as Map<String, dynamic>?)?['thumbnails']
            as List?;
    if (thumbs != null && thumbs.isNotEmpty) {
      thumb = (thumbs.last as Map<String, dynamic>?)?['url'] as String? ??
          '';
    }
    if (thumb.isEmpty) {
      thumb = 'https://i.ytimg.com/vi/$id/maxresdefault.jpg';
    }
    final duration =
        double.tryParse((details['lengthSeconds'] as String?) ?? '') ??
            0.0;
    final views =
        int.tryParse((details['viewCount'] as String?) ?? '') ?? 0;
    return _videoResult(
      shortcode: id,
      platform: 'youtube',
      videoUrl: videoUrl,
      thumbUrl: thumb,
      duration: duration,
      width: width,
      height: height,
      author: (details['author'] as String?) ?? '',
      caption: (details['title'] as String?) ?? '',
      viewCount: views,
      permalink: 'https://www.youtube.com/watch?v=$id',
    );
  }

  // ================= TikTok =================

  static String? _tikTokId(String url) {
    final m = RegExp(r'tiktok\.com/@[^/]+/video/(\d+)').firstMatch(url);
    return m?.group(1);
  }

  static Future<Map<String, dynamic>> _fetchTikTok(String url) async {
    var full = url.trim();
    // Resolve short share links (vm/vt.tiktok.com, tiktok.com/t/)
    // to the full video URL via redirect following.
    final host = Uri.tryParse(full)?.host.toLowerCase() ?? '';
    if (host == 'vm.tiktok.com' ||
        host == 'vt.tiktok.com' ||
        full.contains('/t/')) {
      try {
        final r = await IgHttp.get(full,
            headers: {'User-Agent': _browserUa},
            connectTimeout: _timeout,
            readTimeout: _timeout);
        full = r.finalUri.toString();
      } catch (_) {}
    }
    final id = _tikTokId(full);
    if (id == null) throw PlatformMediaException('TIKTOK_NOT_FOUND');

    // Try several page variants: TikTok serves the video data to
    // some clients and a shell/verify page to others. First page
    // that carries playAddr wins.
    final attempts = <Future<String?>>[
      _getTextWith(full, _browserUa,
          referer: 'https://www.tiktok.com/'),
      _getTextWith(full, _iphoneUa,
          referer: 'https://www.tiktok.com/'),
      _getTextWith('https://m.tiktok.com/v/$id', _iphoneUa,
          referer: 'https://www.tiktok.com/'),
    ];
    for (final attempt in attempts) {
      String? html;
      try {
        html = await attempt;
      } catch (_) {}
      if (html == null) continue;
      final meta = await _tikTokFromPage(html, id, full);
      if (meta != null) return meta;
    }
    // Last resort: the item detail API (sometimes answers when
    // the page does not).
    try {
      final api = await _getTextWith(
          'https://www.tiktok.com/api/item/detail/?itemId=$id&aid=1988',
          _browserUa,
          referer: 'https://www.tiktok.com/');
      if (api != null && api.isNotEmpty) {
        final meta = await _tikTokFromPage(api, id, full);
        if (meta != null) return meta;
      }
    } catch (_) {}
    throw PlatformMediaException('TIKTOK_BLOCKED');
  }

  /// Parse one TikTok page/API response: returns the video result
  /// when it carries playAddr/downloadAddr, else null.
  static Future<Map<String, dynamic>?> _tikTokFromPage(
      String html, String id, String full) async {
    final text = InstagramService.deepUnescape(html);

    // The video file in the rehydration JSON (present on friendly
    // networks; on datacenter IPs TikTok serves a shell page without
    // it — then this returns null and the caller tries the next source).
    var videoUrl = InstagramService.pick(
        text, r'"playAddr":"((?:[^"\\]|\\.)*)"');
    videoUrl ??= InstagramService.pick(
        text, r'"downloadAddr":"((?:[^"\\]|\\.)*)"');
    videoUrl = _cleanUrl(videoUrl);
    if (videoUrl.isEmpty) return null;

    // Metadata from the same page, near the video data.
    final winStart = text.indexOf('playAddr');
    var win = text;
    if (winStart >= 0) {
      final from = winStart - 4000 < 0 ? 0 : winStart - 4000;
      var to = winStart + 4000;
      if (to > text.length) to = text.length;
      win = text.substring(from, to);
    }
    var author =
        InstagramService.pick(win, r'"uniqueId":"([^"]+)"') ?? '';
    final desc = InstagramService.pick(win, r'"desc":"([^"]*)"') ?? '';
    var cover =
        InstagramService.pick(win, r'"originCover":"([^"]+)"') ?? '';
    cover = _cleanUrl(cover);
    if (cover.isEmpty) {
      cover = _cleanUrl(
          InstagramService.pick(win, r'"cover":"([^"]+)"'));
    }
    var duration = 0.0;
    try {
      duration = double.parse(InstagramService.pick(
              win, r'"duration":([0-9.]+)') ??
          '0');
    } catch (_) {}
    var width = 0;
    var height = 0;
    try {
      width = int.parse(
          InstagramService.pick(win, r'"width":(\d+)') ?? '0');
      height = int.parse(
          InstagramService.pick(win, r'"height":(\d+)') ?? '0');
    } catch (_) {}

    // oEmbed enriches title/thumbnail when the page is thin.
    if (cover.isEmpty || author.isEmpty) {
      try {
        final oe = await IgHttp.get(
            'https://www.tiktok.com/oembed?url=${Uri.encodeComponent(full)}',
            headers: {'User-Agent': _browserUa},
            connectTimeout: _timeout,
            readTimeout: _timeout);
        if (oe.statusCode == 200) {
          final o = jsonDecode(oe.body) as Map<String, dynamic>;
          if (cover.isEmpty) {
            cover = (o['thumbnail_url'] as String?) ?? '';
          }
          if (author.isEmpty) {
            author = (o['author_name'] as String?) ?? '';
          }
        }
      } catch (_) {}
    }

    return _videoResult(
      shortcode: id,
      platform: 'tiktok',
      videoUrl: videoUrl,
      thumbUrl: cover,
      duration: duration,
      width: width,
      height: height,
      author: author,
      caption: desc,
      viewCount: 0,
      permalink: full,
    );
  }

  // ================= Facebook =================

  static String? _facebookId(String url) {
    var m = RegExp(r'facebook\.com/(?:reel|videos?)/(\d+)').firstMatch(url);
    if (m != null) return m.group(1);
    m = RegExp(r'[?&]v=(\d+)').firstMatch(url);
    if (m != null) return m.group(1);
    m = RegExp(r'facebook\.com/share/[rv]/(\d+)').firstMatch(url);
    return m?.group(1);
  }

  static Future<Map<String, dynamic>> _fetchFacebook(String url) async {
    var full = url.trim();
    // Resolve fb.watch / share links to the final video URL.
    final host = Uri.tryParse(full)?.host.toLowerCase() ?? '';
    if (host == 'fb.watch' || full.contains('/share/')) {
      try {
        final r = await IgHttp.get(full,
            headers: {'User-Agent': _browserUa},
            connectTimeout: _timeout,
            readTimeout: _timeout);
        full = r.finalUri.toString();
      } catch (_) {}
    }
    final id = _facebookId(full);
    if (id == null) throw PlatformMediaException('FACEBOOK_NOT_FOUND');

    // 1. The public video page — og:video carries the file for
    //    public videos; playable_url/hd_src are the backups.
    var html = await _getText('https://www.facebook.com/watch/?v=$id');
    var videoUrl = html == null ? null : _fbVideoFromHtml(html);
    // 2. mbasic fallback (lighter page, sometimes less gated).
    if (videoUrl == null || videoUrl.isEmpty) {
      final mb =
          await _getText('https://mbasic.facebook.com/watch/?v=$id');
      if (mb != null) videoUrl = _fbVideoFromHtml(mb);
    }
    if (videoUrl == null || videoUrl.isEmpty) {
      throw PlatformMediaException('FACEBOOK_BLOCKED');
    }
    var title = '';
    var thumb = '';
    if (html != null) {
      title = InstagramService.pick(
              html, r'<meta property="og:title" content="([^"]+)"') ??
          '';
      thumb = InstagramService.pick(
              html, r'<meta property="og:image" content="([^"]+)"') ??
          '';
      title = _cleanUrl(title);
      thumb = _cleanUrl(thumb);
    }
    return _videoResult(
      shortcode: id,
      platform: 'facebook',
      videoUrl: videoUrl,
      thumbUrl: thumb,
      duration: 0,
      width: 0,
      height: 0,
      author: '',
      caption: title,
      viewCount: 0,
      permalink: 'https://www.facebook.com/watch/?v=$id',
    );
  }

  static String? _fbVideoFromHtml(String html) {
    final text = InstagramService.deepUnescape(html);
    // Prefer the explicit HD stream when Facebook exposes it, then
    // the og:video file, then the plain playable URL / sd source.
    var u = InstagramService.pick(
        text, r'"playable_url_quality_hd":"((?:[^"\\]|\\.)*)"');
    u ??= InstagramService.pick(
        text, r'<meta property="og:video:secure_url" content="([^"]+)"');
    u ??= InstagramService.pick(
        text, r'<meta property="og:video" content="([^"]+)"');
    u ??= InstagramService.pick(
        text, r'"playable_url":"((?:[^"\\]|\\.)*)"');
    u ??= InstagramService.pick(text, r'"hd_src":"((?:[^"\\]|\\.)*)"');
    u ??= InstagramService.pick(text, r'"sd_src":"((?:[^"\\]|\\.)*)"');
    final clean = _cleanUrl(u);
    if (clean.isEmpty) return null;
    if (!clean.startsWith('http://') && !clean.startsWith('https://')) {
      return null;
    }
    return clean;
  }
}
