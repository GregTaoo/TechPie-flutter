import 'package:flutter/foundation.dart';

/// Check if the current platform is iOS and not web.
bool isIos() => !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

/// Check if the current platform is Android and not web.
bool isAndroid() => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
