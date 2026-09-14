import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/app_providers.dart';
import '../localization/geekpay_localizations.dart';
import '../widgets/gp_state.dart';

/// Used only when binding restoration is unresolved, never to request an OpenID.
final class SessionRestoreScreen extends ConsumerWidget {
  const SessionRestoreScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authControllerProvider);
    final exit = ref.watch(geekPayHostExitProvider);
    return Scaffold(
      key: const Key('ecard-session-restore-page'),
      appBar: AppBar(
        title: Text(context.l10n.t('sessionRestoreTitle')),
        leading: exit == null ? null : BackButton(onPressed: exit),
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: auth.isLoading
              ? const CupertinoActivityIndicator()
              : GpStateView(
                  title: context.l10n.t('sessionRestoreTitle'),
                  description: auth.hasError ? GpStateView.safeUiError(auth.error!)
                      : context.l10n.t('sessionRestoreMessage'),
                  actionLabel: context.l10n.t('retry'),
                  onAction: () => ref.invalidate(authControllerProvider),
                ),
        ),
      ),
    );
  }
}
