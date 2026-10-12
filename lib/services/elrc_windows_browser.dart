import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart' as inapp;

import '../pages/campus_session_handle.dart';
import 'elrc_browser.dart';
import 'session/cookie_provider.dart';
import 'third_party_auth_service.dart';

class ElrcWindowsBrowser implements ElrcBrowser {
  ElrcWindowsBrowser({
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

  inapp.InAppWebViewController? _controller;
  bool _disposed = false;
  Timer? _startupTimeout;

  // The plugin creates separate facade objects for creation and event callbacks.
  bool _ownsController(inapp.InAppWebViewController controller) =>
      identical(_controller?.platform, controller.platform);

  @override
  bool get isReady => _controller != null;

  @override
  Future<void> prepare() async {
    final cookies = inapp.CookieManager.instance();
    await cookies.deleteCookies(url: inapp.WebUri('https://elrc.shanghaitech.edu.cn/'));
    await cookies.deleteCookies(url: inapp.WebUri('https://ids.shanghaitech.edu.cn/'));
    final session = CampusSessionHandle(auth, auth.elrcNode);
    await session.prepare();
    final provider = auth.elrcNode.cookieProvider;
    if (provider == null) throw StateError('ELRC session renewal failed');
    await writeCookies(provider);
  }

  @override
  Future<void> writeCookies(CookieProvider provider) async {
    for (final cookie in webViewCookies(provider)) {
      await inapp.CookieManager.instance().setCookie(
        url: inapp.WebUri('https://${cookie.domain}/'),
        name: cookie.name,
        value: cookie.value,
        domain: cookie.domain,
        path: cookie.path,
      );
    }
  }

  @override
  Future<void> navigate(Uri uri) async {
    final controller = _controller;
    if (_disposed || controller == null) throw StateError('ELRC browser is not ready');
    await controller.loadUrl(
      urlRequest: inapp.URLRequest(url: inapp.WebUri(uri.toString())),
    );
  }

  @override
  Future<String?> mediaCookie() async {
    final cookies = await inapp.CookieManager.instance().getCookies(
      url: inapp.WebUri('https://elrc.shanghaitech.edu.cn/'),
    );
    return cookies.map((cookie) => '${cookie.name}=${cookie.value}').join('; ');
  }

  @override
  Future<void> registerMessages(void Function(String) onMessage) async {
    _controller!.addJavaScriptHandler(
      handlerName: 'TechPieElrc',
      callback: (arguments) {
        if (arguments.length == 1 && arguments.first is String) {
          onMessage(arguments.first as String);
        }
        return null;
      },
    );
  }

  @override
  Future<void> runJavaScript(String script) async {
    await _controller!.evaluateJavascript(
      source: '''
window.TechPieElrc = {
  postMessage: (message) => window.flutter_inappwebview.callHandler('TechPieElrc', message)
};
$script
''',
    );
  }

  @override
  Widget buildView() => inapp.InAppWebView(
        key: ValueKey(this),
        onWebViewCreated: (controller) {
          if (_disposed) return;
          _controller = controller;
          _startupTimeout = Timer(const Duration(seconds: 30), () {
            if (!_disposed) {
              if (kDebugMode) debugPrint('[ELRC] Windows browser startup timed out');
              onFailed();
            }
          });
          unawaited(_initialize(controller));
        },
        onLoadStart: (controller, url) {
          if (!_disposed &&
              _ownsController(controller) &&
              url != null &&
              url.toString() != 'about:blank') {
            if (kDebugMode) debugPrint('[ELRC] Windows page started: ${url.host}${url.path}');
            onStarted(url.toString());
          }
        },
        onUpdateVisitedHistory: (controller, url, isReload) {
          if (!_disposed &&
              _ownsController(controller) &&
              url != null &&
              url.toString() != 'about:blank') {
            onUrlChanged(url.toString());
          }
        },
        onLoadStop: (controller, url) {
          if (!_disposed &&
              _ownsController(controller) &&
              url != null &&
              url.toString() != 'about:blank') {
            _startupTimeout?.cancel();
            if (kDebugMode) debugPrint('[ELRC] Windows page finished: ${url.host}${url.path}');
            onFinished(url.toString());
          }
        },
        onReceivedError: (controller, request, error) {
          if (_disposed || !_ownsController(controller) || request.isForMainFrame != true) {
            return;
          }
          // WebView2 cancels its initial blank document when ELRC navigation starts.
          // It is not a failure of the requested campus page.
          if (request.url.toString() == 'about:blank') return;
          if (kDebugMode) {
            final uri = Uri.tryParse(request.url.toString());
            debugPrint(
              '[ELRC] page load failed: type=${error.type} host=${uri?.host} path=${uri?.path}',
            );
          }
          onFailed();
        },
        shouldOverrideUrlLoading: (controller, navigation) async {
          if (_disposed || !_ownsController(controller)) {
            return inapp.NavigationActionPolicy.CANCEL;
          }
          final uri = Uri.tryParse(navigation.request.url.toString());
          final decision = onNavigation(uri, (target) {
            unawaited(navigate(target).catchError((Object _) => onFailed()));
          });
          return decision == ElrcNavigationAction.allow
              ? inapp.NavigationActionPolicy.ALLOW
              : inapp.NavigationActionPolicy.CANCEL;
        },
        initialSettings: inapp.InAppWebViewSettings(
          javaScriptEnabled: true,
          useShouldOverrideUrlLoading: true,
        ),
      );

  Future<void> _initialize(inapp.InAppWebViewController controller) async {
    try {
      if (kDebugMode) debugPrint('[ELRC] Windows controller ready; opening ELRC');
      await onReady().timeout(const Duration(seconds: 30));
    } catch (_) {
      if (!_disposed && _ownsController(controller)) {
        _startupTimeout?.cancel();
        _controller = null;
        onFailed();
      }
    }
  }

  @override
  void dispose() {
    _startupTimeout?.cancel();
    _disposed = true;
    _controller = null;
  }
}
