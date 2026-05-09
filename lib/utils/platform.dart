import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// Check if the current platform is iOS and not web.
bool isIos() => !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;
