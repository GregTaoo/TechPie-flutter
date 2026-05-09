import 'package:flutter/material.dart';

final GlobalKey<ScaffoldMessengerState> rootMessengerKey =
    GlobalKey<ScaffoldMessengerState>();

enum AdaptiveFeedbackStyle { info, success, error }

void showAdaptiveFeedback({
  BuildContext? context,
  required String message,
  AdaptiveFeedbackStyle style = AdaptiveFeedbackStyle.info,
  Duration duration = const Duration(seconds: 3),
  String? actionLabel,
  VoidCallback? onAction,
}) {
  final messenger = context != null
      ? ScaffoldMessenger.maybeOf(context)
      : rootMessengerKey.currentState;
  if (messenger == null) return;

  messenger
    ..clearSnackBars()
    ..showSnackBar(
      SnackBar(
        content: Text(message),
        duration: duration,
        action: actionLabel != null && onAction != null
            ? SnackBarAction(label: actionLabel, onPressed: onAction)
            : null,
      ),
    );
}
