import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/config/debug_mode_controller.dart';
import '../../core/config/debug_mode_features.dart';
import '../../core/config/scan_payment_preferences.dart';
import '../icons/platform_icons.dart';
import '../localization/geekpay_localizations.dart';
import '../widgets/apple_wallet_components.dart';

final class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final debugMode = ref.watch(debugModeProvider);
    final skipScanConfirmation = ref.watch(skipScanConfirmationProvider);
    final l10n = context.l10n;
    return Scaffold(
      body: AppleWalletPage(
        child: ApplePinnedHeaderLayout(
          leading: CampusCardHeaderAction(
            id: 'back',
            sfSymbol: 'chevron.left',
            icon: GpPlatformIcons.back(context),
            label: l10n.t('back'),
            onPressed: () => context.pop(),
          ),
          title: l10n.t('settings'),
          child: ListView(
            physics: const BouncingScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(
              20,
              ApplePinnedHeaderLayout.contentTop,
              20,
              52,
            ),
            children: [
              AppleSection(
                children: [
                  AppleListRow(
                    icon: GpPlatformIcons.scan(context),
                    label: l10n.t('skipScanConfirmation'),
                    verticalPadding: 4,
                    trailing: _SettingsSwitch(
                      value: skipScanConfirmation,
                      onChanged: (value) => unawaited(
                        ref
                            .read(skipScanConfirmationProvider.notifier)
                            .setEnabled(value),
                      ),
                    ),
                  ),
                  if (debugModeFeaturesAvailable)
                    AppleListRow(
                      icon: GpPlatformIcons.debug(context),
                      label: l10n.t('debugMode'),
                      verticalPadding: 4,
                      trailing: _SettingsSwitch(
                        value: debugMode,
                        onChanged: (value) => unawaited(
                          ref
                              .read(debugModeProvider.notifier)
                              .setEnabled(value),
                        ),
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

final class _SettingsSwitch extends StatelessWidget {
  const _SettingsSwitch({required this.value, required this.onChanged});

  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) =>
      Switch.adaptive(value: value, onChanged: onChanged);
}
