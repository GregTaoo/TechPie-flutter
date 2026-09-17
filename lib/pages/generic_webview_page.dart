import 'dart:async';

import 'package:desktop_webview_window/desktop_webview_window.dart' show Webview;
import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart'
    show
        JavaScriptMessage,
        WebViewController,
        WebViewUserScript,
        JavaScriptMode,
        NavigationDelegate,
        NavigationDecision,
        WebViewWidget,
        WebViewCookie,
        WebViewCookieManager;

import '../services/webview_bridge.dart';
import 'webview_host.dart';

/// A page that hosts a webview.
///
/// On Linux and Windows it opens a separate popup window via
/// [WebviewWindow] (WebKitGTK on Linux, WebView2 on Windows). On all
/// other platforms it uses [WebViewWidget] (webview_flutter) for an
/// in-app webview.
class GenericWebViewPage extends StatefulWidget {
  const GenericWebViewPage({
    super.key,
    required this.title,
    required this.url,
    this.cookies,
    this.initialUserScripts = const <WebViewUserScript>[],
  });

  final String title;
  final String url;
  final List<WebViewCookie>? cookies;

  final List<WebViewUserScript> initialUserScripts;

  @override
  State<GenericWebViewPage> createState() => _GenericWebViewPageState();
}

class _GenericWebViewPageState extends State<GenericWebViewPage>
    with BhWebViewHost<GenericWebViewPage>, WidgetsBindingObserver {
  late final WebViewController _controller;
  Webview? _desktopWebview;
  String? _desktopError;

  @override
  Webview? get desktopWebview => _desktopWebview;

  @override
  List<WebViewCookie> get hostCookies =>
      widget.cookies ?? const <WebViewCookie>[];

  @override
  Future<void> runPageJavaScript(String script) async {
    if (isDesktopWebView) {
      await _desktopWebview?.evaluateJavaScript(script);
      return;
    }
    await _controller.runJavaScript(script);
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (isDesktopWebView) {
      unawaited(_openDesktop());
    } else {
      _controller = WebViewController();
      unawaited(_initController());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(notifyBhMobileSdkResume());
    }
  }

  // -- Desktop path (desktop_webview_window popup) --

  Future<void> _openDesktop() async {
    final webview = await openDesktopWebview(
      title: widget.title,
      url: widget.url,
      cookies: hostCookies,
      initialScripts: <String>[
        for (final script in widget.initialUserScripts) script.source,
      ],
    );
    if (webview == null) {
      if (mounted) {
        setState(() => _desktopError = 'The WebView window could not be opened');
      }
      return;
    }
    _desktopWebview = webview;
    if (mounted) Navigator.of(context).pop();
  }

  // -- Mobile / webview_flutter in-app widget --

  Future<void> _initController() async {
    await _controller.setJavaScriptMode(JavaScriptMode.unrestricted);
    await _controller.setNavigationDelegate(
      NavigationDelegate(
        onNavigationRequest: (request) => NavigationDecision.navigate,
      ),
    );

    installBhMobileSdkBridge();
    await _controller.addJavaScriptChannel(
      'TechPieBridge',
      onMessageReceived: (JavaScriptMessage message) {
        unawaited(handleBhMobileSdkMessage(message.message));
      },
    );

    await _controller.addUserScripts(<WebViewUserScript>[
      ...widget.initialUserScripts,
      const WebViewUserScript(source: techPieDocumentStartScript),
    ]);

    final cookieManager = WebViewCookieManager();
    await cookieManager.clearCookies();
    for (final c in hostCookies) {
      await cookieManager.setCookie(c);
    }

    await _controller.loadRequest(Uri.parse(widget.url));
  }

  @override
  Widget build(BuildContext context) {
    final appBar = hostNavBarVisible
        ? AppBar(title: Text(hostPageTitle ?? widget.title), centerTitle: true)
        : null;
    if (isDesktopWebView) {
      return Scaffold(
        appBar: appBar,
        body: Center(
          child: _desktopError == null
              ? const CircularProgressIndicator()
              : Text(_desktopError!),
        ),
      );
    }

    return Scaffold(
      appBar: appBar,
      body: WebViewWidget(controller: _controller),
    );
  }
}
