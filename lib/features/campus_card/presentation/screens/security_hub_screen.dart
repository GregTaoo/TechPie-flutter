import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/app_providers.dart';
import '../app/routes.dart';
import '../icons/platform_icons.dart';
import '../localization/geekpay_localizations.dart';
import '../widgets/apple_wallet_components.dart';

final class SecurityHubScreen extends ConsumerWidget {
  const SecurityHubScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final caps = ref.watch(appRuntimeProvider).capabilities;
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
          title: l10n.t('security'),
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
                    icon: GpPlatformIcons.password(context),
                    label: l10n.t('changePassword'),
                    value: caps.changeSpendingPassword
                        ? null
                        : l10n.t('notAvailable'),
                    onTap: caps.changeSpendingPassword
                        ? () => unawaited(
                              context.push('${GpRoutes.me}/security/password'),
                            )
                        : null,
                  ),
                  AppleListRow(
                    icon: GpPlatformIcons.limits(context),
                    label: l10n.t('limits'),
                    value: caps.spendingLimits ? null : l10n.t('notAvailable'),
                    onTap: caps.spendingLimitsRead
                        ? () => unawaited(
                              context.push('${GpRoutes.me}/security/limit'),
                            )
                        : null,
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
