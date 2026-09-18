import 'package:flutter/widgets.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/update_service.dart';
import 'adaptive_alert_dialog.dart';

/// The dialogs the update check can raise.
///
/// Shared, because the check runs twice — silently at launch and on resume, and
/// loudly when the version tile is tapped — and the two must not grow different
/// answers to the same question.

/// An update is available. Offered by both paths.
Future<void> showUpdateAvailableDialog(
  BuildContext context,
  ReleaseInfo release,
) async {
  final openReleasePage = await showAdaptiveAlertDialog<bool>(
    context: context,
    title: '发现新版本 ${release.name}',
    message: release.notes,
    actions: const [
      AdaptiveAlertAction<bool>(label: '以后再说'),
      AdaptiveAlertAction<bool>(
        label: '前往更新',
        value: true,
        isDefault: true,
      ),
    ],
  );
  if (openReleasePage == true) {
    await _openReleasePage();
  }
}

/// The manual check ran and found nothing newer. Only the manual path says this:
/// the silent one has nothing to report when it succeeds quietly.
Future<void> showUpToDateDialog(BuildContext context, String version) {
  return showAdaptiveAlertDialog<void>(
    context: context,
    title: '已是最新版本',
    message: '当前版本 $version 就是 GitHub 上最新的版本。',
    actions: const [AdaptiveAlertAction<void>(label: '好')],
  );
}

/// The manual check could not answer.
///
/// The message carries whatever went wrong, and the dialog always offers the way
/// out that does not depend on this app's network being good: GitHub in a
/// browser, which is where the release and its notes live anyway.
Future<void> showUpdateFailureDialog(
  BuildContext context, {
  required String message,
}) async {
  final goToGitHub = await showAdaptiveAlertDialog<bool>(
    context: context,
    title: '检查更新失败',
    message: '$message\n\n可以前往 GitHub 的 releases 页面查看最新版本，并手动下载。',
    actions: const [
      AdaptiveAlertAction<bool>(label: '取消'),
      AdaptiveAlertAction<bool>(
        label: '前往 GitHub',
        value: true,
        isDefault: true,
      ),
    ],
  );
  if (goToGitHub == true) {
    await _openReleasePage();
  }
}

Future<void> _openReleasePage() async {
  try {
    await launchUrl(
      Uri.parse(UpdateService.latestReleasePage),
      mode: LaunchMode.externalApplication,
    );
  } catch (_) {
    // No browser to hand it to — a headless desktop, a locked-down device. The
    // dialog has already said where to look.
  }
}
