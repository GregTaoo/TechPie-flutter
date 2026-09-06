import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/app_providers.dart';
import '../../domain/models/card_models.dart';
import '../../domain/ports/platform_ports.dart';
import '../app/routes.dart';
import '../icons/platform_icons.dart';
import '../localization/geekpay_localizations.dart';
import '../theme/colors.dart';
import '../widgets/apple_wallet_components.dart';
import '../widgets/gp_state.dart';

/// eCard information and activity. OpenID account management lives in
/// TechPie's Account settings.
final class CardManageScreen extends ConsumerStatefulWidget {
  const CardManageScreen({super.key});

  @override
  ConsumerState<CardManageScreen> createState() => _CardManageScreenState();
}

class _CardManageScreenState extends ConsumerState<CardManageScreen> {
  static final DateTimeRange _clearDateRangeSentinel = DateTimeRange(
    start: DateTime.utc(1900),
    end: DateTime.utc(1900),
  );

  int _segment = 0;
  DateTimeRange? _range;
  late final ScrollController _scrollController;

  @override
  void initState() {
    super.initState();
    _scrollController = ScrollController()..addListener(_loadMoreIfNeeded);
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  TransactionDateRange get _transactionQuery => (
        begin: _range == null
            ? null
            : DateTime(
                _range!.start.year,
                _range!.start.month,
                _range!.start.day,
              ),
        end: _range == null
            ? null
            : DateTime(
                _range!.end.year,
                _range!.end.month,
                _range!.end.day,
                23,
                59,
                59,
              ),
      );

  void _loadMoreIfNeeded() {
    if (_segment != 1 ||
        !_scrollController.hasClients ||
        _scrollController.position.extentAfter > 240) {
      return;
    }
    unawaited(
      ref.read(transactionFeedProvider(_transactionQuery).notifier).loadMore(),
    );
  }

  Future<void> _setSegment(int value) async {
    await ref.read(appRuntimeProvider).feedback.play(FeedbackEvent.selection);
    setState(() => _segment = value);
  }

  Future<void> _refreshActivity() async {
    final provider = transactionFeedProvider(_transactionQuery);
    ref.invalidate(provider);
    await ref.read(provider.future);
  }

  Future<void> _pickRange() async {
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      final selection = await _showCupertinoRangePicker();
      if (selection == null) return;
      await ref.read(appRuntimeProvider).feedback.play(FeedbackEvent.selection);
      setState(() => _range = selection.clear ? null : selection.range);
      return;
    }
    final now = DateTime.now();
    final selected = await showDateRangePicker(
      context: context,
      useRootNavigator: false,
      initialDateRange: _range ??
          DateTimeRange(start: DateTime(now.year, now.month, 1), end: now),
      firstDate: DateTime(2020),
      lastDate: DateTime.now().add(const Duration(days: 1)),
      saveText: context.l10n.t('done'),
      helpText: context.l10n.t('dateRange'),
      builder: (pickerContext, child) => _AndroidDateRangePickerShell(
        onClear: () => Navigator.of(
          pickerContext,
        ).pop<DateTimeRange>(_clearDateRangeSentinel),
        child: child!,
      ),
    );
    if (selected == null) return;
    await ref.read(appRuntimeProvider).feedback.play(FeedbackEvent.selection);
    setState(() {
      _range = selected.start == _clearDateRangeSentinel.start &&
              selected.end == _clearDateRangeSentinel.end
          ? null
          : selected;
    });
  }

  Future<_DateRangeSelection?> _showCupertinoRangePicker() {
    final now = DateTime.now();
    var start = _range?.start ?? DateTime(now.year, now.month, 1);
    var end = _range?.end ?? now;
    var editingStart = true;
    return showModalBottomSheet<_DateRangeSelection>(
      context: context,
      useRootNavigator: false,
      useSafeArea: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, setSheetState) => SizedBox(
          height: 390,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
                child: Row(
                  children: [
                    CupertinoButton(
                      onPressed: () => Navigator.pop(
                        sheetContext,
                        const _DateRangeSelection.clear(),
                      ),
                      child: Text(context.l10n.t('noDateRange')),
                    ),
                    const Spacer(),
                    CupertinoButton(
                      onPressed: () => Navigator.pop(
                        sheetContext,
                        _DateRangeSelection.range(
                          DateTimeRange(start: start, end: end),
                        ),
                      ),
                      child: Text(context.l10n.t('done')),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 18),
                child: CupertinoSlidingSegmentedControl<bool>(
                  groupValue: editingStart,
                  children: {
                    true: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 18),
                      child: Text(context.l10n.t('startDate')),
                    ),
                    false: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 18),
                      child: Text(context.l10n.t('endDate')),
                    ),
                  },
                  onValueChanged: (value) {
                    if (value != null) {
                      setSheetState(() => editingStart = value);
                    }
                  },
                ),
              ),
              Expanded(
                child: CupertinoDatePicker(
                  key: ValueKey(editingStart),
                  mode: CupertinoDatePickerMode.date,
                  initialDateTime: editingStart ? start : end,
                  minimumDate: DateTime(2020),
                  maximumDate: now.add(const Duration(days: 1)),
                  onDateTimeChanged: (value) {
                    setSheetState(() {
                      if (editingStart) {
                        start = value;
                        if (end.isBefore(start)) end = start;
                      } else {
                        end = value;
                        if (start.isAfter(end)) start = end;
                      }
                    });
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cardAsync = ref.watch(cardControllerProvider);
    final card = cardAsync.valueOrNull;
    final profile = ref.watch(profileControllerProvider).valueOrNull;
    final l10n = context.l10n;

    return Scaffold(
      key: const Key('card-manage-page'),
      body: AppleWalletPage(
        child: ApplePinnedHeaderLayout(
          leading: CampusCardHeaderAction(
            id: 'back',
            sfSymbol: 'chevron.left',
            icon: GpPlatformIcons.back(context),
            label: l10n.t('back'),
            onPressed: () {
              if (context.canPop()) {
                context.pop();
                return;
              }
              final hostExit = ref.read(geekPayHostExitProvider);
              if (hostExit != null) {
                hostExit();
                return;
              }
              context.go(GpRoutes.pay);
            },
          ),
          child: switch (cardAsync) {
            AsyncError(:final error) => Padding(
                padding: const EdgeInsets.fromLTRB(
                  20,
                  ApplePinnedHeaderLayout.contentTop,
                  20,
                  20,
                ),
                child: GpStateView.error(
                  error,
                  onRetry: () => ref.invalidate(cardControllerProvider),
                ),
              ),
            AsyncLoading() when card == null => const Center(
                child: CupertinoActivityIndicator(radius: 13),
              ),
            _ when card == null => Center(
                child: FilledButton(
                  onPressed: () => unawaited(context.push(GpRoutes.bindCard)),
                  child: Text(l10n.t('bindCard')),
                ),
              ),
            _ => CustomScrollView(
                controller: _scrollController,
                physics: const BouncingScrollPhysics(
                  parent: AlwaysScrollableScrollPhysics(),
                ),
                slivers: [
                  if (_segment == 1)
                    EcardSliverRefreshControl(onRefresh: _refreshActivity),
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(
                      20,
                      ApplePinnedHeaderLayout.contentTop,
                      20,
                      52,
                    ),
                    sliver: SliverList.list(
                      children: [
                        Center(
                          child: SizedBox(
                            width: 164,
                            child: CampusWalletCard(
                              card: card,
                              compact: true,
                              heroTag: 'card-details-thumbnail',
                            ),
                          ),
                        ),
                        const SizedBox(height: 22),
                        Text(
                          l10n.t('campusCard'),
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: context.gpColors.textPrimary,
                            fontSize: 28,
                            fontWeight: FontWeight.w700,
                            letterSpacing: -0.5,
                          ),
                        ),
                        const SizedBox(height: 26),
                        AppleSegmentedControl(
                          labels: [l10n.t('information'), l10n.t('activity')],
                          selectedIndex: _segment,
                          onChanged: _setSegment,
                        ),
                        const SizedBox(height: 28),
                        AnimatedSwitcher(
                          duration: MediaQuery.disableAnimationsOf(context)
                              ? Duration.zero
                              : const Duration(milliseconds: 300),
                          transitionBuilder: (child, animation) {
                            final offset = _segment == 0
                                ? const Offset(-0.06, 0)
                                : const Offset(0.06, 0);
                            return FadeTransition(
                              opacity: animation,
                              child: SlideTransition(
                                position: Tween<Offset>(
                                  begin: offset,
                                  end: Offset.zero,
                                ).animate(animation),
                                child: child,
                              ),
                            );
                          },
                          child: _segment == 0
                              ? _InformationTab(
                                  key: const ValueKey('info'),
                                  card: card,
                                  profilePosition: profile?.positionName,
                                )
                              : _ActivityTab(
                                  key: const ValueKey('activity'),
                                  range: _range,
                                  onPickRange: _pickRange,
                                ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
          },
        ),
      ),
    );
  }
}

final class _InformationTab extends ConsumerWidget {
  const _InformationTab({
    super.key,
    required this.card,
    required this.profilePosition,
  });

  final CampusCard card;
  final String? profilePosition;

  String _date(BuildContext context, DateTime? value) =>
      value == null ? '—' : context.l10n.fullDateTime(value);

  String _status(BuildContext context) => switch (card.status) {
        CampusCardStatus.normal => context.l10n.t('normal'),
        CampusCardStatus.lost => context.l10n.t('lost'),
        CampusCardStatus.frozen ||
        CampusCardStatus.manualFrozen =>
          context.l10n.t('frozen'),
        CampusCardStatus.closed => context.l10n.t('closed'),
        CampusCardStatus.preclosed => context.l10n.t('preclosed'),
        CampusCardStatus.unknown => '—',
      };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    return Column(
      children: [
        AppleSection(
          children: [
            AppleListRow(label: l10n.t('name'), value: card.ownerName),
            AppleListRow(
              label: l10n.t('identity'),
              value: profilePosition ?? card.positionName,
            ),
            AppleListRow(
              label: l10n.t('department'),
              value: card.departmentName ?? card.schoolName ?? '—',
            ),
            AppleListRow(label: l10n.t('status'), value: _status(context)),
            AppleListRow(
              label: l10n.t('validUntil'),
              value: _date(context, card.validUntil),
            ),
            AppleListRow(
              label: l10n.t('lastLogin'),
              value: _date(context, card.lastTransactionAt),
            ),
          ],
        ),
        const SizedBox(height: 18),
        AppleSection(
          children: [
            AppleListRow(
              icon: GpPlatformIcons.security(context),
              label: l10n.t('security'),
              onTap: () => unawaited(context.push('${GpRoutes.me}/security')),
            ),
            AppleListRow(
              icon: GpPlatformIcons.offline(context),
              label: l10n.t('offlineAuthorization'),
              onTap: () => unawaited(context.push(GpRoutes.offline)),
            ),
            AppleListRow(
              icon: GpPlatformIcons.settings(context),
              label: l10n.t('settings'),
              onTap: () => unawaited(context.push('${GpRoutes.me}/settings')),
            ),
          ],
        ),
        if (Theme.of(context).platform == TargetPlatform.android ||
            Theme.of(context).platform == TargetPlatform.iOS) ...[
          const SizedBox(height: 18),
          AppleSection(
            footer: l10n.t('widgetGuideSummary'),
            children: [
              AppleListRow(
                key: const Key('add-pay-widget'),
                icon: GpPlatformIcons.homeWidget(context),
                label: l10n.t('addPayWidget'),
                onTap: () => unawaited(context.push(GpRoutes.widgetSetup)),
              ),
            ],
          ),
        ],
      ],
    );
  }
}

final class _ActivityTab extends ConsumerWidget {
  const _ActivityTab({
    super.key,
    required this.range,
    required this.onPickRange,
  });

  final DateTimeRange? range;
  final VoidCallback onPickRange;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final query = (
      begin: range == null
          ? null
          : DateTime(range!.start.year, range!.start.month, range!.start.day),
      end: range == null
          ? null
          : DateTime(
              range!.end.year,
              range!.end.month,
              range!.end.day,
              23,
              59,
              59,
            ),
    );
    final transactions = ref.watch(transactionFeedProvider(query));
    return Column(
      children: [
        AppleSection(
          children: [
            AppleListRow(
              label: context.l10n.t('dateRange'),
              value: range == null
                  ? context.l10n.t('noDateRange')
                  : context.l10n.dateRangeDays(range!.start, range!.end),
              icon: GpPlatformIcons.calendar(context),
              onTap: onPickRange,
            ),
          ],
        ),
        const SizedBox(height: 20),
        switch (transactions) {
          AsyncData(:final value) => Column(
              children: [
                TransactionList(
                  items: value.items,
                  onTap: (record) => unawaited(
                    context.push(GpRoutes.transactionDetail(record.id)),
                  ),
                ),
                if (value.hasMore) ...[
                  const SizedBox(height: 12),
                  CupertinoButton(
                    onPressed: () => unawaited(
                      ref
                          .read(transactionFeedProvider(query).notifier)
                          .loadMore(),
                    ),
                    child: Text(context.l10n.t('loadMore')),
                  ),
                ],
              ],
            ),
          AsyncError(:final error) => GpStateView.error(
              error,
              onRetry: () => ref.invalidate(transactionFeedProvider(query)),
            ),
          _ => const Padding(
              padding: EdgeInsets.all(42),
              child: CupertinoActivityIndicator(radius: 13),
            ),
        },
      ],
    );
  }
}

final class _DateRangeSelection {
  const _DateRangeSelection.range(this.range) : clear = false;
  const _DateRangeSelection.clear()
      : clear = true,
        range = null;

  final bool clear;
  final DateTimeRange? range;
}

final class _AndroidDateRangePickerShell extends StatelessWidget {
  const _AndroidDateRangePickerShell({
    required this.child,
    required this.onClear,
  });

  final Widget child;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final actionColor = context.gpColors.action;
    final theme = Theme.of(context);
    return Theme(
      data: theme.copyWith(
        appBarTheme: theme.appBarTheme.copyWith(
          systemOverlayStyle: theme.brightness == Brightness.dark
              ? SystemUiOverlayStyle.light
              : SystemUiOverlayStyle.dark,
        ),
      ),
      child: Stack(
        fit: StackFit.expand,
        children: [
          child,
          Positioned(
            left: 24,
            right: 24,
            bottom: MediaQuery.paddingOf(context).bottom + 18,
            child: Material(
              color: Colors.transparent,
              child: OutlinedButton(
                key: const Key('android-date-range-clear'),
                onPressed: onClear,
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size.fromHeight(48),
                  foregroundColor: actionColor,
                  backgroundColor: actionColor.withValues(alpha: 0.08),
                  side: BorderSide(color: actionColor.withValues(alpha: 0.28)),
                  shape: const StadiumBorder(),
                ),
                child: Text(context.l10n.t('noDateRange')),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
