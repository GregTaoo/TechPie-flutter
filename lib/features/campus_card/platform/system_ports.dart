import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' as flutter;
import 'package:screen_brightness/screen_brightness.dart';

import '../data/storage/feedback_preferences.dart';
import '../domain/models/feedback_models.dart';
import '../domain/ports/platform_ports.dart';

final class SystemFeedbackPort implements FeedbackPort {
  SystemFeedbackPort({FeedbackPreferences? preferences, MethodChannel? channel})
      : _preferences = preferences ?? FeedbackPreferences(),
        _channel = channel ?? const MethodChannel('techpie/feedback');

  final FeedbackPreferences _preferences;
  final MethodChannel _channel;

  @override
  Future<FeedbackOptions> settingsFor(FeedbackScenario scenario) =>
      _preferences.read(scenario);

  @override
  Future<void> setEnabled(
    FeedbackScenario scenario,
    FeedbackChannel channel,
    bool enabled,
  ) =>
      _preferences.setEnabled(scenario, channel, enabled);

  @override
  Future<void> play(FeedbackEvent event) async {
    final options = await _preferences.read(event.scenario);
    if (!options.vibration && !options.sound) return;
    if (event.scenario != FeedbackScenario.interaction &&
        (defaultTargetPlatform == TargetPlatform.iOS ||
            defaultTargetPlatform == TargetPlatform.android)) {
      try {
        await _channel.invokeMethod<void>('play', {
          'event': event.name,
          'sound': options.sound,
          'vibration': options.vibration,
        });
        return;
      } on MissingPluginException {
        // Unsupported hosts retain the existing system vibration fallback.
      } on PlatformException {
        // A feedback failure must never turn a confirmed payment into an error.
      }
    }
    if (!options.vibration) return;
    try {
      switch (event) {
        case FeedbackEvent.selection:
          await HapticFeedback.selectionClick();
        case FeedbackEvent.lightImpact:
          await HapticFeedback.lightImpact();
        case FeedbackEvent.mediumImpact:
          await HapticFeedback.mediumImpact();
        case FeedbackEvent.warning:
        case FeedbackEvent.networkDisconnected:
          await HapticFeedback.mediumImpact();
          await Future<void>.delayed(const Duration(milliseconds: 90));
          await HapticFeedback.mediumImpact();
        case FeedbackEvent.success:
        case FeedbackEvent.paymentSuccess:
          await HapticFeedback.heavyImpact();
          await Future<void>.delayed(const Duration(milliseconds: 85));
          await HapticFeedback.mediumImpact();
        case FeedbackEvent.error:
          await HapticFeedback.heavyImpact();
          await Future<void>.delayed(const Duration(milliseconds: 70));
          await HapticFeedback.heavyImpact();
      }
    } on MissingPluginException {
      // Optional system feedback is unavailable on this host.
    } on PlatformException {
      // Keep UI actions successful even if the device feedback service fails.
    }
  }
}

final class SystemBrightnessPort implements BrightnessPort {
  SystemBrightnessPort({ScreenBrightness? screenBrightness})
      : _screenBrightness = screenBrightness ?? ScreenBrightness.instance;

  final ScreenBrightness _screenBrightness;
  double? _original;

  @override
  Future<double> current() async {
    final value = await _screenBrightness.application;
    _original ??= value;
    return value;
  }

  @override
  Future<void> set(double value) async {
    _original ??= await _screenBrightness.application;
    await _screenBrightness.setApplicationScreenBrightness(value.clamp(0, 1));
  }

  @override
  Future<void> restore() async {
    final original = _original;
    _original = null;
    try {
      await _screenBrightness.resetApplicationScreenBrightness();
    } catch (_) {
      if (original != null) {
        await _screenBrightness.setApplicationScreenBrightness(original);
      }
    }
  }
}

final class SystemConnectivityPort implements ConnectivityPort {
  SystemConnectivityPort({Connectivity? connectivity})
      : _connectivity = connectivity ?? Connectivity();

  final Connectivity _connectivity;

  bool get _pluginSupported =>
      kIsWeb ||
      defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS ||
      defaultTargetPlatform == TargetPlatform.macOS ||
      defaultTargetPlatform == TargetPlatform.linux ||
      defaultTargetPlatform == TargetPlatform.windows;

  @override
  Future<bool> isOnline() async {
    if (!_pluginSupported) return true;
    try {
      return _hasNetwork(await _connectivity.checkConnectivity());
    } on MissingPluginException {
      return true;
    } on PlatformException {
      return true;
    }
  }

  @override
  Stream<bool> get changes {
    if (!_pluginSupported) return Stream<bool>.value(true);
    return _connectivityChanges();
  }

  Stream<bool> _connectivityChanges() async* {
    try {
      await for (final results in _connectivity.onConnectivityChanged) {
        yield _hasNetwork(results);
      }
    } on MissingPluginException {
      yield true;
    } on PlatformException {
      yield true;
    }
  }

  bool _hasNetwork(List<ConnectivityResult> results) =>
      results.any((result) => result != ConnectivityResult.none);
}

final class FlutterAppLifecyclePort
    with flutter.WidgetsBindingObserver
    implements AppLifecyclePort {
  FlutterAppLifecyclePort() {
    flutter.WidgetsBinding.instance.addObserver(this);
    _current = _map(flutter.WidgetsBinding.instance.lifecycleState);
  }

  final StreamController<AppLifecycleState> _changes =
      StreamController<AppLifecycleState>.broadcast(sync: true);
  late AppLifecycleState _current;

  @override
  AppLifecycleState get current => _current;

  @override
  Stream<AppLifecycleState> get changes => _changes.stream;

  @override
  void didChangeAppLifecycleState(flutter.AppLifecycleState state) {
    final mapped = _map(state);
    if (mapped == _current) return;
    _current = mapped;
    _changes.add(mapped);
  }

  Future<void> dispose() async {
    flutter.WidgetsBinding.instance.removeObserver(this);
    await _changes.close();
  }

  AppLifecycleState _map(flutter.AppLifecycleState? state) => switch (state) {
        flutter.AppLifecycleState.resumed => AppLifecycleState.resumed,
        flutter.AppLifecycleState.inactive ||
        flutter.AppLifecycleState.hidden =>
          AppLifecycleState.inactive,
        flutter.AppLifecycleState.paused => AppLifecycleState.paused,
        flutter.AppLifecycleState.detached ||
        null =>
          AppLifecycleState.detached,
      };
}
