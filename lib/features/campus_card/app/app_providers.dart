import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../application/payment_code_controller.dart';
import '../application/scan_payment_controller.dart';
import '../core/config/debug_mode_controller.dart';
import '../core/config/debug_mode_features.dart';
import '../core/config/offline_authorization_banner_controller.dart';
import '../core/config/payment_code_preferences.dart';
import '../data/mock/debug_transactions.dart';
import '../domain/models/auth_models.dart';
import '../domain/models/bill_models.dart';
import '../domain/models/card_models.dart';
import '../domain/models/offline_models.dart';
import '../domain/models/payment_models.dart';
import '../domain/models/profile_models.dart';
import '../domain/models/scan_models.dart';
import '../domain/models/security_models.dart';
import '../domain/money_fen.dart';
import '../domain/ports/auth_port.dart';
import '../domain/ports/bill_ports.dart';
import '../domain/ports/card_ports.dart';
import '../domain/ports/platform_ports.dart';
import 'app_runtime.dart';

final appRuntimeProvider = Provider<AppRuntime>(
  (ref) =>
      throw StateError('AppRuntime must be overridden at the application root'),
);

/// Supplied by TechPie so the campus-card root can return through the host
/// navigator without coupling its internal router to the app shell.
final geekPayHostExitProvider = Provider<VoidCallback?>((ref) => null);

/// Opens TechPie's Account settings for the campus-card OpenID.
final campusCardAccountProvider = Provider<VoidCallback?>((ref) => null);

final homeWidgetPortProvider = Provider<HomeWidgetPort?>((ref) => null);

enum CampusCardEntry { paymentCode, cardManagement }

final campusCardEntryProvider = Provider<CampusCardEntry>(
  (ref) => CampusCardEntry.paymentCode,
);

final authControllerProvider =
    AsyncNotifierProvider<AuthController, AuthSnapshot>(AuthController.new);

final class AuthController extends AsyncNotifier<AuthSnapshot> {
  Future<void>? _backgroundRestore;

  @override
  Future<AuthSnapshot> build() async {
    final runtime = ref.watch(appRuntimeProvider);
    final auth = runtime.auth;
    final initial =
        await auth.restoreLocal().timeout(const Duration(seconds: 10));
    final subscription = auth.changes.listen((snapshot) {
      if (snapshot.state == AuthState.signingIn) return;
      final previous = state.valueOrNull;
      state = AsyncData(snapshot);
      if (previous != null &&
          previous.session?.subjectId != snapshot.session?.subjectId) {
        _invalidateAccountProviders();
      }
    });
    final connectivitySubscription = runtime.connectivity.changes.listen((
      online,
    ) {
      if (online && state.valueOrNull?.state == AuthState.authenticated) {
        unawaited(_startBackgroundRestore(auth));
      }
    });
    ref.onDispose(() {
      unawaited(subscription.cancel());
      unawaited(connectivitySubscription.cancel());
    });
    if (initial.state == AuthState.authenticated) {
      Future<void>.delayed(Duration.zero, () => _startBackgroundRestore(auth));
    }
    return initial;
  }

  Future<void> refreshFromServer() =>
      _startBackgroundRestore(ref.read(appRuntimeProvider).auth);

  Future<void> _startBackgroundRestore(AuthPort auth) {
    final active = _backgroundRestore;
    if (active != null) return active;
    late final Future<void> operation;
    operation = _refreshStoredSession(auth).whenComplete(() {
      if (identical(_backgroundRestore, operation)) _backgroundRestore = null;
    });
    _backgroundRestore = operation;
    return operation;
  }

  Future<void> _refreshStoredSession(AuthPort auth) async {
    try {
      final refreshed = await auth.restore();
      state = AsyncData(refreshed);
    } catch (_) {
      // The locally verified identity and offline code remain available.
    }
  }

  Future<void> signIn(AuthCredential credential) async {
    state = const AsyncLoading();
    final result = await AsyncValue.guard(
      () => ref.read(appRuntimeProvider).auth.signIn(credential),
    );
    if (!result.hasError) _invalidateAccountProviders();
    state = result;
    _throwAsyncError(result);
  }

  Future<void> signOut() async {
    state = const AsyncLoading();
    final auth = ref.read(appRuntimeProvider).auth;
    final result = await AsyncValue.guard(() async {
      await auth.signOut();
      await ref
          .read(offlineAuthorizationBannerDismissedProvider.notifier)
          .reset();
      _invalidateAccountProviders();
      return auth.restoreLocal();
    });
    state = result;
    _throwAsyncError(result);
  }

  void _invalidateAccountProviders() {
    ref.invalidate(cardControllerProvider);
    ref.invalidate(profileControllerProvider);
    ref.invalidate(transactionDetailProvider);
    ref.invalidate(transactionFeedProvider);
    ref.invalidate(offlineAuthorizationProvider);
    ref.invalidate(manualOfflineModeProvider);
    ref.invalidate(paymentCodeControllerProvider);
    ref.invalidate(scanPaymentControllerProvider);
    ref.invalidate(spendingPasswordInitializationProvider);
    ref.invalidate(spendingLimitsControllerProvider);
  }
}

final cardControllerProvider =
    AsyncNotifierProvider<CardController, CampusCard?>(CardController.new);

final class CardController extends AsyncNotifier<CampusCard?> {
  int _generation = 0;

  @override
  Future<CampusCard?> build() {
    final generation = ++_generation;
    ref.onDispose(() => _generation++);
    return _loadCard(ref.watch(appRuntimeProvider), generation);
  }

  Future<CampusCard?> _loadCard(
    AppRuntime runtime,
    int generation,
  ) async {
    final repository = runtime.cards;
    final CampusCard? card;
    if (repository is CacheFirstCardRepository) {
      final cached = await repository.readCachedCard();
      if (cached != null) {
        card = cached;
        unawaited(
          _refreshCachedCard(repository, generation),
        );
      } else {
        OfflineAuthorization? authorization;
        try {
          authorization =
              await runtime.offlinePayments.mostRecentAuthorization();
        } catch (_) {
          // A damaged historical grant cannot block an online card refresh.
        }
        if (authorization != null) {
          card = _offlineFallbackCard(authorization.cardId);
          unawaited(_refreshCachedCard(repository, generation));
        } else {
          card = await repository.refreshCard();
        }
      }
    } else {
      card = await repository.currentCard();
    }
    if (card == null) return null;
    if (generation == _generation) {
      unawaited(_maintainOfflineAuthorization(runtime, card));
    }
    return card;
  }

  Future<void> _refreshCachedCard(
    CacheFirstCardRepository repository,
    int generation,
  ) async {
    try {
      final refreshed = await repository.refreshCard();
      if (generation == _generation && refreshed != null) {
        state = AsyncData(refreshed);
      }
    } catch (_) {
      // Cached card data remains usable when its background refresh fails.
    }
  }

  Future<void> _maintainOfflineAuthorization(
    AppRuntime runtime,
    CampusCard card,
  ) async {
    try {
      final current = await runtime.offlinePayments.status(card.id);
      if (current.authorization != null) {
        await runtime.offlinePayments.renew(card.id, force: true);
      }
    } catch (_) {
      // A failed renewal must not replace a usable local authorization.
    }
  }

  CampusCard _offlineFallbackCard(String cardId) {
    final tail =
        cardId.length <= 4 ? cardId : cardId.substring(cardId.length - 4);
    return CampusCard(
      id: cardId,
      maskedNumber: '••••$tail',
      ownerName: '',
      balance: MoneyFen.zero,
      status: CampusCardStatus.normal,
      positionName: '',
      offlineCodeAllowed: true,
      detailsAvailable: false,
    );
  }

  Future<BindCardResult?> bind(BindCardCommand command) async {
    final generation = _generation;
    final repository = ref.read(appRuntimeProvider).cards;
    state = const AsyncLoading();
    BindCardResult? result;
    final next = await AsyncValue.guard(() async {
      result = await repository.bind(command);
      return repository.currentCard();
    });
    if (generation != _generation) return null;
    state = next;
    _throwAsyncError(state);
    return result;
  }

  Future<void> unbind(String cardPassword) async {
    final generation = _generation;
    final repository = ref.read(appRuntimeProvider).cards;
    state = const AsyncLoading();
    final next = await AsyncValue.guard<CampusCard?>(() async {
      await repository.unbind(cardPassword: cardPassword);
      return null;
    });
    if (generation != _generation) return;
    state = next;
    _throwAsyncError(state);
  }

  Future<void> refresh() async {
    final generation = _generation;
    final previous = state.valueOrNull;
    final runtime = ref.read(appRuntimeProvider);
    final repository = runtime.cards;
    final result = await AsyncValue.guard(
      () => repository is CacheFirstCardRepository
          ? repository.refreshCard()
          : repository.currentCard(),
    );
    if (generation != _generation) return;
    if (result.hasError && previous != null) {
      state = AsyncData(previous);
      _throwAsyncError(result);
    }
    state = result;
    _throwAsyncError(result);
  }
}

final profileControllerProvider =
    AsyncNotifierProvider<ProfileController, UserProfile>(
  ProfileController.new,
);

final class ProfileController extends AsyncNotifier<UserProfile> {
  int _generation = 0;

  @override
  Future<UserProfile> build() {
    _generation++;
    ref.onDispose(() => _generation++);
    return ref.watch(appRuntimeProvider).cards.profile();
  }

  Future<void> refresh() async {
    final generation = _generation;
    state = const AsyncLoading();
    final next =
        await AsyncValue.guard(ref.read(appRuntimeProvider).cards.profile);
    if (generation != _generation) return;
    state = next;
    _throwAsyncError(state);
  }
}

final transactionDetailProvider =
    FutureProvider.family<TransactionRecord, String>((ref, id) {
  if (debugModeFeaturesAvailable && ref.watch(debugModeProvider)) {
    for (final record in debugTransactionRecords(DateTime.now())) {
      if (record.id == id) return record;
    }
  }
  return ref.watch(appRuntimeProvider).transactions.detail(id);
});

typedef TransactionDateRange = ({DateTime? begin, DateTime? end});

final transactionFeedProvider = AsyncNotifierProvider.family<
    TransactionFeedController, TransactionPage, TransactionDateRange>(
  TransactionFeedController.new,
);

final class TransactionFeedController
    extends FamilyAsyncNotifier<TransactionPage, TransactionDateRange> {
  bool _loadingMore = false;
  int _generation = 0;
  @override
  Future<TransactionPage> build(TransactionDateRange arg) async {
    _generation++;
    _loadingMore = false;
    ref.onDispose(() => _generation++);
    final range = arg;
    final debug = debugModeFeaturesAvailable && ref.watch(debugModeProvider);
    final port = ref.watch(appRuntimeProvider).transactions;
    if (port is! DateRangeTransactionHistoryPort) {
      throw UnsupportedError('Date range transaction history is unavailable');
    }
    final datePort = port as DateRangeTransactionHistoryPort;
    final page = await datePort.timelineRange(
      begin: range.begin,
      end: range.end,
    );
    if (!debug) return page;
    return _withDebugTransactions(page);
  }

  Future<void> loadMore() async {
    final generation = _generation;
    final current = state.valueOrNull;
    if (current == null || !current.hasMore || _loadingMore) return;
    _loadingMore = true;
    final port = ref.read(appRuntimeProvider).transactions;
    if (port is! DateRangeTransactionHistoryPort) {
      _loadingMore = false;
      return;
    }
    try {
      final next =
          await (port as DateRangeTransactionHistoryPort).timelineRange(
        begin: arg.begin,
        end: arg.end,
        cursor: current.nextCursor,
      );
      if (generation != _generation) return;
      final seen = current.items.map((record) => record.id).toSet();
      final debugItems = current.items
          .where((record) => record.id.startsWith('DEBUG-'))
          .toList();
      final currentRealItems = current.items
          .where((record) => !record.id.startsWith('DEBUG-'))
          .toList();
      final cursorAdvanced =
          next.nextCursor != null && next.nextCursor != current.nextCursor;
      state = AsyncData(
        TransactionPage(
          items: [
            ...currentRealItems,
            for (final record in next.items)
              if (seen.add(record.id)) record,
            ...debugItems,
          ],
          hasMore: next.hasMore && cursorAdvanced,
          nextCursor: cursorAdvanced ? next.nextCursor : null,
        ),
      );
    } catch (error, stackTrace) {
      if (generation == _generation) state = AsyncError(error, stackTrace);
    } finally {
      if (generation == _generation) _loadingMore = false;
    }
  }
}

TransactionPage _withDebugTransactions(TransactionPage page) => TransactionPage(
      items: [...page.items, ...debugTransactionRecords(DateTime.now())],
      hasMore: page.hasMore,
      nextCursor: page.nextCursor,
    );

final manualOfflineModeProvider =
    NotifierProvider<ManualOfflineModeController, bool>(
  ManualOfflineModeController.new,
);

final class ManualOfflineModeController extends Notifier<bool> {
  @override
  bool build() => false;

  void setEnabled(bool enabled) => state = enabled;
}

final offlineAuthorizationProvider = AsyncNotifierProvider.family<
    OfflineAuthorizationController, OfflineAuthorizationView, String>(
  OfflineAuthorizationController.new,
);

final class OfflineAuthorizationController
    extends FamilyAsyncNotifier<OfflineAuthorizationView, String> {
  static const _automaticRetryDelay = Duration(minutes: 15);
  Timer? _renewalTimer;

  @override
  Future<OfflineAuthorizationView> build(String arg) async {
    final cardId = arg;
    ref.onDispose(() => _renewalTimer?.cancel());
    final service = ref.watch(appRuntimeProvider).offlinePayments;
    var view = await service.status(cardId);
    if (_shouldRenewAutomatically(view)) {
      try {
        await service.renew(cardId, force: true);
        view = await service.status(cardId);
      } catch (_) {
        // Automatic maintenance is best effort and must not replace a usable
        // local authorization with an error screen.
      }
    }
    _scheduleAutomaticRenewal(view);
    return view;
  }

  Future<OfflineQrCode> generate() async {
    final code =
        await ref.read(appRuntimeProvider).offlinePayments.generate(arg);
    state = AsyncData(
      await ref.read(appRuntimeProvider).offlinePayments.status(arg),
    );
    return code;
  }

  Future<void> activate() async {
    final previous = state.valueOrNull ??
        const OfflineAuthorizationView(
          state: OfflineAuthorizationState.missingCredential,
        );
    state = const AsyncLoading();
    final result = await AsyncValue.guard(() async {
      await ref.read(appRuntimeProvider).offlinePayments.activate(cardId: arg);
      return ref.read(appRuntimeProvider).offlinePayments.status(arg);
    });
    if (result.hasError) {
      state = AsyncData(previous);
      _throwAsyncError(result);
    }
    state = result;
    final view = result.valueOrNull;
    if (view != null) _scheduleAutomaticRenewal(view);
  }

  Future<void> renew({bool force = true}) async {
    final previous = state.valueOrNull;
    state = const AsyncLoading();
    final result = await AsyncValue.guard(() async {
      await ref
          .read(appRuntimeProvider)
          .offlinePayments
          .renew(arg, force: force);
      return ref.read(appRuntimeProvider).offlinePayments.status(arg);
    });
    if (result.hasError) {
      state = previous == null ? result : AsyncData(previous);
      _throwAsyncError(result);
    }
    state = result;
    final view = result.valueOrNull;
    if (view != null) _scheduleAutomaticRenewal(view);
  }

  Future<void> maintain({bool force = true}) async {
    final service = ref.read(appRuntimeProvider).offlinePayments;
    try {
      await service.renew(arg, force: force);
      final view = await service.status(arg);
      state = AsyncData(view);
      _scheduleAutomaticRenewal(view);
    } catch (_) {
      try {
        final view = await service.status(arg);
        state = AsyncData(view);
        _scheduleAutomaticRenewal(view, retrySoon: true);
      } catch (_) {
        _renewalTimer?.cancel();
        _renewalTimer = Timer(
          _automaticRetryDelay,
          () => unawaited(maintain(force: true)),
        );
      }
    }
  }

  Future<void> removeFromDevice() async {
    _renewalTimer?.cancel();
    await ref
        .read(appRuntimeProvider)
        .offlinePayments
        .removeFromThisDevice(arg);
    await ref
        .read(offlineAuthorizationBannerDismissedProvider.notifier)
        .reset();
    state = const AsyncData(
      OfflineAuthorizationView(
        state: OfflineAuthorizationState.missingCredential,
      ),
    );
  }

  bool _shouldRenewAutomatically(OfflineAuthorizationView view) =>
      view.authorization != null &&
      (view.state == OfflineAuthorizationState.renewalDue ||
          view.state == OfflineAuthorizationState.expired);

  void _scheduleAutomaticRenewal(
    OfflineAuthorizationView view, {
    bool retrySoon = false,
  }) {
    _renewalTimer?.cancel();
    final authorization = view.authorization;
    if (authorization == null) return;
    final expiresOn = authorization.expiresOn;
    var delay = _automaticRetryDelay;
    if (!retrySoon &&
        expiresOn != null &&
        view.state == OfflineAuthorizationState.active) {
      final renewalAt = DateTime.utc(
        expiresOn.year,
        expiresOn.month,
        expiresOn.day,
      ).subtract(const Duration(days: 4));
      final untilRenewal = renewalAt.difference(DateTime.now().toUtc());
      if (untilRenewal > Duration.zero) delay = untilRenewal;
    }
    _renewalTimer = Timer(delay, () => unawaited(maintain(force: true)));
  }
}

final paymentCodeControllerProvider =
    NotifierProvider.autoDispose<PaymentCodeNotifier, PaymentCodeViewState>(
  PaymentCodeNotifier.new,
);

final class PaymentCodeNotifier
    extends AutoDisposeNotifier<PaymentCodeViewState> {
  late PaymentCodeExperienceController _controller;

  @override
  PaymentCodeViewState build() {
    final controller =
        ref.watch(appRuntimeProvider).createPaymentCodeController();
    final subscription = controller.states.listen((value) => state = value);
    _controller = controller;
    ref.listen(
      maximizePaymentCodeBrightnessProvider,
      (_, next) {
        unawaited(controller.setMaximizeBrightness(next.valueOrNull ?? false));
      },
      fireImmediately: true,
    );
    ref.onDispose(() {
      unawaited(subscription.cancel());
      unawaited(controller.dispose());
    });
    return controller.state;
  }

  Future<void> enter({bool online = true}) =>
      _guardPaymentAction(() => _controller.enter(online: online));
  Future<void> restart() => _guardPaymentAction(_controller.restart);
  Future<void> activateAndRestart() =>
      _guardPaymentAction(_controller.activateAndRestart);
  Future<void> leave() => _guardPaymentAction(_controller.leave);

  void debugComplete() {
    if (!debugModeFeaturesAvailable || !ref.read(debugModeProvider)) return;
    _controller.debugComplete();
  }

  void markDisconnected() => _controller.markDisconnected();

  Future<void> _guardPaymentAction(Future<void> Function() action) async {
    try {
      await action();
    } catch (_) {
      state = state.copyWith(
        phase: PaymentCodePhase.failed,
        message: '付款码加载失败，请重试。',
        connectionState: PaymentConnectionState.apiError,
      );
    }
  }
}

final scanPaymentControllerProvider =
    NotifierProvider.autoDispose<ScanPaymentNotifier, ScanFlowState>(
  ScanPaymentNotifier.new,
);

final class ScanPaymentNotifier extends AutoDisposeNotifier<ScanFlowState> {
  late ScanPaymentController _controller;

  @override
  ScanFlowState build() {
    final controller =
        ref.watch(appRuntimeProvider).createScanPaymentController();
    final subscription = controller.states.listen((value) => state = value);
    _controller = controller;
    ref.onDispose(() {
      unawaited(subscription.cancel());
      unawaited(controller.dispose());
    });
    return controller.state;
  }

  Future<void> submitCode(String code) =>
      debugModeFeaturesAvailable && ref.read(debugModeProvider)
          ? _controller.debugSubmitCode(code)
          : _controller.submitCode(code);
  Future<void> submitPassword(String password) =>
      debugModeFeaturesAvailable && ref.read(debugModeProvider)
          ? _controller.debugSubmitPassword(password)
          : _controller.submitPassword(password);
  void reset() => _controller.reset();
}

final spendingPasswordInitializationProvider =
    FutureProvider<SpendingPasswordInitialization>(
  (ref) =>
      ref.watch(appRuntimeProvider).securitySettings.initializePasswordChange(),
);

final spendingLimitsControllerProvider =
    AsyncNotifierProvider.autoDispose<SpendingLimitsController, SpendingLimits>(
  SpendingLimitsController.new,
);

final class SpendingLimitsController
    extends AutoDisposeAsyncNotifier<SpendingLimits> {
  @override
  Future<SpendingLimits> build() =>
      ref.watch(appRuntimeProvider).securitySettings.readLimits();

  Future<void> saveCardLimits(SpendingLimits limits) async {
    final previous = state.valueOrNull;
    if (previous == null) return;
    state = const AsyncLoading();
    final result = await AsyncValue.guard(() async {
      await ref
          .read(appRuntimeProvider)
          .securitySettings
          .updateCardLimits(limits);
      return ref.read(appRuntimeProvider).securitySettings.readLimits();
    });
    if (result.hasError) {
      state = AsyncData(previous);
      _throwAsyncError(result);
    }
    state = result;
  }

  Future<void> saveQrLimits(
    SpendingLimits limits, {
    required String transactionPassword,
  }) async {
    final previous = state.valueOrNull;
    if (previous == null) return;
    state = const AsyncLoading();
    final result = await AsyncValue.guard(() async {
      await ref
          .read(appRuntimeProvider)
          .securitySettings
          .updateQrLimits(limits, transactionPassword: transactionPassword);
      return ref.read(appRuntimeProvider).securitySettings.readLimits();
    });
    if (result.hasError) {
      state = AsyncData(previous);
      _throwAsyncError(result);
    }
    state = result;
  }

  Future<void> changePassword({
    required String accountKey,
    required String oldPassword,
    required String newPassword,
  }) =>
      ref.read(appRuntimeProvider).securitySettings.changeSpendingPassword(
            accountKey: accountKey,
            oldPassword: oldPassword,
            newPassword: newPassword,
          );
}

void _throwAsyncError(AsyncValue<Object?> value) {
  if (!value.hasError) return;
  Error.throwWithStackTrace(value.error!, value.stackTrace!);
}
