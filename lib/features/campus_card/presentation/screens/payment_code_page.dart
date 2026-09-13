import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../app/app_providers.dart';
import '../../application/confirmed_disconnect_feedback.dart';
import '../../core/config/debug_mode_controller.dart';
import '../../core/config/debug_mode_features.dart';
import '../../core/config/offline_authorization_banner_controller.dart';
import '../../domain/models/card_models.dart';
import '../../domain/models/offline_models.dart';
import '../../domain/models/payment_models.dart';
import '../../domain/ports/platform_ports.dart';
import '../app/routes.dart';
import '../app/shell.dart';
import '../icons/geekpay_icons.dart';
import '../icons/platform_icons.dart';
import '../localization/geekpay_localizations.dart';
import '../theme/colors.dart';
import '../theme/tokens.dart';
import '../widgets/apple_wallet_components.dart';
import '../widgets/gp_state.dart';

/// Expanded pass surface from the supplied design: card header, online/offline
/// indicator, live QR or animated result, cardholder data, and recent activity.
final class PaymentCodePage extends ConsumerStatefulWidget {
  const PaymentCodePage({super.key});

  @override
  ConsumerState<PaymentCodePage> createState() => _PaymentCodePageState();
}

class _PaymentCodePageState extends ConsumerState<PaymentCodePage> {
  static const TransactionDateRange _allTransactions = (begin: null, end: null);

  PaymentCodeNotifier get _paymentCodes =>
      ref.read(paymentCodeControllerProvider.notifier);
  bool _offline = false;
  bool _offlineBusy = false;
  String? _offlinePayload;
  String? _offlineError;
  int? _offlineRemaining;
  StreamSubscription<bool>? _connectivitySubscription;
  StreamSubscription<AppLifecycleState>? _lifecycleSubscription;
  Timer? _onlineRetryTimer;
  bool _scannerOpen = false;
  bool _visible = false;
  bool _foreground = false;
  bool _active = false;
  int _activityRevision = 0;
  late final ConfirmedDisconnectFeedback _disconnectFeedback;

  @override
  void initState() {
    super.initState();
    final runtime = ref.read(appRuntimeProvider);
    _foreground = runtime.lifecycle.current == AppLifecycleState.resumed;
    _lifecycleSubscription = runtime.lifecycle.changes.listen((state) {
      _foreground = state == AppLifecycleState.resumed;
      _updateActivity(defer: false);
    });
    _disconnectFeedback = ConfirmedDisconnectFeedback(
      connectivity: runtime.connectivity,
      lifecycle: runtime.lifecycle,
      feedback: runtime.feedback,
    );
    unawaited(_disconnectFeedback.start());
    _connectivitySubscription = ref
        .read(appRuntimeProvider)
        .connectivity
        .changes
        .listen(_handleConnectivity);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Navigator's Overlay disables this mode below opaque routes, including
    // routes in the host navigator. Non-opaque status sheets stay visible.
    _visible = TickerMode.of(context);
    _updateActivity(defer: true);
  }

  void _updateActivity({required bool defer}) {
    if (!mounted) return;
    final next = _visible && _foreground && !_scannerOpen;
    if (next == _active) return;
    if (defer) {
      _active = next;
    } else {
      setState(() => _active = next);
    }
    if (!next) _onlineRetryTimer?.cancel();
    final revision = ++_activityRevision;
    if (defer) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        unawaited(_applyActivity(revision));
      });
    } else {
      // Backgrounding may stop frame delivery, so release resources now.
      unawaited(_applyActivity(revision));
    }
  }

  Future<void> _applyActivity(int revision) async {
    if (!mounted || revision != _activityRevision) return;
    if (_active) {
      await _paymentCodes.enter(online: !ref.read(manualOfflineModeProvider));
    } else {
      await _paymentCodes.leave();
    }
  }

  @override
  void dispose() {
    unawaited(_disconnectFeedback.dispose());
    unawaited(_lifecycleSubscription?.cancel());
    _onlineRetryTimer?.cancel();
    unawaited(_connectivitySubscription?.cancel());
    super.dispose();
  }

  void _handleConnectivity(bool online) {
    if (!mounted || !_active) return;
    final card = ref.read(cardControllerProvider).valueOrNull;
    if (card == null) return;
    if (online) {
      unawaited(
        ref
            .read(offlineAuthorizationProvider(card.id).notifier)
            .maintain(force: false),
      );
    }
    if (ref.read(manualOfflineModeProvider)) return;
    if (!online) {
      _paymentCodes.markDisconnected();
    } else {
      final payment = ref.read(paymentCodeControllerProvider);
      if (payment.phase == PaymentCodePhase.initializing ||
          payment.connectionState == PaymentConnectionState.online) {
        return;
      }
      setState(() => _offline = false);
      unawaited(_paymentCodes.restart());
    }
  }

  Future<void> _refreshOnline() async {
    await ref.read(appRuntimeProvider).feedback.play(FeedbackEvent.selection);
    if (!mounted || !_active) return;
    await ref.read(paymentCodeControllerProvider.notifier).restart();
  }

  Future<void> _setOfflineMode(CampusCard card, bool enabled) async {
    await ref.read(appRuntimeProvider).feedback.play(FeedbackEvent.selection);
    if (!mounted) return;
    ref.read(manualOfflineModeProvider.notifier).setEnabled(enabled);
    if (!enabled) {
      setState(() {
        _offline = false;
        _offlineError = null;
      });
      if (_active) await _paymentCodes.restart();
      return;
    }
    if (_active) await _paymentCodes.enter(online: false);
    if (!mounted) return;
    await _generateOffline(card, switching: true);
    if (!mounted) return;
    if (_offlinePayload == null) {
      ref.read(manualOfflineModeProvider.notifier).setEnabled(false);
      if (_active) await _paymentCodes.restart();
    }
  }

  Future<void> _generateOffline(
    CampusCard card, {
    bool switching = false,
  }) async {
    if (_offlineBusy) return;
    setState(() {
      _offlineBusy = true;
      _offlineError = null;
      if (switching) _offline = true;
    });
    try {
      final controller = ref.read(
        offlineAuthorizationProvider(card.id).notifier,
      );
      final view = await ref.read(offlineAuthorizationProvider(card.id).future);
      if (view.state != OfflineAuthorizationState.active &&
          view.state != OfflineAuthorizationState.renewalDue) {
        throw StateError('OFFLINE_AUTH_REQUIRED');
      }
      final code = await controller.generate();
      final refreshed = await ref.read(
        offlineAuthorizationProvider(card.id).future,
      );
      if (!mounted) return;
      setState(() {
        _offline = true;
        _offlinePayload = code.payload;
        _offlineRemaining = refreshed.authorization?.remaining;
      });
    } catch (error) {
      if (!mounted) return;
      final authorizationRequired = error.toString().contains(
            'OFFLINE_AUTH_REQUIRED',
          );
      setState(() {
        _offlineError =
            authorizationRequired ? null : GpStateView.safeUiError(error);
        _offlinePayload = null;
        _offlineRemaining = null;
        _offline = false;
      });
      if (authorizationRequired) {
        ref.invalidate(offlineAuthorizationProvider(card.id));
      } else {
        await ref.read(appRuntimeProvider).feedback.play(FeedbackEvent.error);
      }
    } finally {
      if (mounted) setState(() => _offlineBusy = false);
    }
  }

  Future<void> _refreshRecentTransactions() async {
    ref.invalidate(transactionFeedProvider(_allTransactions));
    await _loadRecentTransactions();
  }

  Future<void> _refreshAfterPayment() async {
    // Refresh through the card controller so its identity checks and cached
    // balance stay intact while the confirmed success animation is displayed.
    final cardRefresh = ref.read(cardControllerProvider.notifier).refresh();
    ref.invalidate(transactionFeedProvider);
    await Future.wait<void>([
      _loadRecentTransactions(),
      cardRefresh.then<void>((_) {}, onError: (Object _) {}),
    ]);
  }

  Future<void> _loadRecentTransactions() async {
    try {
      await ref.read(transactionFeedProvider(_allTransactions).future);
    } catch (_) {
      // The activity feed reports its own error without changing the outcome.
    }
  }

  @override
  Widget build(BuildContext context) {
    final cardAsync = ref.watch(cardControllerProvider);
    final card = cardAsync.valueOrNull;
    // Starting/finishing a pending poll changes no visible content.
    ref.watch(
      paymentCodeControllerProvider.select(
        (value) => (
          value.phase == PaymentCodePhase.polling
              ? PaymentCodePhase.displaying
              : value.phase,
          value.generation,
          value.frame,
          value.result,
          value.message,
          value.connectionState,
          value.requestLatency,
        ),
      ),
    );
    final payment = ref.read(paymentCodeControllerProvider);
    // A same-account session renewal replaces the controller without changing
    // this page's visibility. Start the replacement after the build completes.
    if (_active && payment.phase == PaymentCodePhase.idle) {
      final revision = _activityRevision;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted &&
            _active &&
            revision == _activityRevision &&
            ref.read(paymentCodeControllerProvider).phase ==
                PaymentCodePhase.idle) {
          unawaited(_applyActivity(revision));
        }
      });
    }
    final transactions = ref.watch(transactionFeedProvider(_allTransactions));
    final l10n = context.l10n;
    final hostExit = ref.watch(geekPayHostExitProvider);
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final manualOffline = ref.watch(manualOfflineModeProvider);
    final debugMode =
        debugModeFeaturesAvailable && ref.watch(debugModeProvider);
    final offlineAuthorization =
        card == null ? null : ref.watch(offlineAuthorizationProvider(card.id));
    final bannerDismissed = ref.watch(
      offlineAuthorizationBannerDismissedProvider,
    );
    final authorizationState = offlineAuthorization?.valueOrNull?.state;
    final canGenerateOffline =
        authorizationState == OfflineAuthorizationState.active ||
            authorizationState == OfflineAuthorizationState.renewalDue;
    final showOfflineAuthorizationBanner = card != null &&
        bannerDismissed.valueOrNull == false &&
        (authorizationState == OfflineAuthorizationState.missingCredential ||
            authorizationState == OfflineAuthorizationState.unavailable);

    ref.listen(paymentCodeControllerProvider, (previous, next) {
      if (next.phase == PaymentCodePhase.initializing && _offlineError != null) {
        setState(() => _offlineError = null);
      }
      if (card == null) {
        return;
      }
      if (next.connectionState == PaymentConnectionState.online &&
          !manualOffline) {
        _onlineRetryTimer?.cancel();
        if (_offline) setState(() => _offline = false);
      }
      if (next.phase == PaymentCodePhase.succeeded &&
          previous?.phase != PaymentCodePhase.succeeded) {
        unawaited(_refreshAfterPayment());
      }
      final shouldFallback = next.phase == PaymentCodePhase.switchingOffline ||
          (next.phase == PaymentCodePhase.failed &&
              next.connectionState != PaymentConnectionState.online);
      if (shouldFallback) {
        if (_active && canGenerateOffline &&
            !_offline && !_offlineBusy && _offlineError == null) {
          unawaited(_generateOffline(card, switching: true));
        }
        _scheduleOnlineRetry();
      }
    });

    final onlineFailed = payment.phase == PaymentCodePhase.switchingOffline ||
        (payment.phase == PaymentCodePhase.failed &&
            payment.connectionState != PaymentConnectionState.online);
    if (onlineFailed && _onlineRetryTimer?.isActive != true) {
      _scheduleOnlineRetry();
    }
    if (_active &&
        card != null &&
        canGenerateOffline &&
        (manualOffline || onlineFailed) &&
        !_offline &&
        !_offlineBusy &&
        _offlineError == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _active) {
          unawaited(_generateOffline(card, switching: true));
        }
      });
    }

    final transactionPage = transactions.valueOrNull;
    final realTransactionCount = transactionPage?.items
        .where((record) => !record.id.startsWith('DEBUG-'))
        .length;
    if (_active &&
        transactionPage != null &&
        transactionPage.hasMore &&
        (realTransactionCount ?? 0) < 25) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_active) return;
        unawaited(
          ref
              .read(transactionFeedProvider(_allTransactions).notifier)
              .loadMore(),
        );
      });
    }

    final page = Scaffold(
      key: const Key('payment-code-page'),
      body: _scannerOpen
          ? const ColoredBox(color: Colors.black)
          : AppleWalletPage(
              child: ApplePinnedHeaderLayout(
                title: l10n.t('showPaymentCode'),
                leading: hostExit == null
                    ? null
                    : CampusCardHeaderAction(
                        id: 'back',
                        sfSymbol: 'chevron.left',
                        icon: GpPlatformIcons.back(context),
                        label: l10n.t('back'),
                        onPressed: hostExit,
                      ),
                actions: [
                  CampusCardHeaderAction(
                    id: 'scan',
                    sfSymbol: 'qrcode.viewfinder',
                    label: l10n.t('scanToPay'),
                    onPressed: _openScanner,
                    icon: GpPlatformIcons.scan(context),
                    iconSize: 25,
                  ),
                  CampusCardHeaderAction(
                    id: 'info',
                    sfSymbol: 'info.circle',
                    key: const Key('payment-header-info'),
                    label: l10n.t('cardDetails'),
                    onPressed: () => unawaited(context.push('/card/manage')),
                    icon: GpPlatformIcons.info(context),
                  ),
                ],
                child: CustomScrollView(
                  physics: const BouncingScrollPhysics(
                    parent: AlwaysScrollableScrollPhysics(),
                  ),
                  slivers: [
                    EcardSliverRefreshControl(
                      onRefresh: _refreshRecentTransactions,
                    ),
                    SliverPadding(
                      padding: const EdgeInsets.fromLTRB(
                        18,
                        ApplePinnedHeaderLayout.contentTop,
                        18,
                        0,
                      ),
                      sliver: SliverList.list(
                        children: [
                          if (card != null)
                            _ExpandedPaymentPass(
                              card: card,
                              payment: payment,
                              offline: _offline,
                              offlineBusy: _offlineBusy,
                              offlinePayload: _offlinePayload,
                              offlineRemaining: _offlineRemaining,
                              reduceMotion: reduceMotion,
                              active: _active,
                              onShowStatus: () => unawaited(
                                _showStatusSheet(
                                  card: card,
                                  payment: payment,
                                  manualOffline: manualOffline,
                                ),
                              ),
                              onRefreshOnline: _refreshOnline,
                              onRefreshOffline: () =>
                                  unawaited(_generateOffline(card)),
                              onActivateOnline: () => unawaited(
                                ref
                                    .read(
                                      paymentCodeControllerProvider.notifier,
                                    )
                                    .activateAndRestart(),
                              ),
                            )
                          else
                            switch (cardAsync) {
                              AsyncError(:final error) => GpStateView.error(
                                  error,
                                  onRetry: () => unawaited(
                                    ref
                                        .read(cardControllerProvider.notifier)
                                        .refresh(),
                                  ),
                                ),
                              AsyncData() => GpStateView(
                                  icon: GpIcons.card,
                                  title: l10n.t('bindCard'),
                                  description: l10n.t('cardUnavailable'),
                                ),
                              _ => const _PaymentCardLoading(),
                            },
                          if (debugMode && card != null) ...[
                            const SizedBox(height: 12),
                            SizedBox(
                              width: double.infinity,
                              child: OutlinedButton.icon(
                                onPressed: () => ref
                                    .read(
                                      paymentCodeControllerProvider.notifier,
                                    )
                                    .debugComplete(),
                                icon: Icon(GpPlatformIcons.debug(context)),
                                label: Text(l10n.t('debugPaymentSuccess')),
                              ),
                            ),
                          ],
                          if (showOfflineAuthorizationBanner) ...[
                            const SizedBox(height: 12),
                            _OfflineAuthorizationBanner(
                              onActivate: () =>
                                  unawaited(context.push(GpRoutes.offline)),
                              onDismiss: () async {
                                await ref
                                    .read(
                                      offlineAuthorizationBannerDismissedProvider
                                          .notifier,
                                    )
                                    .dismiss();
                              },
                            ),
                          ],
                          if (_offlineError != null) ...[
                            const SizedBox(height: 12),
                            Container(
                              padding: const EdgeInsets.all(14),
                              decoration: BoxDecoration(
                                color: context.gpColors.danger.withValues(
                                  alpha: 0.09,
                                ),
                                borderRadius: BorderRadius.circular(16),
                              ),
                              child: Row(
                                children: [
                                  Expanded(child: Text(_offlineError!)),
                                  TextButton(
                                    onPressed: () => unawaited(
                                      context.push(GpRoutes.offline),
                                    ),
                                    child: Text(l10n.t('offlineAuthorization')),
                                  ),
                                ],
                              ),
                            ),
                          ],
                          const SizedBox(height: 30),
                          Text(
                            l10n.t('recentActivity'),
                            style: TextStyle(
                              color: context.gpColors.textPrimary,
                              fontSize: 24,
                              fontWeight: FontWeight.w700,
                              letterSpacing: -0.3,
                            ),
                          ),
                          const SizedBox(height: 10),
                        ],
                      ),
                    ),
                    SliverPadding(
                      padding: const EdgeInsets.fromLTRB(18, 0, 18, 52),
                      sliver: switch (transactions) {
                        AsyncData(:final value) => TransactionList(
                            items: value.items
                                .where(
                                  (record) => !record.id.startsWith('DEBUG-'),
                                )
                                .take(25)
                                .toList(),
                            onTap: (record) => unawaited(
                              context.push(
                                GpRoutes.transactionDetail(record.id),
                              ),
                            ),
                          ),
                        AsyncError(:final error) => SliverToBoxAdapter(
                            child: GpStateView.error(
                              error,
                              onRetry: () => ref.invalidate(
                                transactionFeedProvider(_allTransactions),
                              ),
                            ),
                          ),
                        _ => SliverToBoxAdapter(
                            child: Container(
                              height: 128,
                              decoration: BoxDecoration(
                                color: context.gpColors.surface,
                                borderRadius: BorderRadius.circular(24),
                              ),
                              child: Center(
                                child: CupertinoActivityIndicator(
                                  color: context.gpColors.textSecondary,
                                ),
                              ),
                            ),
                          ),
                      },
                    ),
                  ],
                ),
              ),
            ),
    );
    return TickerMode(enabled: _active, child: page);
  }

  Future<void> _openScanner() async {
    if (_scannerOpen) return;
    setState(() => _scannerOpen = true);
    _updateActivity(defer: false);
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    try {
      await openGpScanner(context);
    } finally {
      if (mounted) {
        setState(() => _scannerOpen = false);
        _updateActivity(defer: false);
      }
    }
  }

  void _scheduleOnlineRetry() {
    if (!_active || ref.read(manualOfflineModeProvider)) return;
    _onlineRetryTimer?.cancel();
    _onlineRetryTimer = Timer(const Duration(seconds: 15), () {
      if (!mounted || !_active || ref.read(manualOfflineModeProvider)) return;
      unawaited(_paymentCodes.restart());
    });
  }

  Future<void> _showStatusSheet({
    required CampusCard card,
    required PaymentCodeViewState payment,
    required bool manualOffline,
  }) async {
    final l10n = context.l10n;
    final stateLabel = switch (payment.connectionState) {
      PaymentConnectionState.online => l10n.t('networkOnline'),
      PaymentConnectionState.disconnected => l10n.t('networkDisconnected'),
      PaymentConnectionState.apiError => l10n.t('networkApiError'),
      PaymentConnectionState.unknown => l10n.t('networkChecking'),
    };
    final latency = payment.requestLatency == null
        ? '--'
        : '${payment.requestLatency!.inMilliseconds} ms';
    final selected = await showModalBottomSheet<bool>(
      context: context,
      useRootNavigator: false,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (sheetContext) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AppleSection(
              children: [
                AppleListRow(label: l10n.t('onlineStatus'), value: stateLabel),
                AppleListRow(label: l10n.t('requestLatency'), value: latency),
                AppleListRow(
                  label: l10n.t('offlineCode'),
                  verticalPadding: 4,
                  trailing: Switch.adaptive(
                    value: manualOffline ||
                        _offline ||
                        payment.connectionState ==
                            PaymentConnectionState.disconnected ||
                        payment.connectionState ==
                            PaymentConnectionState.apiError,
                    onChanged: (value) => Navigator.pop(sheetContext, value),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              manualOffline
                  ? l10n.t('manualOfflineActive')
                  : l10n.t('automaticOfflineMode'),
              textAlign: TextAlign.center,
              style: TextStyle(color: context.gpColors.textSecondary),
            ),
          ],
        ),
      ),
    );
    if (selected != null && mounted) await _setOfflineMode(card, selected);
  }
}

final class _PaymentCardLoading extends StatelessWidget {
  const _PaymentCardLoading();

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: 746 / 984,
      child: DecoratedBox(
        key: const Key('payment-card-loading'),
        decoration: BoxDecoration(
          color: context.gpColors.surface,
          borderRadius: BorderRadius.circular(20),
        ),
        child: const Center(child: _PaymentCodeActivityIndicator()),
      ),
    );
  }
}

final class _PaymentCodeActivityIndicator extends StatelessWidget {
  const _PaymentCodeActivityIndicator({super.key, this.radius = 10});

  final double radius;

  @override
  Widget build(BuildContext context) => CupertinoActivityIndicator(
        color: GpTokens.campusRed,
        radius: radius,
      );
}

final class _OfflineAuthorizationBanner extends StatelessWidget {
  const _OfflineAuthorizationBanner({
    required this.onActivate,
    required this.onDismiss,
  });

  final VoidCallback onActivate;
  final Future<void> Function() onDismiss;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Semantics(
      container: true,
      label: l10n.t('offlineAuthorizationBannerPrompt'),
      child: Container(
        key: const Key('offline-authorization-banner'),
        padding: const EdgeInsets.fromLTRB(16, 10, 4, 10),
        decoration: BoxDecoration(
          color: context.gpColors.warning.withValues(alpha: 0.11),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: context.gpColors.warning.withValues(alpha: 0.22),
          ),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                l10n.t('offlineAuthorizationBannerPrompt'),
                style: const TextStyle(fontWeight: FontWeight.w500),
              ),
            ),
            TextButton(onPressed: onActivate, child: Text(l10n.t('activate'))),
            IconButton(
              key: const Key('offline-authorization-banner-close'),
              tooltip: l10n.t('close'),
              visualDensity: VisualDensity.compact,
              onPressed: () => unawaited(onDismiss()),
              icon: Icon(GpPlatformIcons.close(context), size: 17),
            ),
          ],
        ),
      ),
    );
  }
}

final class _ExpandedPaymentPass extends StatelessWidget {
  const _ExpandedPaymentPass({
    required this.card,
    required this.payment,
    required this.offline,
    required this.offlineBusy,
    required this.offlinePayload,
    required this.offlineRemaining,
    required this.reduceMotion,
    required this.active,
    required this.onShowStatus,
    required this.onRefreshOnline,
    required this.onRefreshOffline,
    required this.onActivateOnline,
  });

  final CampusCard card;
  final PaymentCodeViewState payment;
  final bool offline;
  final bool offlineBusy;
  final String? offlinePayload;
  final int? offlineRemaining;
  final bool reduceMotion;
  final bool active;
  final VoidCallback onShowStatus;
  final VoidCallback onRefreshOnline;
  final VoidCallback onRefreshOffline;
  final VoidCallback onActivateOnline;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final succeeded = !offline && payment.phase == PaymentCodePhase.succeeded;
    final result = payment.result;
    final payload = offline ? offlinePayload : payment.frame?.qrPayload;
    final loading = offline
        ? offlineBusy
        : payment.phase == PaymentCodePhase.initializing ||
            payment.phase == PaymentCodePhase.refreshing ||
            payment.phase == PaymentCodePhase.stopped;
    final showCodeMetadata = offline ||
        payment.phase == PaymentCodePhase.displaying ||
        payment.phase == PaymentCodePhase.refreshing ||
        payment.phase == PaymentCodePhase.polling;
    final ownerName = card.detailsAvailable
        ? cardholderDisplayName(
            card.ownerName,
            languageCode: Localizations.localeOf(context).languageCode,
          )
        : l10n.t('campusCardShort');

    return Hero(
      tag: 'campus-card',
      child: Material(
        key: const Key('expanded-payment-pass'),
        color: GpTokens.cardCanvas,
        elevation: 5,
        shadowColor: Colors.black.withValues(alpha: 0.20),
        borderRadius: BorderRadius.circular(20),
        clipBehavior: Clip.antiAlias,
        child: AspectRatio(
          aspectRatio: 746 / 984,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final width = constraints.maxWidth;
              final headerHeight = width * 126 / 746;
              final statusSize = _scaled(width, 0.128, 47, 67);
              final qrSize = width * 0.668;
              final qrTop = width * 0.06;
              final metadataTop = width * 0.75;
              final horizontalPadding = width * 0.049;
              final detailsBottom = width * 0.055;
              final nameSize = _scaled(width, 0.05, 20, 27);
              final numberSize = _scaled(width, 0.034, 15, 19);
              final balanceSize = _scaled(width, 0.061, 22, 33);
              final metadataTitleSize = _scaled(width, 0.037, 15, 20);
              final metadataValueSize = _scaled(width, 0.032, 13, 17);

              return ColoredBox(
                color: GpTokens.cardCanvas,
                child: Column(
                  children: [
                    SizedBox(
                      height: headerHeight,
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          Image.asset(
                            GeekPayAssets.cardTop,
                            gaplessPlayback: true,
                            key: const Key('payment-card-top-art'),
                            fit: BoxFit.fill,
                            filterQuality: FilterQuality.high,
                          ),
                          Positioned(
                            right: width * 0.043,
                            top: 0,
                            bottom: 0,
                            child: Center(
                              child: Transform.translate(
                                key: const Key(
                                  'payment-online-status-indicator',
                                ),
                                offset: Offset(0, statusSize * 0.045),
                                child: Semantics(
                                  button: true,
                                  label: l10n.t('onlineStatus'),
                                  child: GestureDetector(
                                    onTap: onShowStatus,
                                    behavior: HitTestBehavior.opaque,
                                    child: SizedBox.square(
                                      dimension: statusSize,
                                      child: payment.connectionState ==
                                              PaymentConnectionState.unknown
                                          ? const CupertinoActivityIndicator(
                                              color: Colors.white,
                                            )
                                          : Image.asset(
                                              switch (payment.connectionState) {
                                                PaymentConnectionState.online =>
                                                  GeekPayAssets.online,
                                                PaymentConnectionState
                                                      .disconnected =>
                                                  GeekPayAssets.offline,
                                                PaymentConnectionState
                                                      .apiError =>
                                                  GeekPayAssets.warningOnline,
                                                PaymentConnectionState
                                                      .unknown =>
                                                  GeekPayAssets.online,
                                              },
                                              width: statusSize,
                                              height: statusSize,
                                              filterQuality: FilterQuality.high,
                                              gaplessPlayback: true,
                                            ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    Expanded(
                      child: Stack(
                        children: [
                          Positioned(
                            left: 0,
                            right: 0,
                            bottom: 0,
                            height: width * 337 / 744,
                            child: Image.asset(
                              GeekPayAssets.cardBottom,
                              gaplessPlayback: true,
                              key: const Key('payment-card-bottom-art'),
                              fit: BoxFit.contain,
                              alignment: Alignment.bottomCenter,
                              filterQuality: FilterQuality.high,
                            ),
                          ),
                          Positioned(
                            top: qrTop,
                            left: (width - qrSize) / 2,
                            width: qrSize,
                            height: qrSize,
                            child: RepaintBoundary(
                              child: AnimatedSwitcher(
                                duration: reduceMotion || !active
                                    ? Duration.zero
                                    : const Duration(milliseconds: 320),
                                switchInCurve: Curves.easeOutCubic,
                                switchOutCurve: Curves.easeInCubic,
                                child: succeeded
                                    ? _PaymentSuccess(
                                        key: const ValueKey('success'),
                                        result: result,
                                        reduceMotion: reduceMotion,
                                        onRefresh: onRefreshOnline,
                                      )
                                    : loading
                                        ? const _PaymentCodeActivityIndicator(
                                            key: ValueKey(
                                              'payment-code-refresh-spinner',
                                            ),
                                            radius: 15,
                                          )
                                        : payment.phase ==
                                                PaymentCodePhase
                                                    .activationRequired
                                            ? _ActivationRequired(
                                                key: const ValueKey('activate'),
                                                onActivate: onActivateOnline,
                                              )
                                            : payment.phase ==
                                                        PaymentCodePhase
                                                            .failed &&
                                                    !offline
                                                ? _CodeFailure(
                                                    key: const ValueKey(
                                                      'failed',
                                                    ),
                                                    message: payment.message,
                                                    onRetry: onRefreshOnline,
                                                  )
                                                : payload == null
                                                    ? const _PaymentCodeActivityIndicator(
                                                        key: ValueKey(
                                                          'payment-code-pending-spinner',
                                                        ),
                                                      )
                                                    : _QrCode(
                                                        key: ValueKey(
                                                          offline
                                                              ? payload
                                                              : payment
                                                                  .generation,
                                                        ),
                                                        payload: payload,
                                                        binaryPayload:
                                                            offline ||
                                                                (payment.frame
                                                                        ?.rawQrCode
                                                                        .startsWith(
                                                                      '5638',
                                                                    ) ??
                                                                    false),
                                                        size: qrSize,
                                                        onTap: offline
                                                            ? onRefreshOffline
                                                            : onRefreshOnline,
                                                      ),
                              ),
                            ),
                          ),
                          if (!succeeded && showCodeMetadata)
                            Positioned(
                              top: metadataTop,
                              left: horizontalPadding,
                              right: horizontalPadding,
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    offline
                                        ? l10n.t('offlineCode')
                                        : l10n.t('onlineCode'),
                                    style: TextStyle(
                                      color: GpTokens.campusRed,
                                      fontSize: metadataTitleSize,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  if (!offline || offlineRemaining != null) ...[
                                    SizedBox(height: width * 0.004),
                                    if (offline)
                                      Text(
                                        '${l10n.t('remainingUses')}: $offlineRemaining',
                                        style: TextStyle(
                                          color: GpTokens.campusRed
                                              .withValues(alpha: 0.62),
                                          fontSize: metadataValueSize,
                                        ),
                                      )
                                    else
                                      _CodeCountdown(
                                        generation: payment.generation,
                                        active: active,
                                        style: TextStyle(
                                          color: GpTokens.campusRed
                                              .withValues(alpha: 0.62),
                                          fontSize: metadataValueSize,
                                        ),
                                      ),
                                  ],
                                ],
                              ),
                            ),
                          Positioned(
                            left: horizontalPadding,
                            right: horizontalPadding,
                            bottom: detailsBottom,
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: [
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        ownerName,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          color: const Color(0xFF303034),
                                          fontSize: nameSize,
                                          fontWeight: FontWeight.w600,
                                          height: 1.1,
                                        ),
                                      ),
                                      SizedBox(height: width * 0.006),
                                      Text(
                                        l10n.cardNumber(card.id),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          color: const Color(0xFF303034),
                                          fontSize: numberSize,
                                          fontFeatures: const [
                                            FontFeature.tabularFigures(),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                SizedBox(width: width * 0.025),
                                Text(
                                  card.detailsAvailable
                                      ? formatMoneyFen(
                                          card.balance.value,
                                        )
                                      : '--',
                                  maxLines: 1,
                                  style: TextStyle(
                                    color: const Color(0xFF303034),
                                    fontSize: balanceSize,
                                    fontWeight: FontWeight.w700,
                                    fontFeatures: const [
                                      FontFeature.tabularFigures(),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

final class _CodeCountdown extends StatefulWidget {
  const _CodeCountdown({
    required this.generation,
    required this.active,
    required this.style,
  });
  final int generation;
  final bool active;
  final TextStyle style;

  @override
  State<_CodeCountdown> createState() => _CodeCountdownState();
}

class _CodeCountdownState extends State<_CodeCountdown> {
  Timer? _timer;
  int _remaining = 30;

  @override
  void initState() {
    super.initState();
    _startTimer();
  }

  @override
  void didUpdateWidget(_CodeCountdown oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.generation != widget.generation) {
      _remaining = 30;
      _startTimer();
    } else if (oldWidget.active != widget.active) {
      _startTimer();
    }
  }

  void _startTimer() {
    _timer?.cancel();
    if (!widget.active || _remaining <= 1) return;
    final initial = _remaining;
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      final next = (initial - timer.tick).clamp(1, 30);
      setState(() => _remaining = next);
      if (_remaining == 1) timer.cancel();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SizedBox(
        width: double.infinity,
        child: RepaintBoundary(
          child: Text(
            context.l10n.refreshIn(_remaining),
            textAlign: TextAlign.center,
            style: widget.style,
          ),
        ),
      );
}

double _scaled(double width, double ratio, double minimum, double maximum) =>
    (width * ratio).clamp(minimum, maximum).toDouble();

final class _QrCode extends StatefulWidget {
  const _QrCode({
    super.key,
    required this.payload,
    required this.binaryPayload,
    required this.size,
    required this.onTap,
  });

  final String payload;
  final bool binaryPayload;
  final double size;
  final VoidCallback onTap;

  @override
  State<_QrCode> createState() => _QrCodeState();
}

class _QrCodeState extends State<_QrCode> {
  late Widget _image;

  @override
  void initState() {
    super.initState();
    _image = _createImage();
  }

  @override
  void didUpdateWidget(_QrCode oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.payload != widget.payload ||
        oldWidget.binaryPayload != widget.binaryPayload) {
      _image = _createImage();
    }
  }

  Widget _createImage() => widget.binaryPayload
      ? QrImageView.withQr(
          qr: QrCode.fromUint8List(
            data: Uint8List.fromList(latin1.encode(widget.payload)),
            errorCorrectLevel: QrErrorCorrectLevel.L,
          ),
          padding: EdgeInsets.zero,
          eyeStyle: const QrEyeStyle(
            eyeShape: QrEyeShape.square,
            color: GpTokens.campusRed,
          ),
          dataModuleStyle: const QrDataModuleStyle(
            dataModuleShape: QrDataModuleShape.square,
            color: GpTokens.campusRed,
          ),
          backgroundColor: GpTokens.cardCanvas,
        )
      : QrImageView(
          data: widget.payload,
          version: QrVersions.auto,
          padding: EdgeInsets.zero,
          eyeStyle: const QrEyeStyle(
            eyeShape: QrEyeShape.square,
            color: GpTokens.campusRed,
          ),
          dataModuleStyle: const QrDataModuleStyle(
            dataModuleShape: QrDataModuleShape.square,
            color: GpTokens.campusRed,
          ),
          backgroundColor: GpTokens.cardCanvas,
        );

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: context.l10n.t('touchToRefresh'),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          key: const Key('payment-code-qr'),
          width: widget.size,
          height: widget.size,
          color: GpTokens.cardCanvas,
          padding: EdgeInsets.all(widget.size * 0.035),
          child: _image,
        ),
      ),
    );
  }
}

final class _PaymentSuccess extends ConsumerWidget {
  const _PaymentSuccess({
    super.key,
    required this.result,
    required this.reduceMotion,
    required this.onRefresh,
  });

  final TransactionResult? result;
  final bool reduceMotion;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Semantics(
      button: true,
      label: context.l10n.t('touchToRefresh'),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onRefresh,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AnimatedSuccessCheck(
              size: 88,
              color: GpTokens.campusRed,
              reduceMotion: reduceMotion,
              feedback: ref.read(appRuntimeProvider).feedback,
            ),
            const SizedBox(height: 16),
            Text(
              result == null
                  ? context.l10n.t('paymentSucceeded')
                  : formatMoneyFen(result!.amount.value),
              style: const TextStyle(
                color: GpTokens.campusRed,
                fontSize: 35,
                fontWeight: FontWeight.w600,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
            const SizedBox(height: 3),
            Text(
              result?.merchantName?.trim().isNotEmpty == true
                  ? result!.merchantName!
                  : context.l10n.t('paymentSucceeded'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: GpTokens.campusRed.withValues(alpha: 0.62),
                fontSize: 14,
              ),
            ),
            if (result != null) ...[
              const SizedBox(height: 3),
              Text(
                context.l10n.fullDateTime(
                  result!.tradeAt ?? result!.confirmedLocallyAt,
                ),
                style: TextStyle(
                  color: GpTokens.campusRed.withValues(alpha: 0.62),
                  fontSize: 13,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

final class _ActivationRequired extends StatelessWidget {
  const _ActivationRequired({super.key, required this.onActivate});

  final VoidCallback onActivate;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          GpPlatformIcons.paymentCode(context),
          size: 68,
          color: context.gpColors.action,
        ),
        const SizedBox(height: 16),
        Text(context.l10n.t('activationRequired')),
        const SizedBox(height: 14),
        FilledButton(
          onPressed: onActivate,
          style: FilledButton.styleFrom(
            backgroundColor: context.gpColors.action,
            shape: const StadiumBorder(),
          ),
          child: Text(context.l10n.t('activate')),
        ),
      ],
    );
  }
}

final class _CodeFailure extends StatelessWidget {
  const _CodeFailure({super.key, this.message, required this.onRetry});

  final String? message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(message ?? context.l10n.t('paymentCodeFailed')),
        const SizedBox(height: 8),
        TextButton(onPressed: onRetry, child: Text(context.l10n.t('retry'))),
      ],
    );
  }
}
