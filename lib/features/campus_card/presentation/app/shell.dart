import 'package:flutter/material.dart';

import '../localization/geekpay_localizations.dart';
import '../scanner/scanner_modal.dart';
import '../theme/glass.dart';
import '../theme/tokens.dart';

/// Opens the scanner with one identical bottom-up transition on every OS.
Future<void> openGpScanner(BuildContext context) async {
  final reduceMotion = gpReduceMotionActive(context);
  await showGeneralDialog<void>(
    context: context,
    useRootNavigator: false,
    barrierLabel: context.l10n.t('close'),
    barrierDismissible: false,
    barrierColor: Colors.black54,
    transitionDuration: GpTokens.scanModalDuration,
    pageBuilder: (dialogContext, animation, secondaryAnimation) =>
        ScannerModal(onClose: () => Navigator.of(dialogContext).pop()),
    transitionBuilder: (dialogContext, animation, secondaryAnimation, child) {
      return gpScannerEntranceTransition(
        animation,
        child,
        reduceMotion: reduceMotion,
      );
    },
  );
}
