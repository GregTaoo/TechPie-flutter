import 'dart:ui' show Offset;

import '../models/feedback_models.dart';

enum AppLifecycleState { resumed, inactive, paused, detached }

/// One decode: the text, and where it was in the frame it was read from, in
/// normalised 0..1 coordinates so a viewfinder can land on it whatever size the
/// preview is drawn at.
final class ScannerReading {
  const ScannerReading(this.value, {this.corners});

  final String value;
  final List<Offset>? corners;
}

abstract interface class ScannerPort {
  Stream<ScannerReading> get scannedCodes;
  Future<void> start();
  Future<void> stop();
  Future<void> setTorch(bool enabled);
  Future<String?> scanImage();
}

abstract interface class BrightnessPort {
  Future<double> current();
  Future<void> set(double value);
  Future<void> restore();
}

abstract interface class AppLifecyclePort {
  AppLifecycleState get current;
  Stream<AppLifecycleState> get changes;
}

abstract interface class ConnectivityPort {
  Future<bool> isOnline();
  Stream<bool> get changes;
}

enum HomeWidgetAvailability { nativePin, manual, unsupported }

abstract interface class HomeWidgetPort {
  Future<HomeWidgetAvailability> availability();
  Future<bool> requestPin();
}

enum FeedbackEvent {
  selection,
  lightImpact,
  mediumImpact,
  success,
  warning,
  error,
  paymentSuccess,
  networkDisconnected;

  FeedbackScenario get scenario => switch (this) {
        FeedbackEvent.paymentSuccess => FeedbackScenario.paymentSuccess,
        FeedbackEvent.networkDisconnected =>
          FeedbackScenario.networkDisconnected,
        _ => FeedbackScenario.interaction,
      };
}

abstract interface class FeedbackPort {
  Future<void> play(FeedbackEvent event);
  Future<FeedbackOptions> settingsFor(FeedbackScenario scenario);
  Future<void> setEnabled(
    FeedbackScenario scenario,
    FeedbackChannel channel,
    bool enabled,
  );
}
