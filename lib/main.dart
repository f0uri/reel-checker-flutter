// تنزيل ريلزات — Flutter (Android + iOS).
// Same UI as the native app: the local assets/index.html in a
// WebView, with the AndroidBridge JS channel dispatching to the Dart
// services. Light edge-to-edge UI, no ads.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'services/bridge.dart';
import 'services/license_service.dart';
import 'services/platform.dart';
import 'services/security.dart';
import 'services/updater.dart';
import 'video_preview.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.dark,
    statusBarBrightness: Brightness.light,
    systemNavigationBarColor: Colors.white,
    systemNavigationBarIconBrightness: Brightness.dark,
  ));
  runApp(const ReelCheckerApp());
}

class ReelCheckerApp extends StatelessWidget {
  const ReelCheckerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'تنزيل ريلزات',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.light,
        scaffoldBackgroundColor: Colors.white,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFFB8860B),
          brightness: Brightness.light,
        ),
        useMaterial3: true,
      ),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  late final WebViewController _controller;
  late final Updater _updater;
  late final Bridge _bridge;
  bool _pageReady = false;
  bool _previewOpen = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _updater = Updater();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.white)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageFinished: _onPageFinished,
        ),
      );
    _bridge = Bridge(_controller, _updater, onOpenPreview: _openPreview);
    _controller.addJavaScriptChannel(
      'AndroidBridge',
      onMessageReceived: (message) {
        unawaited(_bridge.handleMessage(message.message));
      },
    );
    _updater.attach(_controller);
    unawaited(_updater.restoreBlockedState());
    unawaited(_initApp());
  }

  Future<void> _openPreview(Uri url) async {
    if (!mounted || _previewOpen) return;
    _previewOpen = true;
    try {
      await Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => VideoPreviewPage(url: url),
      ));
    } finally {
      _previewOpen = false;
    }
  }

  /// v4.4.6: a build that is not signed with our key shows a
  /// blocked page and never loads the real UI. The license verdict
  /// is refreshed in the background (cached, so a sleeping server
  /// never delays launch).
  Future<void> _initApp() async {
    if (!await SecurityService.isGenuineBuild()) {
      await _controller.loadHtmlString(_blockedHtml);
      return;
    }
    unawaited(LicenseService.refresh());
    await _controller.loadFlutterAsset('assets/index.html');
  }

  static const String _blockedHtml = '''
<!DOCTYPE html><html lang="ar" dir="rtl"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>تنزيل ريلزات</title><style>
body{margin:0;min-height:100vh;display:flex;align-items:center;justify-content:center;background:#fff;font-family:system-ui;color:#1c1c1e;text-align:center;padding:24px;box-sizing:border-box}
h1{font-size:22px;margin:0 0 12px}p{font-size:15px;color:rgba(0,0,0,.6);margin:0;line-height:1.7}
</style></head><body><div><h1>هاد النسخة ماشي أصلية</h1>
<p>هاد التطبيق خاص بصاحبو — نزّل النسخة الأصلية من المصدر الرسمي.</p></div></body></html>
''';

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_updater.onResume());
      if (_pageReady) unawaited(_handleSharedText());
    }
  }

  Future<void> _onPageFinished(String url) async {
    // Only the local UI page gets the bridge + updater lifecycle.
    if (!url.contains('index.html')) return;
    _pageReady = true;
    await _bridge.injectShim();
    await _updater.onPageLoaded();
    await _handleSharedText();
  }

  /// Text shared from Instagram (ACTION_SEND): put the link in the
  /// input and run the page's own check, exactly like typing it.
  Future<void> _handleSharedText() async {
    final text = await NativePlatform.getSharedText();
    if (text == null || text.trim().isEmpty) return;
    try {
      // jsonEncode gives a safely quoted JS string literal.
      final quoted = jsonEncode(text.trim());
      await _controller.runJavaScript(
        "var _i = document.getElementById('input');"
        'if (_i) { _i.value = $quoted; }'
        "if (typeof check === 'function') check();",
      );
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        if (await _controller.canGoBack()) {
          await _controller.goBack();
        } else {
          if (context.mounted) Navigator.of(context).pop();
        }
      },
      child: Scaffold(
        backgroundColor: Colors.white,
        body: WebViewWidget(controller: _controller),
      ),
    );
  }
}
