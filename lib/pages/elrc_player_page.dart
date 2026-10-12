import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../services/elrc_client.dart';
import '../widgets/media_player_scaffold.dart';

class ElrcPlayerPage extends StatelessWidget {
  const ElrcPlayerPage({
    super.key,
    required this.courseName,
    required this.lessonTitle,
    required this.referer,
    required this.sources,
    this.cookie,
  });

  final String courseName;
  final String lessonTitle;
  final Uri referer;
  final List<ElrcSource> sources;
  final String? cookie;

  @override
  Widget build(BuildContext context) => defaultTargetPlatform == TargetPlatform.macOS ||
          defaultTargetPlatform == TargetPlatform.windows
      ? _ElrcDesktopPlayerPage(
          courseName: courseName,
          lessonTitle: lessonTitle,
          referer: referer,
          sources: sources,
          cookie: cookie,
        )
      : _ElrcMobilePlayerPage(
          courseName: courseName,
          lessonTitle: lessonTitle,
          referer: referer,
          sources: sources,
        );
}

class _ElrcMobilePlayerPage extends StatefulWidget {
  const _ElrcMobilePlayerPage({
    required this.courseName,
    required this.lessonTitle,
    required this.referer,
    required this.sources,
  });

  final String courseName;
  final String lessonTitle;
  final Uri referer;
  final List<ElrcSource> sources;

  @override
  State<_ElrcMobilePlayerPage> createState() => _ElrcMobilePlayerState();
}

class _ElrcMobilePlayerState extends State<_ElrcMobilePlayerPage> {
  late final WebViewController _controller;
  var _selected = 0;
  var _loading = true;
  var _closing = false;
  var _loadGeneration = 0;
  var _readyGeneration = 0;
  var _hasPlaybackState = false;
  Timer? _loadTimeout;
  Future<void>? _stopPlaybackFuture;
  double _resumeSeconds = 0;
  bool _resumePlaying = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController();
    unawaited(_prepare());
  }

  Future<void> _prepare() async {
    await _controller.setJavaScriptMode(JavaScriptMode.unrestricted);
    await _controller.addJavaScriptChannel(
      'TechPiePlayer',
      onMessageReceived: _playerMessage,
    );
    await _controller.setNavigationDelegate(
      NavigationDelegate(
        onNavigationRequest: (request) {
          final uri = Uri.tryParse(request.url);
          if (request.url == 'about:blank' ||
              (uri?.scheme == 'https' && uri?.host == 'elrc.shanghaitech.edu.cn')) {
            return NavigationDecision.navigate;
          }
          return NavigationDecision.prevent;
        },
        onPageFinished: _mediaDocumentReady,
        onWebResourceError: _webResourceFailed,
      ),
    );
    await _load(0, preservePlayback: false);
  }

  Future<void> _load(int index, {bool preservePlayback = true}) async {
    if (!mounted || _closing || index < 0 || index >= widget.sources.length) return;
    if (preservePlayback) await _rememberPlayback();
    if (!mounted || _closing) return;
    final generation = ++_loadGeneration;
    _loadTimeout?.cancel();
    _loadTimeout = Timer(
      const Duration(seconds: 30),
      () => _loadTimedOut(generation),
    );
    setState(() {
      _selected = index;
      _loading = true;
      _error = null;
    });
    try {
      await _controller.loadRequest(
        widget.sources[index].uri,
        headers: {'Referer': widget.referer.toString()},
      );
    } catch (_) {
      if (_isCurrent(generation)) {
        _loadTimeout?.cancel();
        _trace('request failed before WebKit accepted it');
        setState(() {
          _loading = false;
          _error = '视频加载失败';
        });
      }
    }
  }

  Future<void> _rememberPlayback() async {
    try {
      final result = await _controller.runJavaScriptReturningResult('''
JSON.stringify((() => {
  const video = document.querySelector('video');
  if (!video) return {};
  return {
    seconds: Number.isFinite(video.currentTime) ? video.currentTime : 0,
    playing: !video.paused && !video.ended,
  };
})())
''');
      final decoded = jsonDecode(result.toString());
      if (decoded is! Map<String, dynamic>) return;
      final seconds = decoded['seconds'];
      final playing = decoded['playing'];
      if (seconds is num && seconds.isFinite && seconds >= 0) {
        _resumeSeconds = seconds.toDouble();
        _hasPlaybackState = true;
      }
      if (playing is bool) {
        _resumePlaying = playing;
        _hasPlaybackState = true;
      }
      _trace(
        'remembered position=${_resumeSeconds.toStringAsFixed(1)}s '
        'playing=$_resumePlaying',
      );
    } catch (_) {
      _trace('playback state was not readable');
    }
  }

  void _mediaDocumentReady(String url) {
    if (!_matchesCurrentMedia(url)) {
      _trace('ignored retired media document');
      return;
    }
    _mediaReady(_loadGeneration, 'media document ready');
  }

  void _mediaReady(int generation, String reason) {
    if (!_isCurrent(generation) || _readyGeneration == generation) return;
    _readyGeneration = generation;
    _trace(reason);
    _showPlayer(generation);
    unawaited(_restorePlayback(generation));
  }

  void _webResourceFailed(WebResourceError failure) {
    _trace(
      'resource callback main=${failure.isForMainFrame} '
      'code=${failure.errorCode} type=${failure.errorType?.name}',
    );
    if (failure.isForMainFrame != true || _closing || !mounted) return;
    if (!_matchesCurrentMedia(failure.url)) {
      _trace('ignored callback from retired media');
      return;
    }

    // WKWebView reports direct video documents as WebKit error 204 when AVKit
    // takes over playback. The video is usable; this callback is its success path.
    if (defaultTargetPlatform == TargetPlatform.iOS && failure.errorCode == 204) {
      _mediaReady(_loadGeneration, 'native player accepted the media document');
      return;
    }

    // Replacing a media document can cancel the retired navigation.
    if (failure.errorCode == -999 ||
        (defaultTargetPlatform == TargetPlatform.iOS && failure.errorCode == 102)) {
      _trace('ignored retired media navigation');
      return;
    }

    _loadTimeout?.cancel();
    setState(() {
      _loading = false;
      _error = '视频加载失败';
    });
  }

  bool _matchesCurrentMedia(String? url) =>
      url == null || url == widget.sources[_selected].uri.toString();

  void _loadTimedOut(int generation) {
    if (!_isCurrent(generation) || _readyGeneration == generation) return;
    _trace('load timed out after 30 seconds');
    setState(() {
      _loading = false;
      _error = '视频加载超时';
    });
  }

  void _showPlayer(int generation) {
    if (!_isCurrent(generation)) return;
    _loadTimeout?.cancel();
    setState(() {
      _loading = false;
      _error = null;
    });
  }

  Future<void> _restorePlayback(int generation) async {
    if (!_isCurrent(generation) || !_hasPlaybackState) return;
    final seconds = _resumeSeconds;
    final resumePlaying = _resumePlaying;
    try {
      await _controller.runJavaScript('''
(() => {
  let attempts = 0;
  const restore = () => {
    if (window.techPiePlayerClosed) return true;
    const video = document.querySelector('video');
    if (!video || video.readyState < 1) return false;
    const duration = Number.isFinite(video.duration) ? video.duration : $seconds;
    video.currentTime = Math.min($seconds, Math.max(0, duration - 0.25));
    if ($resumePlaying) {
      const play = video.play();
      if (play) play.catch(() => {});
    } else {
      video.pause();
    }
    if (window.TechPiePlayer) {
      window.TechPiePlayer.postMessage(JSON.stringify({
        generation: $generation,
        type: 'restored',
        seconds: video.currentTime,
      }));
    }
    return true;
  };
  if (restore()) return;
  const timer = setInterval(() => {
    attempts += 1;
    if (restore() || attempts >= 40) clearInterval(timer);
  }, 100);
})();
''');
    } catch (_) {
      _trace('playback restore was not available');
    }
  }

  void _playerMessage(JavaScriptMessage message) {
    if (_closing || message.message.length > 1024) return;
    try {
      final decoded = jsonDecode(message.message);
      if (decoded is! Map<String, dynamic> || decoded['generation'] != _loadGeneration) return;
      if (decoded['type'] == 'restored' && decoded['seconds'] is num) {
        _trace('restored position=${(decoded['seconds'] as num).toStringAsFixed(1)}s');
      }
    } on FormatException {
      return;
    }
  }

  bool _isCurrent(int generation) => mounted && !_closing && generation == _loadGeneration;

  void _trace(String message) {
    if (kDebugMode) debugPrint('[ELRC player] $message');
  }

  Future<void> _stopPlayback() => _stopPlaybackFuture ??= _releaseMedia();

  Future<void> _releaseMedia() async {
    _closing = true;
    _loadGeneration++;
    _loadTimeout?.cancel();
    try {
      await _controller.runJavaScript('''
window.techPiePlayerClosed = true;
document.querySelectorAll('video, audio').forEach(media => {
  media.pause();
  media.removeAttribute('src');
  media.querySelectorAll('source').forEach(source => source.remove());
  media.load();
});
''').timeout(const Duration(seconds: 2));
    } catch (_) {
      // Native media documents may not expose a video element.
    }
    try {
      await _controller.loadRequest(Uri.parse('about:blank'));
    } catch (_) {
      _trace('media document cleanup failed');
    }
  }

  Future<void> _close() async {
    if (_closing) return;
    await _stopPlayback();
    if (mounted) Navigator.of(context).pop();
  }

  @override
  void dispose() {
    unawaited(_stopPlayback());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MediaPlayerScaffold(
        title: widget.courseName,
        subtitle: widget.lessonTitle,
        sourceLabels: [for (final source in widget.sources) source.label],
        selectedSource: _selected,
        sourceEnabled: !_loading,
        onSourceSelected: (index) => unawaited(_load(index)),
        player: WebViewWidget(controller: _controller),
        loading: _loading,
        error: _error,
        onRetry: _error == null ? null : () => unawaited(_load(_selected)),
        onBack: () => unawaited(_close()),
      );
}

class _ElrcDesktopPlayerPage extends StatefulWidget {
  const _ElrcDesktopPlayerPage({
    required this.courseName,
    required this.lessonTitle,
    required this.referer,
    required this.sources,
    this.cookie,
  });

  final String courseName;
  final String lessonTitle;
  final Uri referer;
  final List<ElrcSource> sources;
  final String? cookie;

  @override
  State<_ElrcDesktopPlayerPage> createState() => _ElrcDesktopPlayerState();
}

class _ElrcDesktopPlayerState extends State<_ElrcDesktopPlayerPage> with WidgetsBindingObserver {
  late final Player _player;
  late final VideoController _video;
  StreamSubscription<String>? _errors;
  int _selected = 0;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    MediaKit.ensureInitialized();
    _player = Player(configuration: const PlayerConfiguration(logLevel: MPVLogLevel.error));
    _video = VideoController(_player);
    _errors = _player.stream.error.listen((_) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = '视频播放失败';
        });
      }
    });
    unawaited(_load(0, preservePlayback: false));
  }

  Future<void> _load(int index, {bool preservePlayback = true}) async {
    if (!mounted || index < 0 || index >= widget.sources.length) return;
    final position = preservePlayback ? _player.state.position : Duration.zero;
    final playing = !preservePlayback || _player.state.playing;
    setState(() {
      _selected = index;
      _loading = true;
      _error = null;
    });
    try {
      await _player.open(
        Media(
          widget.sources[index].uri.toString(),
          httpHeaders: {
            'Referer': widget.referer.toString(),
            if (widget.cookie != null && widget.cookie!.isNotEmpty) 'Cookie': widget.cookie!,
          },
        ),
        play: playing,
      );
      if (position > Duration.zero) await _player.seek(position);
      if (mounted) setState(() => _loading = false);
    } catch (_) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = '视频加载失败';
        });
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused || state == AppLifecycleState.detached) {
      unawaited(_player.pause());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_errors?.cancel());
    unawaited(_player.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MediaPlayerScaffold(
        title: widget.courseName,
        subtitle: widget.lessonTitle,
        sourceLabels: [for (final source in widget.sources) source.label],
        selectedSource: _selected,
        sourceEnabled: !_loading,
        onSourceSelected: (index) => unawaited(_load(index)),
        player: Video(controller: _video, controls: MaterialDesktopVideoControls),
        loading: _loading,
        error: _error,
        onRetry: _error == null ? null : () => unawaited(_load(_selected)),
      );
}
