import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'elrc_webview_browser.dart';
import 'elrc_windows_browser.dart';
import 'session/cookie_provider.dart';
import 'third_party_auth_service.dart';

enum ElrcNavigationAction { allow, prevent, replace }

abstract interface class ElrcBrowser {
  Future<void> prepare();
  Future<void> writeCookies(CookieProvider provider);
  Future<void> navigate(Uri uri);
  Future<String?> mediaCookie();
  Future<void> registerMessages(void Function(String) onMessage);
  Future<void> runJavaScript(String script);
  Widget buildView();
  bool get isReady;
  void dispose();
}

ElrcBrowser createElrcBrowser({
  required ThirdPartyAuthService auth,
  required ElrcNavigationAction Function(Uri?, void Function(Uri)) onNavigation,
  required Future<void> Function() onReady,
  required void Function(String) onStarted,
  required void Function(String) onUrlChanged,
  required void Function(String) onFinished,
  required VoidCallback onFailed,
}) {
  if (defaultTargetPlatform == TargetPlatform.windows) {
    return ElrcWindowsBrowser(
      auth: auth,
      onNavigation: onNavigation,
      onReady: onReady,
      onStarted: onStarted,
      onUrlChanged: onUrlChanged,
      onFinished: onFinished,
      onFailed: onFailed,
    );
  }
  return ElrcWebViewBrowser(
    auth: auth,
    onNavigation: onNavigation,
    onReady: onReady,
    onStarted: onStarted,
    onUrlChanged: onUrlChanged,
    onFinished: onFinished,
    onFailed: onFailed,
  );
}
