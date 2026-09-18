import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/app_providers.dart';
import '../../domain/models/bill_models.dart';
import '../icons/platform_icons.dart';
import '../localization/geekpay_localizations.dart';
import '../theme/colors.dart';
import '../widgets/apple_wallet_components.dart';
import '../widgets/gp_state.dart';

final class BillTransactionScreen extends ConsumerWidget {
  const BillTransactionScreen({super.key, required this.transactionId});

  final String transactionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final detail = ref.watch(transactionDetailProvider(transactionId));
    return Scaffold(
      body: AppleWalletPage(
        child: ApplePinnedHeaderLayout(
          leading: CampusCardHeaderAction(
            id: 'back',
            sfSymbol: 'chevron.left',
            icon: GpPlatformIcons.back(context),
            label: context.l10n.t('back'),
            onPressed: () => context.pop(),
          ),
          title: context.l10n.t('transactionDetails'),
          child: CustomScrollView(
            physics: const BouncingScrollPhysics(),
            slivers: [
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(
                  20,
                  ApplePinnedHeaderLayout.contentTop,
                  20,
                  52,
                ),
                sliver: SliverList.list(
                  children: [
                    switch (detail) {
                      AsyncData(:final value) => _Detail(record: value),
                      AsyncError(:final error) => GpStateView.error(error),
                      _ => const Padding(
                          padding: EdgeInsets.all(48),
                          child: Center(
                            child: CupertinoActivityIndicator(radius: 13),
                          ),
                        ),
                    },
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

final class _Detail extends StatelessWidget {
  const _Detail({required this.record});

  final TransactionRecord record;

  @override
  Widget build(BuildContext context) {
    final amount = formatTransactionAmount(record);
    final date = context.l10n.fullDateTime(record.occurredAt);
    final extraDetails = record.details.entries.where(
      (entry) => !_canonicalTransactionFields.contains(entry.key.toLowerCase()),
    );
    return Column(
      children: [
        Icon(
          transactionIcon(context, record),
          size: 72,
          color: context.gpColors.action,
        ),
        const SizedBox(height: 18),
        Text(
          amount,
          style: TextStyle(
            color: context.gpColors.textPrimary,
            fontSize: 48,
            fontWeight: FontWeight.w500,
            letterSpacing: -1.0,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
        const SizedBox(height: 8),
        Text(
          record.merchantName?.trim().isNotEmpty == true
              ? record.merchantName!
              : record.title,
          textAlign: TextAlign.center,
          style: TextStyle(color: context.gpColors.textSecondary, fontSize: 17),
        ),
        Text(
          date,
          textAlign: TextAlign.center,
          style: TextStyle(color: context.gpColors.textSecondary, fontSize: 14),
        ),
        const SizedBox(height: 32),
        AppleSection(
          children: [
            AppleListRow(
              label: context.l10n.t('transactionType'),
              value: record.title,
            ),
            AppleListRow(
              label: context.l10n.t('transactionId'),
              value: record.id,
              valueMaxLines: null,
            ),
            if (record.location != null)
              AppleListRow(
                label: context.l10n.t('department'),
                value: record.location,
              ),
            if (record.balance != null)
              AppleListRow(
                label: context.l10n.t('balance'),
                value: formatMoneyFen(record.balance!.value),
              ),
            for (final entry in extraDetails)
              AppleListRow(
                label: _detailLabel(context, entry.key),
                value: entry.value,
                valueMaxLines: null,
              ),
          ],
        ),
      ],
    );
  }

  String _detailLabel(BuildContext context, String key) {
    final normalized = key.toLowerCase();
    final translationKey = switch (normalized) {
      'merchantno' || 'merno' => 'merchantNumber',
      'poscode' => 'posCode',
      'terminal' || 'terminalno' => 'terminal',
      'room' => 'room',
      'location' || 'address' || 'tradestation' => 'location',
      'channel' => 'channel',
      _ => null,
    };
    if (translationKey != null) return context.l10n.t(translationKey);
    return '${context.l10n.t('additionalInformation')} ($key)';
  }
}

const _canonicalTransactionFields = <String>{
  'id',
  'journo',
  'serialno',
  'tradeno',
  'orderid',
  'txdate',
  'tradetime',
  'paytime',
  'txdatetime',
  'occurtime',
  'txname',
  'tradename',
  'summary',
  'mername',
  'merchantname',
  'merchant',
  'txamt',
  'amount',
  'tradeamt',
  'balance',
  'cardbal',
  'afterbalance',
  'txtype',
  'tradetype',
  'txcode',
  'type',
};
