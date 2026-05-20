import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

class GenericWebViewPage extends StatefulWidget {
  const GenericWebViewPage({
    super.key,
    required this.title,
    required this.url,
    this.cookies,
  });

  final String title;
  final String url;
  final List<Cookie>? cookies;

  @override
  State<GenericWebViewPage> createState() => _GenericWebViewPageState();
}

class _GenericWebViewPageState extends State<GenericWebViewPage> {
  InAppWebViewController? controller;

  Future<void> _loadWithCookies() async {
    final uri = WebUri(widget.url);
    final cookieManager = CookieManager.instance();

    await cookieManager.deleteAllCookies();

    for (final cookie in widget.cookies ?? const <Cookie>[]) {
      await cookieManager.setCookie(
        url: uri,
        name: cookie.name,
        value: '${cookie.value ?? ''}',
        path: '/',
        isSecure: true,
      );
    }

    await controller?.loadUrl(urlRequest: URLRequest(url: uri));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.title), centerTitle: true),
      body: InAppWebView(
        initialSettings: InAppWebViewSettings(
          javaScriptEnabled: true,
          useShouldOverrideUrlLoading: true,
        ),
        onWebViewCreated: (webViewController) {
          controller = webViewController;
          _loadWithCookies();
        },
        shouldOverrideUrlLoading: (controller, navigationAction) async {
          return NavigationActionPolicy.ALLOW;
        },
      ),
    );
  }
}
