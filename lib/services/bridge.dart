// JS bridge between assets/index.html and the Dart services —
// Dart port of the AndroidBridge @JavascriptInterface in
// MainActivity.java (v2.2–v3.13).
//
// The page calls window.AndroidBridge.<method>(...). webview_flutter
// exposes ONE JavaScriptChannel named "AndroidBridge" whose only
// method is postMessage, so a small shim (injected on page load)
// defines window.AndroidBridge with the same method names the HTML
// calls; each one posts JSON {m, a} to the channel, Dart dispatches
// it here, and the result goes back through the SAME callback names
// the HTML expects (onReelResult, onDownloadResult,
// onUpdateAvailable, onControlResult, onPostsResult, ...).
// Updater/APK-install callbacks live in updater.dart; this file only
// routes the updater's bridge methods to it.

import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'downloader.dart';
import 'instagram_service.dart';
import 'quicksave_service.dart';
import 'server_service.dart';
import 'updater.dart';

class Bridge {
  Bridge(this._controller, this._updater);

  final WebViewController _controller;
  final Updater _updater;

  // Track which shortcodes were resolved via quicksave.my fallback
  // so downloads use the same UA (spec: "Download the video URL with
  // the same user-agent header. The link is a temporary Instagram CDN
  // URL, so download right away and never cache it.").
  final Map<String, bool> _quickSaveShortcodes = {};

  /// Injected into the page after load. Captures the real channel
  /// object first, then replaces window.AndroidBridge with the
  /// method table the HTML calls. Re-injecting is a no-op once the
  /// shim is in place.
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

  /// Post a JSON payload to a page callback that takes one JSON
  /// string argument — same quoting as the Java code
  /// (JSONObject.quote(payload)).
  Future<void> _postJson(String fn, Map<String, dynamic> payload) async {
    final json = jsonEncode(payload);
    await _runJs('window.$fn && $fn(${jsonEncode(json)});');
  }

  Future<void> _postCopyResult(bool ok) async {
    await _runJs('window.onCopyResult && onCopyResult($ok);');
  }

  /// Entry point for the JavaScriptChannel: one JSON message
  /// {m: method, a: [args]}. Never throws into the channel.
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

  // ================= reel / account =================

  /// Fetch reel meta with fallback order: primary -> quicksave.my -> error.
  /// Primary is: server (yt-dlp) -> InstagramService (embed/GraphQL/p page).
  /// QuickSave is used ONLY when primary fails (error/timeout/no video URL).
  /// Logs which source succeeded for debugging.
  Future<void> _checkReel(String shortcode) async {
    final code = _cleanCode(shortcode);
    if (code.isEmpty) {
      await _postJson('onReelResult', {'ok': false, 'error': 'REEL_NOT_FOUND'});
      return;
    }
    // Server first (yt-dlp handles Instagram reliably); in-app
    // extraction is the fallback when the server is not configured
    // or fails. Any server failure is silent — never worse than before.
    try {
      await ServerService.ensureLoaded();
      final viaServer = await ServerService.parseMedia(
          'https://www.instagram.com/reel/$code/');
      if (viaServer != null) {
        // ignore: avoid_print
        print('[ReelChecker] source: server succeeded for $code');
        _quickSaveShortcodes[code] = false;
        await _postJson('onReelResult', viaServer);
        return;
      } else {
        // ignore: avoid_print
        print('[ReelChecker] source: server failed/null for $code -> trying primary Instagram');
      }
    } catch (e) {
      // ignore: avoid_print
      print('[ReelChecker] source: server error for $code: $e -> trying primary Instagram');
    }

    // Primary Instagram extraction
    String? lastPrimaryError;
    try {
      final meta = await InstagramService.fetchReelMeta(code);
      // ignore: avoid_print
      print('[ReelChecker] source: primary (InstagramService) succeeded for $code');
      _quickSaveShortcodes[code] = false;
      await _postJson('onReelResult', meta);
      return;
    } on ReelException catch (e) {
      lastPrimaryError = e.code;
      // ignore: avoid_print
      print('[ReelChecker] source: primary failed for $code error=${e.code} -> trying fallback quicksave.my');
    } catch (e) {
      lastPrimaryError = 'INSTAGRAM_ERROR';
      // ignore: avoid_print
      print('[ReelChecker] source: primary exception for $code: $e -> trying fallback quicksave.my');
    }

    // FALLBACK: quicksave.my (only when primary fails)
    try {
      final fallback = await QuickSaveService.fetchReelMeta(code);
      // ignore: avoid_print
      print('[ReelChecker] source: quicksave.my succeeded for $code height=${fallback['height']} label=${fallback['qualityLabel']}');
      _quickSaveShortcodes[code] = true;
      await _postJson('onReelResult', fallback);
      return;
    } on ReelException catch (e) {
      // ignore: avoid_print
      print('[ReelChecker] source: quicksave.my failed for $code error=${e.code}');
      await _postJson('onReelResult', {'ok': false, 'error': e.code});
      return;
    } catch (e) {
      // ignore: avoid_print
      print('[ReelChecker] source: quicksave.my exception for $code: $e');
      await _postJson(
          'onReelResult', {'ok': false, 'error': lastPrimaryError ?? 'INSTAGRAM_ERROR'});
      return;
    }
  }

  Future<void> _searchAccount(String rawInput) async {
    try {
      final profile = await InstagramService.fetchAccountProfile(rawInput);
      await _postJson('onAccountResult', profile);
    } on AccountException catch (e) {
      await _postJson(
          'onAccountResult', {'ok': false, 'error': e.code});
    } catch (_) {
      await _postJson(
          'onAccountResult', {'ok': false, 'error': 'INSTAGRAM_ERROR'});
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

  // ================= downloads =================

  /// One media file via the Downloader (temp file + native
  /// MediaStore on Android, documents + share sheet on iOS).
  static Future<Map<String, dynamic>> _downloadOne(
      String url, String fileName, String mimeType,
      {bool useQuickSaveUA = false}) {
    return Downloader.downloadMediaFile(url, fileName, mimeType,
        useQuickSaveUA: useQuickSaveUA);
  }

  /// Download a reel by its video URL (legacy path — the page now
  /// uses downloadMediaUrls / downloadMediaByCode).
  Future<void> _downloadReel(String videoUrl, String shortcode) async {
    final code = _cleanCode(shortcode);
    if (code.isEmpty ||
        videoUrl.trim().isEmpty ||
        !(videoUrl.startsWith('http://') ||
            videoUrl.startsWith('https://'))) {
      await _postJson(
          'onDownloadResult', {'ok': false, 'error': 'NO_VIDEO_URL'});
      return;
    }
    final isQuickSave = _quickSaveShortcodes[code] == true;
    final res = await _downloadOne(videoUrl.trim(), '$code.mp4', 'video/mp4',
        useQuickSaveUA: isQuickSave);
    res['mediaType'] = 'video';
    await _postJson('onDownloadResult', res);
  }

  /// Helper: fetch meta with fallback (InstagramService -> QuickSaveService)
  /// Returns map with extra key "_viaQuickSave" bool for download UA.
  Future<Map<String, dynamic>?> _fetchMetaWithFallback(String code) async {
    String? lastError;
    try {
      final meta = await InstagramService.fetchReelMeta(code);
      // ignore: avoid_print
      print('[ReelChecker] fetchMeta primary succeeded for $code');
      meta['_viaQuickSave'] = false;
      return meta;
    } on ReelException catch (e) {
      lastError = e.code;
      // ignore: avoid_print
      print('[ReelChecker] fetchMeta primary failed for $code error=${e.code} -> trying quicksave');
    } catch (e) {
      lastError = 'INSTAGRAM_ERROR';
      // ignore: avoid_print
      print('[ReelChecker] fetchMeta primary exception for $code: $e');
    }
    // Fallback to quicksave for video only
    try {
      final fb = await QuickSaveService.fetchReelMeta(code);
      // ignore: avoid_print
      print('[ReelChecker] fetchMeta quicksave fallback succeeded for $code');
      fb['_viaQuickSave'] = true;
      _quickSaveShortcodes[code] = true;
      return fb;
    } on ReelException catch (e) {
      // ignore: avoid_print
      print('[ReelChecker] fetchMeta quicksave failed for $code error=${e.code}');
      // Preserve last primary error if quicksave also fails but has less specific message
      // Throw lastError's equivalent
      if (lastError == 'REEL_TOO_LONG') throw ReelException(lastError!);
      throw ReelException(e.code);
    } catch (_) {
      throw ReelException(lastError ?? 'INSTAGRAM_ERROR');
    }
  }

  /// Download a post by shortcode: fresh meta first (CDN links are
  /// signed and expire), video → mp4, image/carousel → jpg per
  /// image. Same filenames as the Java code.
  /// Fallback order: primary -> quicksave.my -> error.
  Future<void> _downloadMediaByCode(String shortcode) async {
    final code = _cleanCode(shortcode);
    if (code.isEmpty) {
      await _postJson(
          'onDownloadResult', {'ok': false, 'error': 'DOWNLOAD_FAILED'});
      return;
    }
    Map<String, dynamic> meta;
    try {
      final fetched = await _fetchMetaWithFallback(code);
      if (fetched == null) throw ReelException('INSTAGRAM_ERROR');
      meta = fetched;
    } catch (_) {
      await _postJson(
          'onDownloadResult', {'ok': false, 'error': 'DOWNLOAD_FAILED'});
      return;
    }
    final isQuickSave = meta['_viaQuickSave'] == true;
    final mediaType = (meta['mediaType'] as String?) ?? 'video';
    if (mediaType == 'video') {
      final vUrl = (meta['videoUrl'] as String?) ?? '';
      if (vUrl.isEmpty) {
        await _postJson(
            'onDownloadResult', {'ok': false, 'error': 'NO_VIDEO_URL'});
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
      await _postJson(
          'onDownloadResult', {'ok': false, 'error': 'DOWNLOAD_FAILED'});
      return;
    }
    var done = 0;
    var lastFile = '';
    for (var i = 0; i < imgs.length; i++) {
      final u = imgs[i] as String? ?? '';
      if (u.isEmpty) continue;
      final fn = imgs.length > 1 ? '${code}_${i + 1}.jpg' : '$code.jpg';
      final res = await _downloadOne(u, fn, 'image/jpeg',
          useQuickSaveUA: isQuickSave);
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
      await _postJson(
          'onDownloadResult', {'ok': false, 'error': 'DOWNLOAD_FAILED'});
    }
  }

  /// Download the exact URLs the page previewed (v3.6): no re-fetch
  /// — re-fetching could return a different image (429 → cropped
  /// og:image, or the biggest image of another post's window).
  /// Empty URL list falls back to the by-code path.
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
        await _postJson(
            'onDownloadResult', {'ok': false, 'error': 'DOWNLOAD_FAILED'});
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
      if (u.isEmpty ||
          !(u.startsWith('http://') || u.startsWith('https://'))) {
        continue;
      }
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
        'mediaType': isVideo
            ? 'video'
            : (isCarousel || urls.length > 1 ? 'carousel' : 'image'),
        'count': done,
        'filename': lastFile,
      });
    } else {
      await _postJson(
          'onDownloadResult', {'ok': false, 'error': 'DOWNLOAD_FAILED'});
    }
  }

  /// Profile picture to Downloads as <username>_profile.jpg.
  /// The page passes the HD URL when available (v3.13).
  Future<void> _downloadProfilePic(String url, String username) async {
    if (url.trim().isEmpty ||
        !(url.startsWith('http://') || url.startsWith('https://'))) {
      await _postJson(
          'onMediaDownloadResult', {'ok': false, 'error': 'NO_IMAGE'});
      return;
    }
    var clean = username.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '');
    if (clean.isEmpty) clean = 'profile';
    final res =
        await _downloadOne(url.trim(), '${clean}_profile.jpg', 'image/jpeg');
    await _postJson('onMediaDownloadResult', res);
  }

  /// Download a post from the account grid: video → mp4 from
  /// videoUrl, image → jpg from the HD URL (not the thumbnail).
  /// If the video URL is missing, one attempt fetches fresh meta
  /// (primary -> quicksave fallback); if the video still cannot be
  /// downloaded, the HD image is downloaded instead and flagged
  /// imageOnly=true.
  Future<void> _downloadPost(String shortcode, String thumbUrl, bool isVideo,
      String videoUrl, String hdUrl) async {
    final code = _cleanCode(shortcode);
    if (code.isEmpty) {
      await _postJson(
          'onMediaDownloadResult', {'ok': false, 'error': 'DOWNLOAD_FAILED'});
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
        // Also check cached flag
        if (!viaQuickSave) viaQuickSave = _quickSaveShortcodes[code] == true;
      } else {
        viaQuickSave = _quickSaveShortcodes[code] == true;
      }
      if (vUrl.isNotEmpty &&
          (vUrl.startsWith('http://') || vUrl.startsWith('https://'))) {
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
      await _postJson(
          'onMediaDownloadResult', {'ok': false, 'error': 'DOWNLOAD_FAILED'});
      return;
    }
    if (hiRes.isEmpty) {
      await _postJson(
          'onMediaDownloadResult', {'ok': false, 'error': 'NO_IMAGE'});
      return;
    }
    final res = await _downloadOne(hiRes, '$code.jpg', 'image/jpeg');
    await _postJson('onMediaDownloadResult', res);
  }
}
