import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/config/debug_mode_controller.dart';
import '../../core/config/debug_mode_features.dart';
import '../../core/config/feedback_settings.dart';
import '../../core/config/payment_code_preferences.dart';
import '../../core/config/scan_payment_preferences.dart';
import '../../domain/models/feedback_models.dart';
import '../icons/platform_icons.dart';
import '../localization/geekpay_localizations.dart';
import '../widgets/apple_wallet_components.dart';

final class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final debugMode = ref.watch(debugModeProvider);
    final skipScanConfirmation = ref.watch(skipScanConfirmationProvider);
    final maximizeBrightness =
        ref.watch(maximizePaymentCodeBrightnessProvider).valueOrNull;
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
                footer: l10n.t('maximizePaymentCodeBrightnessHint'),
                children: [
                  AppleListRow(
                    icon: GpPlatformIcons.brightness(context),
                    label: l10n.t('maximizePaymentCodeBrightness'),
                    verticalPadding: 4,
                    trailing: _SettingsSwitch(
                      key: const Key('maximize-payment-code-brightness'),
                      value: maximizeBrightness ?? false,
                      onChanged: maximizeBrightness == null
                          ? null
                          : (enabled) => unawaited(
                                ref
                                    .read(
                                      maximizePaymentCodeBrightnessProvider
                                          .notifier,
                                    )
                                    .setEnabled(enabled),
                              ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 24),
              AppleSection(
                footer:
                    debugModeFeaturesAvailable ? l10n.t('debugModeHint') : null,
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
              if (Theme.of(context).platform == TargetPlatform.iOS ||
                  Theme.of(context).platform == TargetPlatform.android)
                for (final scenario in FeedbackScenario.values) ...[
                  const SizedBox(height: 24),
                  _FeedbackSection(scenario: scenario),
                ],
            ],
          ),
        ),
      ),
    );
  }
}

final class _FeedbackSection extends ConsumerWidget {
  const _FeedbackSection({required this.scenario});

  final FeedbackScenario scenario;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final options = ref.watch(feedbackSettingsProvider(scenario)).valueOrNull;
    final header = switch (scenario) {
      FeedbackScenario.paymentSuccess => 'feedbackPaymentSuccess',
      FeedbackScenario.networkDisconnected => 'feedbackNetworkDisconnected',
      FeedbackScenario.interaction => 'feedbackInteraction',
    };
    return AppleSection(
      header: l10n.t(header),
      footer: scenario == FeedbackScenario.interaction
          ? l10n.t('interactionFeedbackHint')
          : null,
      children: [
        for (final channel in FeedbackChannel.values)
          if (channel == FeedbackChannel.vibration ||
              scenario != FeedbackScenario.interaction)
            AppleListRow(
              icon: channel == FeedbackChannel.vibration
                  ? GpPlatformIcons.vibration(context)
                  : GpPlatformIcons.sound(context),
              label: l10n.t(
                channel == FeedbackChannel.vibration ? 'vibration' : 'sound',
              ),
              verticalPadding: 4,
              trailing: _SettingsSwitch(
                key: ValueKey('feedback-${scenario.name}-${channel.name}'),
                value: options == null
                    ? true
                    : channel == FeedbackChannel.vibration
                        ? options.vibration
                        : options.sound,
                onChanged: options == null
                    ? null
                    : (enabled) => unawaited(
                          ref
                              .read(feedbackSettingsProvider(scenario).notifier)
                              .setEnabled(channel, enabled),
                        ),
              ),
            ),
      ],
    );
  }
}

final class _SettingsSwitch extends StatelessWidget {
  const _SettingsSwitch({
    super.key,
    required this.value,
    required this.onChanged,
  });

  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) =>
      Switch.adaptive(value: value, onChanged: onChanged);
}
