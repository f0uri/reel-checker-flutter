// Preview proxy — streams Instagram CDN video through a local HTTP server
// so the <video> element in the WebView can play it.
// Instagram CDN requires Referer + UA headers that a plain <video src="https://...cdninstagram...">
// request from WebView won't send, so raw CDN URL shows blank/placeholder.
// Download via Downloader works because it sets headers via HttpClient.
// This proxy serves the same CDN content on http://127.0.0.1:<port>/preview/<shortcode>.mp4
// adding proper headers upstream and CORS headers downstream, so preview plays.
// Falls back gracefully if server can't start (e.g. iOS strict ATS) — caller should keep poster fallback.

import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'quicksave_service.dart';

class PreviewProxy {
  static HttpServer? _server;
  static int _port = 0;
  static final Map<String, String> _urlMap = {}; // shortcode -> cdnUrl
  static bool _starting = false;

  static int get port => _port;
  static bool get running => _server != null;

  static Future<String?> register(String shortcode, String cdnUrl) async {
    if (cdnUrl.isEmpty) return null;
    await _ensureServer();
    if (_server == null) {
      print('[PreviewProxy] register failed: server not running for $shortcode');
      return null;
    }
    _urlMap[shortcode] = cdnUrl;
    final url = 'http://127.0.0.1:$_port/preview/$shortcode.mp4';
    print('[PreviewProxy] registered $shortcode -> $url (cdn ${cdnUrl.substring(0, cdnUrl.length > 60 ? 60 : cdnUrl.length)}...)');
    return url;
  }

  static Future<void> _ensureServer() async {
    if (_server != null) return;
    if (_starting) {
      for (var i = 0; i < 20; i++) {
        await Future.delayed(const Duration(milliseconds: 100));
        if (_server != null || !_starting) break;
      }
      return;
    }
    _starting = true;
    try {
      // Try loopback first, then anyIPv4 as fallback (some OEMs block loopback bind)
      try {
        _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      } catch (e) {
        print('[PreviewProxy] loopback bind failed: $e, trying anyIPv4');
        _server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
      }
      _port = _server!.port;
      _server!.listen(_handleRequest);
      print('[PreviewProxy] listening on 127.0.0.1:$_port (anyIPv4 fallback if needed)');
    } catch (e) {
      print('[PreviewProxy] failed to start server: $e');
      _server = null;
      _port = 0;
    } finally {
      _starting = false;
    }
  }

  static Future<void> _handleRequest(HttpRequest req) async {
    try {
      // CORS preflight
      if (req.method == 'OPTIONS') {
        req.response.statusCode = 200;
        req.response.headers.set('Access-Control-Allow-Origin', '*');
        req.response.headers.set('Access-Control-Allow-Methods', 'GET, HEAD, OPTIONS');
        req.response.headers.set('Access-Control-Allow-Headers', 'Range, Content-Type, Referer, User-Agent');
        req.response.headers.set('Access-Control-Max-Age', '86400');
        await req.response.close();
        return;
      }

      final segs = req.uri.pathSegments;
      if (segs.length < 2 || segs[0] != 'preview') {
        req.response.statusCode = 404;
        await req.response.close();
        return;
      }
      // path is /preview/<shortcode>.mp4 -> extract code
      var code = segs[1];
      if (code.endsWith('.mp4')) code = code.substring(0, code.length - 4);
      final cdnUrl = _urlMap[code];
      if (cdnUrl == null || cdnUrl.isEmpty) {
        req.response.statusCode = 404;
        req.response.headers.set('Content-Type', 'text/plain');
        req.response.write('preview not registered for $code');
        await req.response.close();
        return;
      }

      final client = http.Client();
      try {
        final cReq = http.Request('GET', Uri.parse(cdnUrl));
        cReq.headers.addAll(QuickSaveService.downloadHeaders);
        // Forward Range for seeking
        final range = req.headers.value('range');
        if (range != null && range.isNotEmpty) {
          cReq.headers['Range'] = range;
        }

        final cResp = await client.send(cReq).timeout(const Duration(seconds: 30));

        // Propagate status (200 or 206)
        req.response.statusCode = cResp.statusCode;

        // Copy relevant headers
        cResp.headers.forEach((k, v) {
          final lk = k.toLowerCase();
          if (lk == 'content-type' ||
              lk == 'content-length' ||
              lk == 'content-range' ||
              lk == 'accept-ranges' ||
              lk == 'cache-control' ||
              lk == 'etag') {
            req.response.headers.set(k, v);
          }
        });
        // Ensure video type if missing
        if (req.response.headers.value('content-type') == null) {
          req.response.headers.set('Content-Type', 'video/mp4');
        }
        req.response.headers.set('Access-Control-Allow-Origin', '*');
        req.response.headers.set('Access-Control-Allow-Headers', 'Range');
        req.response.headers.set('Access-Control-Expose-Headers', 'Content-Range, Content-Length, Accept-Ranges');

        await req.response.addStream(cResp.stream);
        await req.response.close();
      } catch (e) {
        try {
          req.response.statusCode = 502;
          req.response.write('upstream error: $e');
          await req.response.close();
        } catch (_) {}
      } finally {
        client.close();
      }
    } catch (_) {
      try {
        req.response.statusCode = 500;
        await req.response.close();
      } catch (_) {}
    }
  }

  static void unregister(String shortcode) {
    _urlMap.remove(shortcode);
  }

  static Future<void> dispose() async {
    try {
      await _server?.close(force: true);
    } catch (_) {}
    _server = null;
    _port = 0;
    _urlMap.clear();
  }
}
