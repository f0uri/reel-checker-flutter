// ignore_for_file: avoid_print
// Listnr — PRIMARY video source — POST https://bff.listnr.tech/backend/user/getInfoYT
// No token, captcha or cookies needed: one POST returns the direct CDN
// video URL plus thumbnail. QuickSave remains the fallback when Listnr
// fails (see Bridge dual-source chain). Verified live 2026-11-12.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'instagram_service.dart';

class ListnrService {
  static const String _endpoint =
      'https://bff.listnr.tech/backend/user/getInfoYT';
  static const String userAgent =
      'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/139.0.0.0 Safari/537.36';
  static const Duration _timeout = Duration(seconds: 15);

  static const Map<String, String> _headers = {
    'accept': 'application/json, text/plain, */*',
    'content-type': 'application/json',
    'origin': 'https://listnr.ai',
    'referer': 'https://listnr.ai/',
    'user-agent': userAgent,
  };

  /// Fetch reel meta by shortcode. Returns a map compatible with
  /// QuickSaveService.fetchReelMeta (same keys; title/author/duration
  /// are empty because Listnr returns only the video URL + thumbnail).
  /// Throws ReelException on failure; see tryFetchReelMeta for the
  /// null-on-failure variant used by the fallback chain.
  static Future<Map<String, dynamic>> fetchReelMeta(String shortcode) async {
    final code = shortcode.trim();
    if (code.isEmpty) throw ReelException('REEL_NOT_FOUND');
    final instagramUrl = 'https://www.instagram.com/reel/$code/';
    try {
      final body = jsonEncode(
          {'url': instagramUrl, 'platform': 'instagram', 'type': 'video'});

      debugPrint('[Listnr] POST $_endpoint url=$instagramUrl');

      final resp = await http
          .post(Uri.parse(_endpoint), headers: _headers, body: body)
          .timeout(_timeout);

      if (resp.statusCode != 200) {
        debugPrint('[Listnr] failed for $code HTTP ${resp.statusCode}');
        if (resp.statusCode == 404) throw ReelException('REEL_NOT_FOUND');
        if (resp.statusCode == 429 || resp.statusCode == 403) {
          throw ReelException('INSTAGRAM_BLOCKED');
        }
        throw ReelException('INSTAGRAM_ERROR');
      }

      Map<String, dynamic> data;
      try {
        data = jsonDecode(resp.body) as Map<String, dynamic>;
      } catch (_) {
        debugPrint('[Listnr] invalid JSON for $code');
        throw ReelException('INSTAGRAM_ERROR');
      }

      final videoUrl = (data['url'] as String?)?.trim() ?? '';
      if (videoUrl.isEmpty) {
        debugPrint('[Listnr] no video url for $code dataKeys=${data.keys}');
        throw ReelException('VIDEO_URL_MISSING');
      }
      if (!(videoUrl.startsWith('http://') ||
          videoUrl.startsWith('https://'))) {
        throw ReelException('INSTAGRAM_ERROR');
      }

      final thumbRaw = (data['data'] as Map<String, dynamic>?)?['thumb'];
      final thumbUrl =
          (thumbRaw is String ? thumbRaw : '').trim().replaceAll('&amp;', '&');

      debugPrint(
          '[Listnr] succeeded for $code url=${videoUrl.substring(0, videoUrl.length > 80 ? 80 : videoUrl.length)}...');

      return {
        'ok': true,
        'shortcode': code,
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
        'permalink': 'https://www.instagram.com/reel/$code/',
        'platform': 'instagram',
        'title': '',
        'thumbnail': thumbUrl,
        'uploader': '',
        'qualityLabel': '',
        'viaQuickSave': false,
        'viaListnr': true,
        'source': 'listnr.ai',
      };
    } on ReelException {
      rethrow;
    } on TimeoutException {
      debugPrint('[Listnr] timeout for $code after ${_timeout.inSeconds}s');
      throw ReelException('INSTAGRAM_TIMEOUT');
    } on http.ClientException catch (e) {
      debugPrint('[Listnr] ClientException for $code: $e');
      throw ReelException('INSTAGRAM_UNREACHABLE');
    } catch (e) {
      debugPrint('[Listnr] unexpected error for $code: $e');
      throw ReelException('INSTAGRAM_ERROR');
    }
  }

  static Future<Map<String, dynamic>?> tryFetchReelMeta(
      String shortcode) async {
    try {
      return await fetchReelMeta(shortcode);
    } catch (_) {
      return null;
    }
  }
}
