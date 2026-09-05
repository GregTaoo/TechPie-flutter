enum AppLifecycleState { resumed, inactive, paused, detached }

abstract interface class ScannerPort {
  Stream<String> get scannedCodes;
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

enum HapticEvent {
  selection,
  lightImpact,
  mediumImpact,
  success,
  warning,
  error,
}

abstract interface class HapticsPort {
  Future<void> play(HapticEvent event);
}
