// QuickSave fallback — POST https://quicksave.my/api/info
// Used ONLY when the primary method (server -> Instagram embed/GraphQL) fails.
// Spec: 30s timeout, keep only type==video && url!=null, pick highest height,
// ignore audio with null url, return clear error if none found.
// Download must use same UA and happen immediately (temporary CDN link, no cache).

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'instagram_service.dart';

class QuickSaveService {
  static const String _endpoint = 'https://quicksave.my/api/info';
  static const String userAgent =
      'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/139.0.0.0 Safari/537.36';
  static const Duration _timeout = Duration(seconds: 30);

  static const Map<String, String> _headers = {
    'accept': '*/*',
    'content-type': 'application/json',
    'origin': 'https://quicksave.my',
    'referer': 'https://quicksave.my/',
    'user-agent': userAgent,
  };

  /// Headers for direct CDN download (same UA as the API call).
  static Map<String, String> get downloadHeaders => {
        'User-Agent': userAgent,
        'Referer': 'https://www.instagram.com/',
        'Accept': '*/*',
        'Accept-Language': 'en-US,en;q=0.9',
      };

  /// Fetch reel meta by shortcode. Constructs instagram URL as
  /// https://www.instagram.com/reel/<code>/ (works for both reel and p on quicksave).
  /// Returns map compatible with InstagramService.fetchReelMeta result.
  /// Throws ReelException on failure (caller decides fallback -> error).
  static Future<Map<String, dynamic>> fetchReelMeta(String shortcode) async {
    final code = shortcode.trim();
    if (code.isEmpty) throw ReelException('REEL_NOT_FOUND');
    // quicksave expects a full Instagram URL
    final instagramUrl = 'https://www.instagram.com/reel/$code/';
    return fetchByUrl(instagramUrl, shortcodeOverride: code);
  }

  /// Fetch by full Instagram URL. If shortcodeOverride is given, it is used
  /// in the returned map (keeps caller's shortcode even if URL is p/ vs reel/).
  static Future<Map<String, dynamic>> fetchByUrl(String instagramUrl,
      {String? shortcodeOverride}) async {
    final url = instagramUrl.trim();
    if (url.isEmpty) throw ReelException('REEL_NOT_FOUND');
    // Derive shortcode from URL for the result map if not overridden
    String shortcode = shortcodeOverride ?? '';
    if (shortcode.isEmpty) {
      shortcode = InstagramService.extractShortcodeFromText(url) ?? '';
      if (shortcode.isEmpty) shortcode = url;
    }

    try {
      final body = jsonEncode({'url': url});

      // ignore: avoid_print
      print('[QuickSave] POST $_endpoint url=$url shortcode=$shortcode');

      final resp = await http
          .post(Uri.parse(_endpoint), headers: _headers, body: body)
          .timeout(_timeout);

      if (resp.statusCode != 200) {
        // ignore: avoid_print
        print('[QuickSave] failed for $shortcode HTTP ${resp.statusCode} body=${resp.body.length > 300 ? resp.body.substring(0, 300) : resp.body}');
        if (resp.statusCode == 404) throw ReelException('REEL_NOT_FOUND');
        if (resp.statusCode == 429 || resp.statusCode == 403) {
          throw ReelException('INSTAGRAM_BLOCKED');
        }
        throw ReelException('INSTAGRAM_ERROR');
      }

      // Validate JSON
      Map<String, dynamic> data;
      try {
        data = jsonDecode(resp.body) as Map<String, dynamic>;
      } catch (_) {
        // ignore: avoid_print
        print('[QuickSave] invalid JSON for $shortcode: ${resp.body.substring(0, resp.body.length > 200 ? 200 : resp.body.length)}');
        throw ReelException('INSTAGRAM_ERROR');
      }

      // Required fields: formats
      final formatsRaw = data['formats'];
      if (formatsRaw == null || formatsRaw is! List) {
        // No formats field -> treat as missing video
        // ignore: avoid_print
        print('[QuickSave] missing formats for $shortcode dataKeys=${data.keys}');
        throw ReelException('VIDEO_URL_MISSING');
      }

      final List<dynamic> formats = formatsRaw;

      // Keep only type == "video" && url not null/empty
      final videoFormats = <Map<String, dynamic>>[];
      for (final f in formats) {
        if (f is! Map<String, dynamic>) continue;
        final type = (f['type'] as String?)?.toLowerCase().trim() ?? '';
        if (type != 'video') continue; // ignore audio (url is null per spec)
        final u = f['url'];
        if (u == null) continue;
        if (u is! String) continue;
        if (u.trim().isEmpty) continue;
        videoFormats.add(f);
      }

      if (videoFormats.isEmpty) {
        // ignore: avoid_print
        print('[QuickSave] no video format for $shortcode formatsCount=${formats.length}');
        throw ReelException('VIDEO_URL_MISSING');
      }

      // Pick highest height
      Map<String, dynamic>? best;
      int bestHeight = -1;
      String bestUrl = '';
      String bestLabel = '';
      for (final f in videoFormats) {
        int h = 0;
        final hv = f['height'];
        if (hv is int) h = hv;
        else if (hv is num) h = hv.toInt();
        else if (hv is String) h = int.tryParse(hv) ?? 0;
        // if height missing, keep 0 but still consider
        final u = (f['url'] as String).trim();
        if (h > bestHeight) {
          bestHeight = h;
          best = f;
          bestUrl = u;
          bestLabel = (f['label'] as String?) ?? '';
        }
      }

      if (best == null || bestUrl.isEmpty) {
        throw ReelException('VIDEO_URL_MISSING');
      }

      // Extract optional meta
      final title = (data['title'] as String?) ?? '';
      final thumb = (data['thumbnail'] as String?) ?? '';
      final durationRaw = data['duration'];
      double duration = 0;
      if (durationRaw is num) duration = durationRaw.toDouble();
      else if (durationRaw is String) duration = double.tryParse(durationRaw) ?? 0;

      final uploader = (data['uploader'] as String?) ?? '';
      // Width/height fallback: we know height from best, width approximate 9:16 if unknown
      // Use best's height and try to infer width, else default 9x16 portrait
      int width = 9;
      int height = 16;
      if (bestHeight > 0) {
        height = bestHeight;
        // Instagram reels are typically 9:16 vertical; estimate width from height
        // If we have no width, keep 9:16 ratio: width = height * 9 / 16
        width = (height * 9 / 16).round();
        if (width == 0) width = 9;
      }

      // Validate Instagram CDN URL sanity (optional, not strict)
      // Must start with http
      if (!(bestUrl.startsWith('http://') || bestUrl.startsWith('https://'))) {
        throw ReelException('INSTAGRAM_ERROR');
      }

      // Clean thumbnail
      String thumbUrl = thumb.trim().replaceAll('&amp;', '&');

      // Clean title for caption
      String caption = InstagramService.cleanText(title);
      if (caption.length > 600) caption = caption.substring(0, 600);

      final cleanUploader = InstagramService.cleanText(uploader);

      // Log success (for debugging)
      // ignore: avoid_print
      print('[QuickSave] succeeded for $shortcode height=$bestHeight label=$bestLabel url=${bestUrl.substring(0, bestUrl.length > 80 ? 80 : bestUrl.length)}...');

      return {
        'ok': true,
        'shortcode': shortcode,
        'mediaType': 'video',
        'videoUrl': bestUrl,
        'imageUrls': <String>[],
        'thumbUrl': thumbUrl,
        'duration': duration,
        'width': width == 0 ? 9 : width,
        'height': height == 0 ? 16 : height,
        'author': cleanUploader,
        'caption': caption,
        'viewCount': 0,
        'permalink': 'https://www.instagram.com/reel/$shortcode/',
        // Extra fields for logging / UI compatibility with ServerService
        'platform': 'instagram',
        'title': title,
        'thumbnail': thumbUrl,
        'uploader': cleanUploader,
        'qualityLabel': bestLabel,
        'viaQuickSave': true,
        'source': 'quicksave.my',
      };
    } on ReelException {
      rethrow;
    } on TimeoutException {
      // ignore: avoid_print
      print('[QuickSave] timeout for $shortcode after ${_timeout.inSeconds}s');
      throw ReelException('INSTAGRAM_TIMEOUT');
    } on http.ClientException catch (e) {
      // ignore: avoid_print
      print('[QuickSave] ClientException for $shortcode: $e');
      throw ReelException('INSTAGRAM_UNREACHABLE');
    } catch (e) {
      // Any other unexpected error
      // ignore: avoid_print
      print('[QuickSave] unexpected error for $shortcode: $e');
      throw ReelException('INSTAGRAM_ERROR');
    }
  }

  /// Non-throwing wrapper: returns null on any failure (for callers that prefer null).
  static Future<Map<String, dynamic>?> tryFetchReelMeta(String shortcode) async {
    try {
      return await fetchReelMeta(shortcode);
    } catch (_) {
      return null;
    }
  }

  /// Non-throwing wrapper for URL variant.
  static Future<Map<String, dynamic>?> tryFetchByUrl(String instagramUrl) async {
    try {
      return await fetchByUrl(instagramUrl);
    } catch (_) {
      return null;
    }
  }
}
