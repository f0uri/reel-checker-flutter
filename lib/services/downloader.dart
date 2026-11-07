// Media downloads — Dart port of MainActivity.downloadMediaFile /
// downloadViaMediaStoreManual (v3.5).
//
// Flow: Dart downloads the URL to a temp file with the browser headers
// (Instagram's CDN returns 403 on a bare request), then hands the file
// to the native side to place it in the public Downloads folder
// (Android: MediaStore.Downloads via MethodChannel; iOS: app documents
// + the system share sheet, since iOS has no public Downloads folder).
// Files under 1024 bytes are rejected, exactly like the Java code.

import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import 'instagram_service.dart';
import 'platform.dart';

class Downloader {
  static const int _connectTimeoutMs = 30000;
  static const int _readTimeoutMs = 60000;

  static Map<String, String> get _headers => {
        'User-Agent': InstagramService.userAgents[0],
        'Referer': 'https://www.instagram.com/',
        'Accept-Language': 'en-US,en;q=0.9',
      };

  /// Download [url] to the public Downloads folder as [fileName].
  /// Returns {"ok":true,"filename":...,"size":...} or
  /// {"ok":false,"error":"DOWNLOAD_FAILED"} — same shape as the Java
  /// downloadMediaFile.
  static Future<Map<String, dynamic>> downloadMediaFile(
      String url, String fileName, String? mimeType) async {
    try {
      final tmp = await _downloadToTemp(url);
      if (tmp == null) {
        return {'ok': false, 'error': 'DOWNLOAD_FAILED'};
      }
      final size = await tmp.length();
      if (Platform.isAndroid) {
        final ok = await NativePlatform.saveToDownloads(
            tmp.path, fileName, mimeType ?? 'application/octet-stream');
        await tmp.delete().catchError((_) => tmp);
        if (!ok) return {'ok': false, 'error': 'DOWNLOAD_FAILED'};
        return {'ok': true, 'filename': fileName, 'size': size};
      }
      if (Platform.isIOS) {
        final dir = await getApplicationDocumentsDirectory();
        final dest = File('${dir.path}/$fileName');
        await tmp.copy(dest.path);
        await tmp.delete().catchError((_) => tmp);
        // iOS has no public Downloads folder: hand the file to the
        // user through the system share sheet ("Save to Files").
        await Share.shareXFiles([XFile(dest.path)],
            text: fileName);
        return {'ok': true, 'filename': fileName, 'size': size};
      }
      await tmp.delete().catchError((_) => tmp);
      return {'ok': false, 'error': 'DOWNLOAD_FAILED'};
    } catch (_) {
      return {'ok': false, 'error': 'DOWNLOAD_FAILED'};
    }
  }

  /// Stream [url] to a temp file. Returns null on any failure, or if
  /// the file is under 1024 bytes (same guard as the Java code).
  static Future<File?> _downloadToTemp(String url) async {
    http.Client? client;
    try {
      client = http.Client();
      final req = http.Request('GET', Uri.parse(url));
      req.headers.addAll(_headers);
      final resp = await client
          .send(req)
          .timeout(const Duration(milliseconds: _connectTimeoutMs));
      if (resp.statusCode < 200 || resp.statusCode >= 300) return null;
      final dir = await getTemporaryDirectory();
      final tmp = File(
          '${dir.path}/rc_${DateTime.now().millisecondsSinceEpoch}.tmp');
      final sink = tmp.openWrite();
      var total = 0;
      await for (final chunk in resp.stream
          .timeout(const Duration(milliseconds: _readTimeoutMs))) {
        sink.add(chunk);
        total += chunk.length;
      }
      await sink.close();
      if (total < 1024) {
        await tmp.delete().catchError((_) => tmp);
        return null;
      }
      return tmp;
    } catch (_) {
      return null;
    } finally {
      client?.close();
    }
  }
}
