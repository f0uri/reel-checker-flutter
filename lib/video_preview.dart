import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import 'services/quicksave_service.dart';

/// Native player avoids WebView's cross-origin restrictions. The URL is the
/// same temporary URL used by the downloader; never log its signed query.
class VideoPreviewPage extends StatefulWidget {
  const VideoPreviewPage({super.key, required this.url});

  final Uri url;

  @override
  State<VideoPreviewPage> createState() => _VideoPreviewPageState();
}

class _VideoPreviewPageState extends State<VideoPreviewPage> {
  late VideoPlayerController _controller;
  int _attempt = 0;
  String? _error;

  @override
  void initState() {
    super.initState();
    _start();
  }

  void _start() {
    final attempt = ++_attempt;
    final controller = VideoPlayerController.networkUrl(
      widget.url,
      httpHeaders: QuickSaveService.downloadHeaders,
    );
    _controller = controller;
    _error = null;
    controller.addListener(_onPlayerChanged);
    unawaited(_initialize(controller, attempt));
  }

  Future<void> _initialize(VideoPlayerController controller, int attempt) async {
    try {
      await controller.initialize().timeout(const Duration(seconds: 30));
      if (!mounted || attempt != _attempt) return;
      await controller.play();
    } catch (error) {
      if (!mounted || attempt != _attempt) return;
      _showError(error.toString());
    }
  }

  void _onPlayerChanged() {
    final value = _controller.value;
    if (value.hasError && _error == null) {
      _showError(value.errorDescription ?? 'unknown');
    }
  }

  void _showError(String details) {
    // Print a category only: signed media URLs can be present in exceptions.
    final lower = details.toLowerCase();
    final category = lower.contains('403')
        ? 'http_403'
        : lower.contains('decoder') || lower.contains('codec')
            ? 'decoder'
            : lower.contains('timeout')
                ? 'timeout'
                : 'other';
    debugPrint('[VideoPreview] playback failed: $category');
    if (mounted) setState(() => _error = category);
  }

  void _retry() {
    final previous = _controller;
    previous.removeListener(_onPlayerChanged);
    unawaited(previous.dispose());
    setState(_start);
  }

  @override
  void dispose() {
    _attempt++;
    _controller.removeListener(_onPlayerChanged);
    unawaited(_controller.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(title: const Text('معاينة الريل')),
        body: SafeArea(
          child: Center(
            child: _error != null
                ? _errorView()
                : ValueListenableBuilder<VideoPlayerValue>(
                    valueListenable: _controller,
                    builder: (context, value, _) {
                      if (!value.isInitialized) {
                        return const CircularProgressIndicator();
                      }
                      return Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Flexible(
                            child: AspectRatio(
                              aspectRatio: value.aspectRatio,
                              child: VideoPlayer(_controller),
                            ),
                          ),
                          VideoProgressIndicator(
                            _controller,
                            allowScrubbing: true,
                            padding: const EdgeInsets.symmetric(
                                horizontal: 16, vertical: 12),
                          ),
                          IconButton(
                            color: Colors.white,
                            iconSize: 40,
                            tooltip: value.isPlaying ? 'إيقاف مؤقت' : 'تشغيل',
                            icon: Icon(value.isPlaying
                                ? Icons.pause_circle
                                : Icons.play_circle),
                            onPressed: () {
                              if (value.isPlaying) {
                                unawaited(_controller.pause());
                              } else {
                                unawaited(_controller.play());
                              }
                            },
                          ),
                        ],
                      );
                    },
                  ),
          ),
        ),
      ),
    );
  }

  Widget _errorView() {
    final hint = _error == 'http_403'
        ? 'السيرفر رفض طلب المعاينة. عاود التحقق من الرابط.'
        : _error == 'decoder'
            ? 'الهاتف ما قدرش يقرأ صيغة الفيديو.'
            : 'ما قدرناش نشغلو المعاينة. تحقق من الإنترنت أو عاود التحقق من الرابط.';
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.error_outline, color: Colors.white, size: 48),
          const SizedBox(height: 16),
          Text(hint,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white)),
          const SizedBox(height: 8),
          const Text('تقدر ترجع وتحاول تنزيل الريل.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white70)),
          const SizedBox(height: 16),
          FilledButton(onPressed: _retry, child: const Text('عاود المحاولة')),
        ],
      ),
    );
  }
}
