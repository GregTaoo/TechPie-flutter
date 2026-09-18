import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/app_providers.dart';
import '../app/routes.dart';
import '../icons/platform_icons.dart';
import '../localization/geekpay_localizations.dart';
import '../theme/colors.dart';
import '../widgets/apple_wallet_components.dart';
import '../widgets/gp_state.dart';

final class MeScreen extends ConsumerWidget {
  const MeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(profileControllerProvider);
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
            onPressed: () =>
                context.canPop() ? context.pop() : context.go(GpRoutes.pay),
          ),
          child: ListView(
            physics: const BouncingScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(
              20,
              ApplePinnedHeaderLayout.contentTop,
              20,
              52,
            ),
            children: [
              switch (profile) {
                AsyncData(:final value) => Column(
                    children: [
                      CircleAvatar(
                        radius: 42,
                        backgroundColor: context.gpColors.surfaceDisabled,
                        foregroundImage: value.avatarBytes == null
                            ? null
                            : MemoryImage(
                                Uint8List.fromList(value.avatarBytes!),
                              ),
                        child: value.avatarBytes == null
                            ? Text(
                                value.displayName.characters.first,
                                style: const TextStyle(fontSize: 28),
                              )
                            : null,
                      ),
                      const SizedBox(height: 14),
                      Text(
                        value.displayName,
                        style: const TextStyle(
                          fontSize: 28,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 4),
                      if (card == null)
                        Text(
                          value.positionName,
                          style: TextStyle(
                            color: context.gpColors.textSecondary,
                            fontSize: 15,
                          ),
                        )
                      else
                        MaskedCardNumberText(
                          maskedNumber: card.maskedNumber,
                          style: TextStyle(
                            color: context.gpColors.textSecondary,
                            fontSize: 15,
                          ),
                        ),
                    ],
                  ),
                AsyncError(:final error) => GpStateView.error(error),
                _ => const Padding(
                    padding: EdgeInsets.all(42),
                    child: CupertinoActivityIndicator(radius: 13),
                  ),
              },
              const SizedBox(height: 28),
              AppleSection(
                children: [
                  AppleListRow(
                    icon: GpPlatformIcons.card(context),
                    label: l10n.t('cardDetails'),
                    onTap: () => unawaited(context.push('/card/manage')),
                  ),
                  AppleListRow(
                    icon: GpPlatformIcons.security(context),
                    label: l10n.t('security'),
                    onTap: () =>
                        unawaited(context.push('${GpRoutes.me}/security')),
                  ),
                  AppleListRow(
                    icon: GpPlatformIcons.settings(context),
                    label: l10n.t('settings'),
                    onTap: () =>
                        unawaited(context.push('${GpRoutes.me}/settings')),
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
