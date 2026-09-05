import 'dart:async';

import 'package:flutter/services.dart';

typedef OpenEcardPayHandler = Future<void> Function();

/// Receives the iOS Home Screen eCard shortcut and opens the pay code route.
final class EcardDeepLinkService {
  EcardDeepLinkService({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel('techpie/ecard_deep_link');

  final MethodChannel _channel;
  OpenEcardPayHandler? _handler;
  bool _initialized = false;
  bool _pending = false;
  bool _dispatching = false;

  void initialize() {
    if (_initialized) return;
    _initialized = true;
    _channel.setMethodCallHandler(_handleMethodCall);
    unawaited(_consumePending());
  }

  void setOpenPayHandler(OpenEcardPayHandler handler) {
    _handler = handler;
    if (_pending) unawaited(_dispatch());
  }

  void clearOpenPayHandler() {
    _handler = null;
  }

  Future<void> dispose() async {
    _handler = null;
    _channel.setMethodCallHandler(null);
  }

  Future<Object?> _handleMethodCall(MethodCall call) async {
    if (call.method == 'openPayCode') {
      await _dispatch();
    }
    return null;
  }

  Future<void> _consumePending() async {
    try {
      final route = await _channel.invokeMethod<String>('consumePendingRoute');
      if (route == 'pay') await _dispatch();
    } on MissingPluginException {
      // Non-iOS platforms do not install this channel.
    } on PlatformException {
      // A native shortcut failure must never delay normal app startup.
    }
  }

  Future<void> _dispatch() async {
    if (_dispatching) return;
    final handler = _handler;
    if (handler == null) {
      _pending = true;
      return;
    }
    _pending = false;
    _dispatching = true;
    try {
      await handler();
      try {
        await _channel.invokeMethod<void>('acknowledgePendingRoute');
      } on MissingPluginException {
        // Tests and non-iOS hosts can dispatch without a native peer.
      } on PlatformException {
        // The route is already open. A failed acknowledgement is harmless.
      }
    } finally {
      _dispatching = false;
      if (_pending) unawaited(_dispatch());
    }
  }
}
