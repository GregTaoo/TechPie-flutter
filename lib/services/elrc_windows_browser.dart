import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart' as inapp;

import '../pages/campus_session_handle.dart';
import 'elrc_browser.dart';
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

  @override
  bool get isReady => _controller != null;

  @override
  Future<void> prepare() async {
    final cookies = inapp.CookieManager.instance();
    await cookies.deleteCookies(url: inapp.WebUri('https://elrc.shanghaitech.edu.cn/'));
    await cookies.deleteCookies(url: inapp.WebUri('https://ids.shanghaitech.edu.cn/'));
    await refreshCampusCookies();
  }

  @override
  Future<void> refreshCampusCookies() async {
    try {
      final session = CampusSessionHandle(auth, auth.cpdailyNode);
      await session.prepare();
      for (final cookie in session.cookies) {
        await inapp.CookieManager.instance().setCookie(
          url: inapp.WebUri('https://${cookie.domain}/'),
          name: cookie.name,
          value: cookie.value,
          domain: cookie.domain,
          path: cookie.path,
        );
      }
    } catch (_) {
      // The official SSO page remains available if campus session renewal fails.
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
        onWebViewCreated: (controller) async {
          if (_disposed) return;
          _controller = controller;
          try {
            await onReady();
          } catch (_) {
            if (!_disposed && identical(_controller, controller)) {
              _controller = null;
              onFailed();
            }
          }
        },
        onLoadStart: (controller, url) {
          if (!_disposed && identical(_controller, controller) && url != null) {
            onStarted(url.toString());
          }
        },
        onUpdateVisitedHistory: (controller, url, isReload) {
          if (!_disposed && identical(_controller, controller) && url != null) {
            onUrlChanged(url.toString());
          }
        },
        onLoadStop: (controller, url) {
          if (!_disposed && identical(_controller, controller) && url != null) {
            onFinished(url.toString());
          }
        },
        onReceivedError: (controller, request, error) {
          if (!_disposed && identical(_controller, controller) && request.isForMainFrame == true) {
            onFailed();
          }
        },
        shouldOverrideUrlLoading: (controller, navigation) async {
          if (_disposed || !identical(_controller, controller)) {
            return inapp.NavigationActionPolicy.CANCEL;
          }
          final uri = Uri.tryParse(navigation.request.url?.toString() ?? '');
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

  @override
  void dispose() {
    _disposed = true;
    _controller = null;
  }
}
