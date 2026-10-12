import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../pages/campus_session_handle.dart';
import 'elrc_browser.dart';
import 'session/cookie_provider.dart';
import 'third_party_auth_service.dart';

class ElrcWebViewBrowser implements ElrcBrowser {
  ElrcWebViewBrowser({
    required this.auth,
    required this.onNavigation,
    required this.onReady,
    required this.onStarted,
    required this.onUrlChanged,
    required this.onFinished,
    required this.onFailed,
  });

  final ThirdPartyAuthService auth;
  final ElrcNavigationAction Function(Uri?, void Function(Uri)) onNavigation;
  final Future<void> Function() onReady;
  final void Function(String) onStarted;
  final void Function(String) onUrlChanged;
  final void Function(String) onFinished;
  final VoidCallback onFailed;

  WebViewController? _controller;
  bool _disposed = false;
  int _expectedCancellations = 0;

  @override
  bool get isReady => _controller != null;

  @override
  Future<void> prepare() async {
    final controller = WebViewController();
    _controller = controller;
    try {
      final session = CampusSessionHandle(auth, auth.elrcNode);
      await session.prepare();
      final provider = auth.elrcNode.cookieProvider;
      if (provider == null) throw StateError('ELRC session renewal failed');
      await auth.campusWebSession.clearLocalStorageIfDue(controller);
      await writeCookies(provider);
      if (_disposed) return;
      await controller.setJavaScriptMode(JavaScriptMode.unrestricted);
      await controller.setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: (request) {
            if (_disposed || !identical(_controller, controller)) {
              return NavigationDecision.prevent;
            }
            final action = onNavigation(Uri.tryParse(request.url), (uri) {
              unawaited(navigate(uri).catchError((Object _) => onFailed()));
            });
            if (action == ElrcNavigationAction.replace) {
              _expectedCancellations++;
            }
            return action == ElrcNavigationAction.allow
                ? NavigationDecision.navigate
                : NavigationDecision.prevent;
          },
          onPageStarted: (url) {
            if (!_disposed && identical(_controller, controller)) onStarted(url);
          },
          onUrlChange: (change) {
            if (!_disposed && identical(_controller, controller) && change.url != null) {
              onUrlChanged(change.url!);
            }
          },
          onPageFinished: (url) {
            if (!_disposed && identical(_controller, controller)) onFinished(url);
          },
          onWebResourceError: (error) {
            if (_disposed || !identical(_controller, controller) || error.isForMainFrame != true) {
              return;
            }
            if (error.errorCode == 102 && _expectedCancellations > 0) {
              _expectedCancellations--;
              return;
            }
            onFailed();
          },
        ),
      );
      if (!_disposed) await onReady();
    } catch (_) {
      dispose();
      rethrow;
    }
  }

  @override
  Future<void> writeCookies(CookieProvider provider) async {
    for (final cookie in webViewCookies(provider)) {
      await WebViewCookieManager().setCookie(cookie);
    }
  }

  @override
  Future<void> navigate(Uri uri) async {
    final controller = _controller;
    if (_disposed || controller == null) throw StateError('ELRC browser is not ready');
    await controller.loadRequest(uri);
  }

  @override
  Future<String?> mediaCookie() async {
    final controller = _controller;
    if (_disposed || controller == null) throw StateError('ELRC browser is not ready');
    final raw = await controller.runJavaScriptReturningResult('JSON.stringify(document.cookie)');
    final decoded = jsonDecode(raw.toString());
    return decoded is String ? decoded : null;
  }

  @override
  Future<void> registerMessages(void Function(String) onMessage) =>
      _controller!.addJavaScriptChannel(
        'TechPieElrc',
        onMessageReceived: (message) => onMessage(message.message),
      );

  @override
  Future<void> runJavaScript(String script) => _controller!.runJavaScript(script);

  @override
  Widget buildView() => WebViewWidget(controller: _controller!);

  @override
  void dispose() {
    _disposed = true;
    _controller = null;
  }
}
