// ignore_for_file: avoid_print
// JS bridge between assets/index.html and the Dart services —
// Dart port of the AndroidBridge @JavascriptInterface in
// MainActivity.java (v2.2–v3.13).

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'downloader.dart';
import 'instagram_service.dart';
import 'license_service.dart';
import 'preview_proxy.dart';
import 'quicksave_service.dart';
import 'updater.dart';

class Bridge {
  Bridge(this._controller, this._updater);

  final WebViewController _controller;
  final Updater _updater;

  final Map<String, bool> _quickSaveShortcodes = {};

  static const String shimScript = '''
(function () {
  if (window.AndroidBridge && window.AndroidBridge.checkReel) return;
  var ch = window.AndroidBridge;
  if (!ch || !ch.postMessage) return;
  function call(m, a) { ch.postMessage(JSON.stringify({m: m, a: a})); }
  window.AndroidBridge = {
    checkReel: function (code) { call('checkReel', [code]); },
    downloadReel: function (videoUrl, shortcode) { call('downloadReel', [videoUrl, shortcode]); },
    downloadMediaByCode: function (shortcode) { call('downloadMediaByCode', [shortcode]); },
    downloadMediaUrls: function (shortcode, mediaType, urlsJson) { call('downloadMediaUrls', [shortcode, mediaType, urlsJson]); },
    downloadUpdate: function (apkUrl) { call('downloadUpdate', [apkUrl]); },
    installUpdate: function () { call('installUpdate', []); },
    openPost: function (shortcode) { call('openPost', [shortcode]); },
    copyBio: function (text) { call('copyBio', [text]); },
    downloadProfilePic: function (url, username) { call('downloadProfilePic', [url, username]); },
    downloadPost: function (shortcode, thumbUrl, isVideo, videoUrl, hdUrl) { call('downloadPost', [shortcode, thumbUrl, isVideo, videoUrl, hdUrl]); },
    loadMorePosts: function () { call('loadMorePosts', []); },
    checkUpdateManually: function () { call('checkUpdateManually', []); },
    searchAccount: function (user) { call('searchAccount', [user]); }
  };
})();
''';

  Future<void> injectShim() async {
    try {
      await _controller.runJavaScript(shimScript);
    } catch (_) {}
  }

  Future<void> _runJs(String script) async {
    try {
      await _controller.runJavaScript(script);
    } catch (_) {}
  }

  Future<void> _postJson(String fn, Map<String, dynamic> payload) async {
    final json = jsonEncode(payload);
    await _runJs('window.$fn && $fn(${jsonEncode(json)});');
  }

  Future<void> _postCopyResult(bool ok) async {
    await _runJs('window.onCopyResult && onCopyResult($ok);');
  }

  Future<void> handleMessage(String message) async {
    try {
      final decoded = jsonDecode(message);
      if (decoded is! Map<String, dynamic>) return;
      final method = decoded['m'] as String?;
      if (method == null) return;
      final args = (decoded['a'] as List?) ?? [];
      switch (method) {
        case 'checkReel':
          await _checkReel(_arg(args, 0));
          break;
        case 'downloadReel':
          await _downloadReel(_arg(args, 0), _arg(args, 1));
          break;
        case 'downloadMediaByCode':
          await _downloadMediaByCode(_arg(args, 0));
          break;
        case 'downloadMediaUrls':
          await _downloadMediaUrls(_arg(args, 0), _arg(args, 1), _arg(args, 2));
          break;
        case 'downloadUpdate':
          await _updater.downloadUpdate(_arg(args, 0));
          break;
        case 'installUpdate':
          await _updater.installUpdate();
          break;
        case 'openPost':
          await _openPost(_arg(args, 0));
          break;
        case 'copyBio':
          await _copyBio(_arg(args, 0));
          break;
        case 'downloadProfilePic':
          await _downloadProfilePic(_arg(args, 0), _arg(args, 1));
          break;
        case 'downloadPost':
          await _downloadPost(
            _arg(args, 0),
            _arg(args, 1),
            args.length > 2 && args[2] == true,
            _arg(args, 3),
            _arg(args, 4),
          );
          break;
        case 'loadMorePosts':
          await _loadMorePosts();
          break;
        case 'checkUpdateManually':
          await _updater.checkUpdateManually();
          break;
        case 'searchAccount':
          await _searchAccount(_arg(args, 0));
          break;
      }
    } catch (_) {}
  }

  static String _arg(List<dynamic> args, int i) {
    if (i < args.length && args[i] is String) return args[i] as String;
    return '';
  }

  static String _cleanCode(String? raw) {
    if (raw == null) return '';
    return raw.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '');
  }

  /// Inline thumbnail as data URL so WebView preview works even when
  /// Instagram CDN blocks direct WebView request (needs UA/Referer).
  /// Tries 3 header sets: QuickSave (Chrome 139), Instagram (Safari), no headers.
  /// Falls back to original URL only if all fail — caller should show placeholder text.
  Future<void> _inlineThumbnail(Map<String, dynamic> result) async {
    final thumb = (result['thumbUrl'] as String?) ?? '';
    if (thumb.isEmpty || thumb.startsWith('data:')) return;
    // Header sets to try in order
    final headerSets = <Map<String, String>>[
      QuickSaveService.downloadHeaders,
      {
        'User-Agent': InstagramService.userAgents[0],
        'Referer': 'https://www.instagram.com/',
        'Accept': 'image/*,*/*;q=0.8',
        'Accept-Language': 'en-US,en;q=0.9',
      },
      {'Accept': 'image/*,*/*;q=0.8'}, // bare
    ];
    for (var i = 0; i < headerSets.length; i++) {
      try {
        debugPrint('[ReelChecker] thumb inline attempt ${i + 1}/3 for $thumb');
        final resp = await http
            .get(Uri.parse(thumb), headers: headerSets[i])
            .timeout(const Duration(seconds: 8));
        debugPrint('[ReelChecker] thumb attempt ${i + 1} status=${resp.statusCode} len=${resp.bodyBytes.length} ct=${resp.headers['content-type']}');
        if (resp.statusCode == 200 && resp.bodyBytes.length > 512) {
          final ct = (resp.headers['content-type'] ?? '').split(';').first.trim();
          final mime = ct.isNotEmpty && ct.startsWith('image/') ? ct : 'image/jpeg';
          final b64 = base64Encode(resp.bodyBytes);
          final dataUrl = 'data:$mime;base64,$b64';
          result['thumbUrl'] = dataUrl;
          result['thumbnail'] = dataUrl;
          result['posterUrl'] = dataUrl;
          debugPrint('[ReelChecker] thumb inlined ${resp.bodyBytes.length} bytes as $mime on attempt ${i + 1}');
          return;
        }
        // 403/404 on this header set — try next
        debugPrint('[ReelChecker] thumb attempt ${i + 1} failed status=${resp.statusCode}');
      } catch (e) {
        debugPrint('[ReelChecker] thumb inline attempt ${i + 1} error: $e');
      }
    }
    // All attempts failed — keep original URL but log for diagnostics
    debugPrint('[ReelChecker] thumb inline all attempts failed, keeping original URL (WebView will show broken poster, fallback will show placeholder)');
  }

  /// Video URL is now obtained ONLY via quicksave.my — the old
  /// downloader server has been removed completely. No fallback to
  /// server or Instagram extraction remains for video.
  Future<void> _checkReel(String shortcode) async {
    final code = _cleanCode(shortcode);
    if (code.isEmpty) {
      await _postJson('onReelResult', {'ok': false, 'error': 'REEL_NOT_FOUND'});
      return;
    }
    if (!await LicenseService.isAllowed()) {
      await _postJson('onReelResult', {'ok': false, 'error': 'NOT_LICENSED'});
      return;
    }
    try {
      final result = await QuickSaveService.fetchReelMeta(code);
      debugPrint('[ReelChecker] source: quicksave.my succeeded for $code height=${result['height']} label=${result['qualityLabel']}');
      _quickSaveShortcodes[code] = true;
      await _inlineThumbnail(result);
      // Proxy video for preview so <video> can stream with proper headers (CORS/referer fix)
      final vUrl = (result['videoUrl'] as String?) ?? '';
      if (vUrl.isNotEmpty) {
        final proxy = await PreviewProxy.register(code, vUrl);
        if (proxy != null) {
          result['previewUrl'] = proxy;
          // Keep original for download; previewUrl is what <video> will use
          result['videoUrlOriginal'] = vUrl;
          debugPrint('[ReelChecker] preview proxy $proxy for $code');
        }
      }
      await _postJson('onReelResult', result);
      return;
    } on ReelException catch (e) {
      debugPrint('[ReelChecker] source: quicksave.my failed for $code error=${e.code}');
      await _postJson('onReelResult', {'ok': false, 'error': e.code});
      return;
    } catch (e) {
      debugPrint('[ReelChecker] source: quicksave.my exception for $code: $e');
      await _postJson('onReelResult', {'ok': false, 'error': 'INSTAGRAM_ERROR'});
      return;
    }
  }

  Future<void> _searchAccount(String rawInput) async {
    try {
      final profile = await InstagramService.fetchAccountProfile(rawInput);
      await _postJson('onAccountResult', profile);
    } on AccountException catch (e) {
      await _postJson('onAccountResult', {'ok': false, 'error': e.code});
    } catch (_) {
      await _postJson('onAccountResult', {'ok': false, 'error': 'INSTAGRAM_ERROR'});
    }
  }

  Future<void> _loadMorePosts() async {
    final result = await InstagramService.loadMorePosts();
    await _postJson('onMorePosts', result);
  }

  Future<void> _openPost(String shortcode) async {
    final code = _cleanCode(shortcode);
    if (code.isEmpty) return;
    try {
      await launchUrl(
        Uri.parse('https://www.instagram.com/p/$code/'),
        mode: LaunchMode.externalApplication,
      );
    } catch (_) {}
  }

  Future<void> _copyBio(String text) async {
    try {
      await Clipboard.setData(ClipboardData(text: text));
      await _postCopyResult(true);
    } catch (_) {
      await _postCopyResult(false);
    }
  }

  static Future<Map<String, dynamic>> _downloadOne(
      String url, String fileName, String mimeType,
      {bool useQuickSaveUA = false}) {
    return Downloader.downloadMediaFile(url, fileName, mimeType,
        useQuickSaveUA: useQuickSaveUA);
  }

  Future<void> _downloadReel(String videoUrl, String shortcode) async {
    final code = _cleanCode(shortcode);
    if (code.isEmpty ||
        videoUrl.trim().isEmpty ||
        !(videoUrl.startsWith('http://') || videoUrl.startsWith('https://'))) {
      await _postJson('onDownloadResult', {'ok': false, 'error': 'NO_VIDEO_URL'});
      return;
    }
    final isQuickSave = _quickSaveShortcodes[code] == true;
    final res = await _downloadOne(videoUrl.trim(), '$code.mp4', 'video/mp4',
        useQuickSaveUA: isQuickSave);
    res['mediaType'] = 'video';
    await _postJson('onDownloadResult', res);
  }

  /// Video is now fetched ONLY via quicksave.my — no Instagram fallback.
  Future<Map<String, dynamic>?> _fetchMetaWithFallback(String code) async {
    if (!await LicenseService.isAllowed()) {
      throw ReelException('NOT_LICENSED');
    }
    final meta = await QuickSaveService.fetchReelMeta(code);
    debugPrint('[ReelChecker] fetchMeta quicksave succeeded for $code');
    meta['_viaQuickSave'] = true;
    _quickSaveShortcodes[code] = true;
    return meta;
  }

  Future<void> _downloadMediaByCode(String shortcode) async {
    final code = _cleanCode(shortcode);
    if (code.isEmpty) {
      await _postJson('onDownloadResult', {'ok': false, 'error': 'DOWNLOAD_FAILED'});
      return;
    }
    Map<String, dynamic> meta;
    try {
      final fetched = await _fetchMetaWithFallback(code);
      if (fetched == null) throw ReelException('INSTAGRAM_ERROR');
      meta = fetched;
    } catch (_) {
      await _postJson('onDownloadResult', {'ok': false, 'error': 'DOWNLOAD_FAILED'});
      return;
    }
    final isQuickSave = meta['_viaQuickSave'] == true;
    final mediaType = (meta['mediaType'] as String?) ?? 'video';
    if (mediaType == 'video') {
      final vUrl = (meta['videoUrl'] as String?) ?? '';
      if (vUrl.isEmpty) {
        await _postJson('onDownloadResult', {'ok': false, 'error': 'NO_VIDEO_URL'});
        return;
      }
      final res = await _downloadOne(vUrl, '$code.mp4', 'video/mp4',
          useQuickSaveUA: isQuickSave);
      res['mediaType'] = 'video';
      await _postJson('onDownloadResult', res);
      return;
    }
    final imgs = (meta['imageUrls'] as List?) ?? [];
    if (imgs.isEmpty) {
      await _postJson('onDownloadResult', {'ok': false, 'error': 'DOWNLOAD_FAILED'});
      return;
    }
    var done = 0;
    var lastFile = '';
    for (var i = 0; i < imgs.length; i++) {
      final u = imgs[i] as String? ?? '';
      if (u.isEmpty) continue;
      final fn = imgs.length > 1 ? '${code}_${i + 1}.jpg' : '$code.jpg';
      final res = await _downloadOne(u, fn, 'image/jpeg', useQuickSaveUA: isQuickSave);
      if (res['ok'] == true) {
        done++;
        lastFile = fn;
      }
    }
    if (done > 0) {
      await _postJson('onDownloadResult', {
        'ok': true,
        'mediaType': imgs.length > 1 ? 'carousel' : 'image',
        'count': done,
        'filename': lastFile,
      });
    } else {
      await _postJson('onDownloadResult', {'ok': false, 'error': 'DOWNLOAD_FAILED'});
    }
  }

  Future<void> _downloadMediaUrls(
      String shortcode, String mediaType, String urlsJson) async {
    final code = _cleanCode(shortcode);
    List<String> urls = [];
    try {
      final decoded = jsonDecode(urlsJson);
      if (decoded is List) {
        urls = decoded.map((e) => e.toString()).toList();
      }
    } catch (_) {}
    if (code.isEmpty || urls.isEmpty) {
      if (code.isNotEmpty) {
        await _downloadMediaByCode(shortcode);
      } else {
        await _postJson('onDownloadResult', {'ok': false, 'error': 'DOWNLOAD_FAILED'});
      }
      return;
    }
    final isVideo = mediaType == 'video';
    final isCarousel = mediaType == 'carousel';
    final isQuickSave = _quickSaveShortcodes[code] == true;
    var done = 0;
    var lastFile = '';
    for (var i = 0; i < urls.length; i++) {
      final u = urls[i];
      if (u.isEmpty || !(u.startsWith('http://') || u.startsWith('https://'))) continue;
      final String fn;
      final String mime;
      if (isVideo) {
        fn = '$code.mp4';
        mime = 'video/mp4';
      } else if (isCarousel || urls.length > 1) {
        fn = '${code}_${i + 1}.jpg';
        mime = 'image/jpeg';
      } else {
        fn = '$code.jpg';
        mime = 'image/jpeg';
      }
      final res = await _downloadOne(u, fn, mime, useQuickSaveUA: isQuickSave);
      if (res['ok'] == true) {
        done++;
        lastFile = fn;
      }
    }
    if (done > 0) {
      await _postJson('onDownloadResult', {
        'ok': true,
        'mediaType': isVideo ? 'video' : (isCarousel || urls.length > 1 ? 'carousel' : 'image'),
        'count': done,
        'filename': lastFile,
      });
    } else {
      await _postJson('onDownloadResult', {'ok': false, 'error': 'DOWNLOAD_FAILED'});
    }
  }

  Future<void> _downloadProfilePic(String url, String username) async {
    if (url.trim().isEmpty || !(url.startsWith('http://') || url.startsWith('https://'))) {
      await _postJson('onMediaDownloadResult', {'ok': false, 'error': 'NO_IMAGE'});
      return;
    }
    var clean = username.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '');
    if (clean.isEmpty) clean = 'profile';
    final res = await _downloadOne(url.trim(), '${clean}_profile.jpg', 'image/jpeg');
    await _postJson('onMediaDownloadResult', res);
  }

  Future<void> _downloadPost(String shortcode, String thumbUrl, bool isVideo,
      String videoUrl, String hdUrl) async {
    final code = _cleanCode(shortcode);
    if (code.isEmpty) {
      await _postJson('onMediaDownloadResult', {'ok': false, 'error': 'DOWNLOAD_FAILED'});
      return;
    }
    final hiRes = hdUrl.trim().isNotEmpty ? hdUrl.trim() : thumbUrl.trim();
    if (isVideo) {
      var vUrl = videoUrl.trim();
      bool viaQuickSave = false;
      if (vUrl.isEmpty) {
        try {
          final fetched = await _fetchMetaWithFallback(code);
          if (fetched != null) {
            vUrl = (fetched['videoUrl'] as String?) ?? '';
            viaQuickSave = fetched['_viaQuickSave'] == true;
          }
        } catch (_) {}
        if (!viaQuickSave) viaQuickSave = _quickSaveShortcodes[code] == true;
      } else {
        viaQuickSave = _quickSaveShortcodes[code] == true;
      }
      if (vUrl.isNotEmpty && (vUrl.startsWith('http://') || vUrl.startsWith('https://'))) {
        final res = await _downloadOne(vUrl, '$code.mp4', 'video/mp4',
            useQuickSaveUA: viaQuickSave);
        await _postJson('onMediaDownloadResult', res);
        return;
      }
      if (hiRes.isNotEmpty) {
        final res = await _downloadOne(hiRes, '$code.jpg', 'image/jpeg',
            useQuickSaveUA: viaQuickSave);
        res['imageOnly'] = true;
        await _postJson('onMediaDownloadResult', res);
        return;
      }
      await _postJson('onMediaDownloadResult', {'ok': false, 'error': 'DOWNLOAD_FAILED'});
      return;
    }
    if (hiRes.isEmpty) {
      await _postJson('onMediaDownloadResult', {'ok': false, 'error': 'NO_IMAGE'});
      return;
    }
    final res = await _downloadOne(hiRes, '$code.jpg', 'image/jpeg');
    await _postJson('onMediaDownloadResult', res);
  }
}
