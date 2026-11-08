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
import 'services/platform.dart';
import 'services/server_service.dart';
import 'services/updater.dart';

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
    _bridge = Bridge(_controller, _updater);
    _controller.addJavaScriptChannel(
      'AndroidBridge',
      onMessageReceived: (message) {
        unawaited(_bridge.handleMessage(message.message));
      },
    );
    _updater.attach(_controller);
    unawaited(_updater.restoreBlockedState());
    // Warm the downloader server in the background so the first
    // check doesn't pay the ~40 s wake-up wait.
    unawaited(ServerService.warmUp());
    unawaited(_controller.loadFlutterAsset('assets/index.html'));
  }

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
