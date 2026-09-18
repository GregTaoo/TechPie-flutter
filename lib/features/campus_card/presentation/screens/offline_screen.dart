import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/app_providers.dart';
import '../../domain/models/offline_models.dart';
import '../../domain/ports/platform_ports.dart';
import '../icons/geekpay_icons.dart';
import '../icons/platform_icons.dart';
import '../localization/geekpay_localizations.dart';
import '../theme/colors.dart';
import '../widgets/apple_wallet_components.dart';
import '../widgets/gp_state.dart';

final class OfflineAuthorizationScreen extends ConsumerWidget {
  const OfflineAuthorizationScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final card = ref.watch(cardControllerProvider).valueOrNull;
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
          title: l10n.t('offlineAuthorization'),
          child: ListView(
            physics: const BouncingScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(
              20,
              ApplePinnedHeaderLayout.contentTop,
              20,
              52,
            ),
            children: [
              if (card == null)
                GpStateView(
                  icon: GpIcons.card,
                  title: l10n.t('bindCard'),
                  description: l10n.t('cardUnavailable'),
                )
              else ...[
                Center(
                  child: SizedBox(
                    width: 170,
                    child: CampusWalletCard(
                      card: card,
                      compact: true,
                      heroTag: 'offline-card',
                    ),
                  ),
                ),
                const SizedBox(height: 26),
                _AuthorizationBody(cardId: card.id),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

final class _AuthorizationBody extends ConsumerWidget {
  const _AuthorizationBody({required this.cardId});

  final String cardId;

  String _date(BuildContext context, DateTime? value) =>
      value == null ? '—' : context.l10n.fullDateTime(value);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(offlineAuthorizationProvider(cardId));
    final l10n = context.l10n;
    return switch (state) {
      AsyncError(:final error) => _PlainAuthorizationError(
          error,
          onRetry: () => ref.invalidate(offlineAuthorizationProvider(cardId)),
        ),
      AsyncLoading() => const Padding(
          padding: EdgeInsets.all(42),
          child: CupertinoActivityIndicator(radius: 13),
        ),
      AsyncData(:final value) => Column(
          children: [
            AppleSection(
              children: [
                AppleListRow(
                  icon: value.state == OfflineAuthorizationState.active ||
                          value.state == OfflineAuthorizationState.renewalDue
                      ? GpPlatformIcons.successCircle(context)
                      : GpPlatformIcons.errorCircle(context),
                  label: l10n.t('status'),
                  value: _stateLabel(context, value.state),
                ),
                if (value.authorization?.isLimited == true)
                  AppleListRow(
                    label: l10n.t('remainingUses'),
                    value: value.authorization!.remaining.toString(),
                  ),
                AppleListRow(
                  label: l10n.t('expiresOn'),
                  value: _date(context, value.authorization?.expiresOn),
                ),
              ],
            ),
            const SizedBox(height: 18),
            if (value.state == OfflineAuthorizationState.unavailable ||
                value.state == OfflineAuthorizationState.missingCredential)
              FilledButton(
                onPressed: () => unawaited(
                  _runAction(
                    context,
                    ref,
                    () => ref
                        .read(offlineAuthorizationProvider(cardId).notifier)
                        .activate(),
                  ),
                ),
                style: FilledButton.styleFrom(
                  backgroundColor: context.gpColors.action,
                  minimumSize: const Size.fromHeight(54),
                  shape: const StadiumBorder(),
                ),
                child: Text(l10n.t('activate')),
              )
            else ...[
              AppleSection(
                footer: l10n.t('clientOnlyRemoveNotice'),
                children: [
                  AppleListRow(
                    icon: GpPlatformIcons.refresh(context),
                    label: l10n.t('renew'),
                    onTap: () => unawaited(
                      _runAction(context, ref, () async {
                        await ref
                            .read(appRuntimeProvider)
                            .feedback
                            .play(FeedbackEvent.selection);
                        if (!context.mounted) return;
                        await ref
                            .read(offlineAuthorizationProvider(cardId).notifier)
                            .renew();
                      }),
                    ),
                  ),
                  AppleListRow(
                    icon: GpPlatformIcons.delete(context),
                    label: l10n.t('removeFromDevice'),
                    destructive: true,
                    onTap: () => unawaited(_remove(context, ref)),
                  ),
                ],
              ),
            ],
          ],
        ),
      _ => const SizedBox.shrink(),
    };
  }

  String _stateLabel(BuildContext context, OfflineAuthorizationState state) =>
      switch (state) {
        OfflineAuthorizationState.active ||
        OfflineAuthorizationState.renewalDue ||
        OfflineAuthorizationState.expired ||
        OfflineAuthorizationState.exhausted =>
          context.l10n.t('opened'),
        OfflineAuthorizationState.missingCredential ||
        OfflineAuthorizationState.unavailable =>
          context.l10n.t('notOpened'),
      };

  Future<void> _remove(BuildContext context, WidgetRef ref) async {
    final accepted = await showAdaptiveDialog<bool>(
      context: context,
      useRootNavigator: false,
      builder: (dialogContext) => AlertDialog.adaptive(
        title: Text(context.l10n.t('removeFromDevice')),
        content: Text(context.l10n.t('clientOnlyRemoveNotice')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(context.l10n.t('cancel')),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(context.l10n.t('delete')),
          ),
        ],
      ),
    );
    if (accepted == true && context.mounted) {
      await ref
          .read(offlineAuthorizationProvider(cardId).notifier)
          .removeFromDevice();
    }
  }

  Future<void> _runAction(
    BuildContext context,
    WidgetRef ref,
    Future<void> Function() action,
  ) async {
    try {
      await action();
    } catch (error) {
      if (!context.mounted) return;
      await ref.read(appRuntimeProvider).feedback.play(FeedbackEvent.error);
      if (!context.mounted) return;
      await showAdaptiveDialog<void>(
        context: context,
        useRootNavigator: false,
        builder: (dialogContext) => AlertDialog.adaptive(
          title: Text(context.l10n.t('offlineAuthorization')),
          content: Text(GpStateView.safeUiError(error)),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: Text(context.l10n.t('done')),
            ),
          ],
        ),
      );
    }
  }
}

final class _PlainAuthorizationError extends StatelessWidget {
  const _PlainAuthorizationError(this.error, {required this.onRetry});

  final Object error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Container(
        key: const Key('offline-authorization-error'),
        width: double.infinity,
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              GpStateView.safeUiError(error),
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 12),
            TextButton(
              onPressed: onRetry,
              child: Text(context.l10n.t('retry')),
            ),
          ],
        ),
      );
}
