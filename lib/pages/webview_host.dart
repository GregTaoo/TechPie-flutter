import 'dart:async';
import 'dart:io' show Platform;

import 'package:desktop_webview_window/desktop_webview_window.dart'
    show CreateConfiguration, Webview, WebviewWindow;
import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart' show WebViewCookie;

import '../models/feature.dart';
import '../services/service_provider.dart';
import '../services/session/cookie_provider.dart';
import '../services/session/session_node.dart';
import '../services/third_party_auth_service.dart';
import '../services/webview_bridge.dart';
import 'generic_webview_page.dart';

/// Gives a webview page the host half of the campus page SDK: picking files
/// for the page, the native bar above it, and opening or closing webviews on
/// its behalf.
mixin BhWebViewHost<T extends StatefulWidget> on State<T>
    implements BhMobileSdkHost {
  BhMobileSdkBridge? _bridge;
  String? _pageTitle;
  bool _navBarVisible = true;

  /// True when the page is shown in its own desktop window, where the app
  /// draws no chrome around it.
  bool get isDesktopWebView => Platform.isLinux || Platform.isWindows;

  /// The desktop window this page drives, when [isDesktopWebView].
  Webview? get desktopWebview;

  /// The campus session this page reads its cookies from, when it has one.
  /// Pages opened for a feature set it; a debug or plain page leaves it null.
  CookieType? get hostCookieType => null;

  /// [hostCookieType] resolved against the running app's session tree.
  CampusSessionHandle? get hostSession {
    final cookieType = hostCookieType;
    if (cookieType == null) return null;
    return CampusSessionHandle(
      ServiceProvider.of(context).thirdPartyAuthService,
      cookieType,
    );
  }

  /// Cookies handed to the webviews this page opens for the campus page, read
  /// live from the session its feature authenticates against.
  List<WebViewCookie> get hostCookies =>
      hostSession?.cookies ?? const <WebViewCookie>[];

  /// Brings the feature's campus session up to date before a webview loads.
  ///
  /// A campus page writes its cookies into the browser store once and then
  /// drives its own requests, so a node that is due for renewal would show up
  /// there as a login screen — the API path cannot rescue it with a 401 retry.
  /// Best effort: a failed pre-flight still opens the page, which falls back to
  /// the campus SSO redirect.
  Future<void> prepareHostSession() async => hostSession?.prepare();

  /// Title the campus page asked for, when it asked for one.
  String? get hostPageTitle => _pageTitle;

  /// Whether the native bar above the page is currently shown.
  bool get hostNavBarVisible => _navBarVisible;

  /// Runs JavaScript in the page this host drives.
  Future<void> runPageJavaScript(String script);

  /// Starts answering the page's SDK messages. Only the in-app webview needs
  /// it: a desktop window builds its own bridge around its own web view.
  void installBhMobileSdkBridge() {
    _bridge = BhMobileSdkBridge(host: this, runJavaScript: runPageJavaScript);
  }

  Future<void> handleBhMobileSdkMessage(String message) async {
    await _bridge?.handleMessage(message);
  }

  /// Reports that the page is visible again, so its `webviewOnResume`
  /// handlers run.
  Future<void> notifyBhMobileSdkResume() async {
    await _bridge?.notifyResumed();
  }

  @override
  Future<List<BhMobileSdkFile>> pickFiles(
    BhMobileSdkPickerSource source,
    int limit,
  ) =>
      pickCampusFiles(source, limit);

  @override
  bool get hasDatePicker => true;

  @override
  Future<String?> pickDateTime(BhMobileSdkDateRequest request) async {
    final now = DateTime.now();
    final initial = _parseCampusDate(request.value) ?? now;
    switch (request.mode) {
      case BhMobileSdkDateMode.date:
        final picked = await _showDate(request, initial, now);
        return picked == null ? null : _formatCampusDate(picked);
      case BhMobileSdkDateMode.time:
        final picked = await showTimePicker(
          context: context,
          initialTime: TimeOfDay.fromDateTime(initial),
        );
        return picked == null ? null : _formatCampusTime(picked);
      case BhMobileSdkDateMode.dateTime:
        final date = await _showDate(request, initial, now);
        if (date == null || !mounted) return null;
        final time = await showTimePicker(
          context: context,
          initialTime: TimeOfDay.fromDateTime(initial),
        );
        if (time == null) return null;
        return '${_formatCampusDate(date)} ${_formatCampusTime(time)}';
    }
  }

  Future<DateTime?> _showDate(
    BhMobileSdkDateRequest request,
    DateTime initial,
    DateTime now,
  ) =>
      showDatePicker(
        context: context,
        initialDate: initial,
        firstDate: _parseCampusDate(request.min) ?? DateTime(now.year - 5),
        lastDate: _parseCampusDate(request.max) ?? DateTime(now.year + 5),
      );

  @override
  void setTitle(String title) {
    if (!mounted || isDesktopWebView || title == _pageTitle) return;
    setState(() => _pageTitle = title);
  }

  @override
  void setNavBarVisible(bool visible) {
    if (!mounted || isDesktopWebView || visible == _navBarVisible) return;
    setState(() => _navBarVisible = visible);
  }

  @override
  void openUrl(String url) {
    if (url.isEmpty) return;
    unawaited(_openHostUrl(url));
  }

  /// Opens [url] for the page, on the session the parent page was opened on.
  Future<void> _openHostUrl(String url) async {
    await prepareHostSession();
    if (!mounted) return;
    if (isDesktopWebView) {
      await openDesktopWebview(
        title: url,
        url: url,
        cookies: hostCookies,
        session: hostSession,
      );
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => GenericWebViewPage(
          title: url,
          url: url,
          cookieType: hostCookieType,
        ),
      ),
    );
  }

  @override
  void closeWebView() {
    if (isDesktopWebView) {
      desktopWebview?.close();
      return;
    }
    if (mounted) unawaited(Navigator.of(context).maybePop());
  }
}

/// Opens a campus page in its own desktop window (WebKitGTK on Linux, WebView2
/// on Windows) with the injected SDK and its own bridge, so a page the campus
/// page opened keeps working there.
Future<Webview?> openDesktopWebview({
  required String title,
  required String url,
  List<WebViewCookie> cookies = const <WebViewCookie>[],
  List<String> initialScripts = const <String>[],
  CampusSessionHandle? session,
}) async {
  final Webview webview;
  try {
    webview = await WebviewWindow.create(
      configuration: CreateConfiguration(
        title: title,
        windowWidth: 900,
        windowHeight: 700,
      ),
    );
  } catch (error) {
    debugPrint('Desktop webview launch failed: $error');
    return null;
  }

  final bridge = BhMobileSdkBridge(
    host: DesktopWebviewHost(webview, session),
    runJavaScript: (script) => webview.evaluateJavaScript(script),
  );
  webview.addOnWebMessageReceivedCallback((message) {
    unawaited(bridge.handleMessage(message));
  });
  webview.addScriptToExecuteOnDocumentCreated(techPieDocumentStartScript);
  for (final script in initialScripts) {
    webview.addScriptToExecuteOnDocumentCreated(script);
  }
  for (final cookie in cookies) {
    webview.setCookie(
      url: url,
      name: cookie.name,
      value: cookie.value,
      domain: cookie.domain,
      path: cookie.path,
      isHttpOnly: true,
    );
  }
  webview.launch(url);
  return webview;
}

/// Host for a campus page that lives in its own desktop window: it can still
/// pick files and open pages, but there is no app chrome to drive.
class DesktopWebviewHost implements BhMobileSdkHost {
  DesktopWebviewHost(this.webview, this.session);

  final Webview webview;

  /// The session the pages it opens are signed in with, when the window was
  /// opened for a campus feature.
  final CampusSessionHandle? session;

  @override
  Future<List<BhMobileSdkFile>> pickFiles(
    BhMobileSdkPickerSource source,
    int limit,
  ) =>
      pickCampusFiles(source, limit);

  // A popup window has no Flutter chrome to host a dialog, but WebKitGTK and
  // WebView2 open their own `<input type=date>` chooser, so the page draws the
  // picker its engine provides.
  @override
  bool get hasDatePicker => false;

  @override
  Future<String?> pickDateTime(BhMobileSdkDateRequest request) =>
      throw UnsupportedError('date picker');

  @override
  void openUrl(String url) {
    if (url.isEmpty) return;
    unawaited(_openChildWindow(url));
  }

  /// A link the campus page opened gets its own window, on the window's own
  /// session — and up to date, since it is a new page load.
  Future<void> _openChildWindow(String url) async {
    await openDesktopWebview(
      title: url,
      url: url,
      cookies: await session?.freshCookies() ?? const <WebViewCookie>[],
      session: session,
    );
  }

  @override
  void closeWebView() => webview.close();

  @override
  void setNavBarVisible(bool visible) {}

  @override
  void setTitle(String title) {}
}

/// The campus session a webview — or a desktop window opened from one —
/// authenticates against: the node its feature reads cookies from, plus the
/// pre-flight that brings that node up to date before a page loads.
class CampusSessionHandle {
  const CampusSessionHandle(this.tpAuth, this.cookieType);

  final ThirdPartyAuthService tpAuth;
  final CookieType cookieType;

  /// Each feature reads a different derived session: ecourse runs on the
  /// CpDaily/CASTGC session directly, eams and the egate apps on their own
  /// downstream cookies.
  SessionNode? get node => switch (cookieType) {
        CookieType.ecourse => tpAuth.cpdailyNode,
        CookieType.eams => tpAuth.eamsNode,
        CookieType.egateApp => tpAuth.egateAppNode,
      };

  /// The cookies to inject, as of the last [prepare].
  List<WebViewCookie> get cookies => _webViewCookies(node?.cookieProvider);

  /// Renews the node when its schedule says it is due. A webview writes its
  /// cookies into the browser store once and then drives its own requests, so a
  /// node that had gone stale would show up there as a login screen — the API
  /// path cannot rescue it with a 401 retry. Best effort: a failed pre-flight
  /// still opens the page, which falls back to the campus SSO redirect.
  Future<void> prepare() async {
    final session = node;
    if (session == null) return;
    try {
      await tpAuth.sessionTree.freshCookie(session);
    } catch (error) {
      debugPrint('Campus session pre-flight failed: $error');
    }
  }

  /// [prepare], then the cookies to inject — for a caller that opens a webview
  /// of its own and cannot come back for them.
  Future<List<WebViewCookie>> freshCookies() async {
    await prepare();
    return cookies;
  }
}

/// Rebuilds a session's cookie string into webview cookie objects, one per
/// `name=value` pair, scoped to the provider's campus host.
List<WebViewCookie> _webViewCookies(CookieProvider? provider) {
  if (provider == null || provider.isEmpty) return const <WebViewCookie>[];
  final domain =
      provider.domain.isNotEmpty ? provider.domain : 'ids.shanghaitech.edu.cn';
  final cookies = <WebViewCookie>[];
  for (final part in provider.cookies.split(';')) {
    final separator = part.indexOf('=');
    if (separator <= 0) continue;
    final name = part.substring(0, separator).trim();
    final value = part.substring(separator + 1).trim();
    if (name.isEmpty || value.isEmpty) continue;
    cookies.add(
      WebViewCookie(name: name, value: value, domain: domain, path: '/'),
    );
  }
  return cookies;
}

/// Reads the values the campus date fields use: `yyyy-MM-dd`, `HH:mm` and
/// `yyyy-MM-dd HH:mm`.
DateTime? _parseCampusDate(String? value) {
  if (value == null) return null;
  final match = RegExp(r'(\d{4})-(\d{1,2})-(\d{1,2})(?:[ T](\d{1,2}):(\d{2}))?')
      .firstMatch(value);
  if (match == null) return null;
  return DateTime(
    int.parse(match[1]!),
    int.parse(match[2]!),
    int.parse(match[3]!),
    int.tryParse(match[4] ?? '') ?? 0,
    int.tryParse(match[5] ?? '') ?? 0,
  );
}

String _formatCampusDate(DateTime value) =>
    '${value.year}-${_two(value.month)}-${_two(value.day)}';

String _formatCampusTime(TimeOfDay value) =>
    '${_two(value.hour)}:${_two(value.minute)}';

String _two(int value) => value.toString().padLeft(2, '0');
