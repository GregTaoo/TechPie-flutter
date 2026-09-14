import 'dart:async';
import 'dart:math';
import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:techpie/features/campus_card/app/app_providers.dart';
import 'package:techpie/features/campus_card/app/app_runtime.dart';
import 'package:techpie/features/campus_card/app/demo_runtime_factory.dart';
import 'package:techpie/features/campus_card/application/offline_payment_service.dart';
import 'package:techpie/features/campus_card/core/errors/app_failure.dart';
import 'package:techpie/features/campus_card/data/crypto/sm2_offline_crypto.dart';
import 'package:techpie/features/campus_card/data/mock/in_memory_ports.dart';
import 'package:techpie/features/campus_card/data/storage/secure_offline_credential_repository.dart';
import 'package:techpie/features/campus_card/domain/models/card_models.dart';
import 'package:techpie/features/campus_card/domain/models/offline_models.dart';
import 'package:techpie/features/campus_card/domain/models/payment_models.dart';
import 'package:techpie/features/campus_card/domain/money_fen.dart';
import 'package:techpie/features/campus_card/domain/ports/card_ports.dart';
import 'package:techpie/features/campus_card/domain/ports/offline_ports.dart';
import 'package:techpie/features/campus_card/domain/ports/payment_ports.dart';
import 'package:techpie/features/campus_card/presentation/screens/payment_code_page.dart';
import 'package:techpie/features/campus_card/presentation/widgets/apple_wallet_components.dart';

final _now = DateTime.utc(2026, 9, 14, 12);

void main() {
  testWidgets('online failure preserves local generation already in flight', (tester) async {
    final h = await _Harness.create();
    h.credentials.gate = Completer<void>();
    await h.mount(tester);
    expect(h.credentials.reservations, 1);
    h.online.pending.completeError(const AppFailure(FailureKind.network, 'offline'));
    await _pump(tester);
    h.credentials.gate!.complete();
    await _pump(tester);
    expect(find.text('离线付款码'), findsOneWidget);
    expect(find.byKey(const Key('payment-code-qr')), findsOneWidget);
    expect(h.credentials.reservations, 1);
    await h.close(tester);
  });

  testWidgets('fast manual refresh shows a spinner without an offline-code detour', (tester) async {
    final h = await _Harness.create();
    await h.mount(tester);
    h.online.pending.complete(_frame());
    await _pump(tester);
    final reservations = h.credentials.reservations;
    h.online.retry = Completer<PaymentCodeFrame>();
    await tester.tap(find.byKey(const Key('payment-code-qr')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const ValueKey('payment-code-refresh-spinner')), findsOneWidget);
    expect(find.byKey(const Key('payment-code-qr')), findsNothing);
    expect(h.credentials.reservations, reservations);
    h.online.retry!.complete(_frame());
    await _pump(tester);
    await tester.pump(const Duration(seconds: 2));
    expect(find.text('在线付款码'), findsOneWidget);
    expect(h.credentials.reservations, reservations);
    expect(h.online.calls, 2);
    await h.close(tester);
  });

  for (final grant in ['valid', 'missing']) {
    testWidgets('manual refresh degrades after 1.5 seconds (grant=$grant)', (tester) async {
      final h = await _Harness.create(grantState: grant);
      await h.mount(tester);
      h.online.pending.complete(_frame());
      await _pump(tester);
      h.online.retry = Completer<PaymentCodeFrame>();
      await tester.tap(find.byKey(const Key('payment-code-qr')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1400));
      expect(find.byKey(const ValueKey('payment-code-refresh-spinner')), findsOneWidget);
      expect(find.text('离线付款码'), findsNothing);
      await tester.pump(const Duration(milliseconds: 100));
      await _pump(tester);
      final image = tester.widget<Image>(find.descendant(
        of: find.byKey(const Key('payment-online-status-indicator')),
        matching: find.byType(Image),),);
      expect((image.image as AssetImage).assetName, GeekPayAssets.warningOnline);
      if (grant == 'valid') {
        expect(find.text('离线付款码'), findsOneWidget);
        expect(find.byKey(const Key('payment-code-qr')), findsOneWidget);
      } else {
        expect(find.byKey(const Key('payment-code-qr')), findsNothing);
        expect(find.byKey(const ValueKey('payment-code-refresh-spinner')), findsOneWidget);
      }
      expect(h.online.calls, 2);
      h.online.retry!.complete(_frame());
      await _pump(tester);
      expect(find.text('在线付款码'), findsOneWidget);
      final readyImage = tester.widget<Image>(find.descendant(
        of: find.byKey(const Key('payment-online-status-indicator')),
        matching: find.byType(Image),),);
      expect((readyImage.image as AssetImage).assetName, GeekPayAssets.online);
      await h.close(tester);
    });
  }

  testWidgets('pull refresh shares the loading grace and coalesces duplicate pulls', (tester) async {
    final h = await _Harness.create();
    await h.mount(tester);
    h.online.pending.complete(_frame());
    await _pump(tester);
    h.online.retry = Completer<PaymentCodeFrame>();
    final refresh = tester.widget<EcardSliverRefreshControl>(find.byType(EcardSliverRefreshControl, skipOffstage: false)).onRefresh;
    final first = refresh();
    final second = refresh();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const ValueKey('payment-code-refresh-spinner')), findsOneWidget);
    expect(find.text('离线付款码'), findsNothing);
    expect(h.online.calls, 2);
    h.online.retry!.complete(_frame());
    await _pump(tester);
    await Future.wait([first, second]);
    expect(find.text('在线付款码'), findsOneWidget);
    await h.close(tester);
  });

  testWidgets('automatic rotation also waits before showing offline code despite old polling results', (tester) async {
    final h = await _Harness.create();
    await h.mount(tester);
    h.online.pending.complete(_frame());
    await _pump(tester);
    h.online.retry = Completer<PaymentCodeFrame>();
    await tester.pump(const Duration(seconds: 30));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const ValueKey('payment-code-refresh-spinner')), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
    await _pump(tester);
    expect(find.text('离线付款码'), findsOneWidget);
    expect(h.online.calls, 2);
    h.online.retry!.complete(_frame());
    await _pump(tester);
    expect(find.text('在线付款码'), findsOneWidget);
    await h.close(tester);
  });

  testWidgets('leaving the page cancels the refresh fallback timer', (tester) async {
    final h = await _Harness.create();
    await h.mount(tester);
    h.online.pending.complete(_frame());
    await _pump(tester);
    final reservations = h.credentials.reservations;
    h.online.retry = Completer<PaymentCodeFrame>();
    await tester.tap(find.byKey(const Key('payment-code-qr')));
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 2));
    expect(h.credentials.reservations, reservations);
    h.online.retry!.complete(_frame());
    await _pump(tester);
    expect(tester.takeException(), isNull);
    await h.close(tester);
  });

  testWidgets(
      'usable local code is shown while online code and renewal are pending',
      (tester) async {
    final h = await _Harness.create();
    await h.mount(tester);
    expect(h.remote.renewals, 1);
    expect(h.online.calls, 1);
    expect(
      h.container.read(paymentCodeControllerProvider).phase,
      PaymentCodePhase.initializing,
    );
    expect(find.text('离线付款码'), findsOneWidget);
    expect(find.byKey(const Key('payment-code-qr')), findsOneWidget);
    expect(h.credentials.reservations, 1);
    await tester.pump(const Duration(seconds: 5));
    expect(h.credentials.reservations, 1);
    final delayedStatus = tester.widget<Image>(find.descendant(
      of: find.byKey(const Key('payment-online-status-indicator')),
      matching: find.byType(Image),),);
    expect((delayedStatus.image as AssetImage).assetName, GeekPayAssets.warningOnline);
    h.online.pending.complete(_frame());
    await _pump(tester);
    expect(find.text('在线付款码'), findsOneWidget);
    expect(find.text('在线付款码'), findsOneWidget);
    expect(find.byKey(const Key('payment-code-qr')), findsOneWidget);
    expect(
      h.container.read(paymentCodeControllerProvider).frame!.qrPayload,
      'ONLINE-CODE',
    );
    await h.close(tester);
  });

  testWidgets('failed online load keeps the already displayed offline code',
      (tester) async {
    final h = await _Harness.create();
    await h.mount(tester);
    expect(find.text('离线付款码'), findsOneWidget);
    h.online.pending
        .completeError(const AppFailure(FailureKind.network, 'test offline'));
    await _pump(tester);
    expect(find.text('离线付款码'), findsOneWidget);
    expect(find.byKey(const Key('payment-code-qr')), findsOneWidget);
    expect(h.credentials.reservations, 1);
    await h.close(tester);
  });

  for (final failed in [false, true]) {
    testWidgets(
        'late local generation cannot replace ready online code (failure=$failed)',
        (tester) async {
      final h = await _Harness.create();
      h.credentials.gate = Completer<void>();
      await h.mount(tester);
      expect(h.credentials.reservations, 1);
      h.online.pending.complete(_frame());
      await _pump(tester);
      expect(find.text('在线付款码'), findsOneWidget);
      expect(find.byKey(const Key('payment-code-qr')), findsOneWidget);
      expect(
        h.container.read(paymentCodeControllerProvider).frame!.qrPayload,
        'ONLINE-CODE',
      );
      if (failed) {
        h.credentials.gate!.completeError(StateError('local write failed'));
      } else {
        h.credentials.gate!.complete();
      }
      await _pump(tester);
      expect(find.text('在线付款码'), findsOneWidget);
      expect(find.text('在线付款码'), findsOneWidget);
      expect(find.byKey(const Key('payment-code-qr')), findsOneWidget);
      expect(
        h.container.read(paymentCodeControllerProvider).frame!.qrPayload,
        'ONLINE-CODE',
      );
      expect(tester.takeException(), isNull);
      await h.close(tester);
    });
  }

  for (final state in ['missing', 'expired', 'exhausted']) {
    testWidgets('unusable $state grant is never displayed provisionally',
        (tester) async {
      final h = await _Harness.create(grantState: state);
      await h.mount(tester);
      expect(find.byKey(const Key('payment-code-qr')), findsNothing);
      expect(h.credentials.reservations, 0);
      h.online.pending.complete(_frame());
      await _pump(tester);
      expect(find.text('在线付款码'), findsOneWidget);
      expect(find.byKey(const Key('payment-code-qr')), findsOneWidget);
      expect(
        h.container.read(paymentCodeControllerProvider).frame!.qrPayload,
        'ONLINE-CODE',
      );
      await h.close(tester);
    });
  }

  testWidgets('manual offline mode does not start an online request',
      (tester) async {
    final h = await _Harness.create();
    h.container.read(manualOfflineModeProvider.notifier).setEnabled(true);
    await h.mount(tester);
    expect(find.text('离线付款码'), findsOneWidget);
    expect(find.byKey(const Key('payment-code-qr')), findsOneWidget);
    expect(h.online.calls, 0);
    await h.close(tester);
  });

  testWidgets(
      'network recovery keeps the local code until a fresh online code is ready',
      (tester) async {
    final h = await _Harness.create();
    await h.mount(tester);
    h.online.pending
        .completeError(const AppFailure(FailureKind.network, 'test offline'));
    await _pump(tester);
    h.online.retry = Completer<PaymentCodeFrame>();
    final connectivity = h.base.connectivity as InMemoryConnectivityPort;
    connectivity.setOnline(false);
    connectivity.setOnline(true);
    await _pump(tester);
    expect(h.online.calls, 2);
    expect(find.text('离线付款码'), findsOneWidget);
    expect(find.byKey(const Key('payment-code-qr')), findsOneWidget);
    expect(h.credentials.reservations, 1);
    h.online.retry!.complete(_frame());
    await _pump(tester);
    expect(find.text('在线付款码'), findsOneWidget);
    await h.close(tester);
  });

  testWidgets(
      'leaving manual offline mode keeps its code during online loading',
      (tester) async {
    final h = await _Harness.create();
    h.container.read(manualOfflineModeProvider.notifier).setEnabled(true);
    await h.mount(tester);
    await tester.tap(find.bySemanticsLabel('在线状态'));
    await _pump(tester);
    await tester.tap(find.byType(Switch));
    await _pump(tester);
    expect(h.container.read(manualOfflineModeProvider), isFalse);
    expect(h.online.calls, 1);
    expect(find.text('离线付款码'), findsOneWidget);
    expect(find.byKey(const Key('payment-code-qr')), findsOneWidget);
    expect(h.credentials.reservations, 1);
    h.online.pending.complete(_frame());
    await _pump(tester);
    expect(find.text('在线付款码'), findsOneWidget);
    await h.close(tester);
  });

  testWidgets('leaving while local generation is pending has no late UI writes',
      (tester) async {
    final h = await _Harness.create();
    h.credentials.gate = Completer<void>();
    await h.mount(tester);
    expect(h.credentials.reservations, 1);
    await tester.pumpWidget(const SizedBox.shrink());
    h.credentials.gate!.complete();
    h.online.pending.complete(_frame());
    await _pump(tester);
    expect(tester.takeException(), isNull);
    await h.close(tester);
  });
}

Future<void> _pump(WidgetTester tester) async {
  for (var i = 0; i < 15; i++) {
    await tester.pump(const Duration(milliseconds: 30));
  }
}

PaymentCodeFrame _frame() => PaymentCodeFrame(
      payCode: 'ONLINE-CODE',
      rawQrCode: 'ONLINE-CODE',
      qrPayload: 'ONLINE-CODE',
      offlineAllowed: true,
      generatedAt: _now,
    );

class _Harness {
  _Harness(
    this.base,
    this.service,
    this.credentials,
    this.remote,
    this.online,
    this.container,
  );
  final AppRuntime base;
  final OfflinePaymentService service;
  final _Credentials credentials;
  final _Remote remote;
  final _Online online;
  final ProviderContainer container;
  static Future<_Harness> create({String grantState = 'valid'}) async {
    SharedPreferences.setMockInitialValues({});
    final base = await buildDemoRuntime();
    final credentials = _Credentials(
      SecureOfflineCredentialRepository(InMemorySecureCredentialStore()),
    );
    final crypto = Sm2OfflineCrypto(random: Random(13));
    final key = crypto.generateKeyPair();
    if (grantState != 'missing') {
      await credentials.install(
        authorization: OfflineAuthorization(
          cardId: 'card',
          deviceCode: 'device',
          publicKeyCompressed: key.publicKeyCompressed,
          authorInfo: '5638AABBCCDD',
          totalUses: 20,
          used: grantState == 'exhausted' ? 20 : 0,
          updatedAt: _now,
          expiresOn: _now.add(Duration(days: grantState == 'expired' ? -1 : 1)),
        ),
        privateKeyHex: key.privateKeyHex,
      );
    }
    final remote = _Remote();
    final service = OfflinePaymentService(
      credentials: credentials,
      remote: remote,
      connectivity: base.connectivity,
      crypto: crypto,
      deviceCodeReader: () async => 'device',
      clock: Clock.fixed(_now),
    );
    final online = _Online();
    final runtime = AppRuntime(
      environment: base.environment,
      capabilities: base.capabilities,
      auth: base.auth,
      cards: _Card(),
      paymentCodes: online,
      scanPayments: base.scanPayments,
      transactions: base.transactions,
      securitySettings: base.securitySettings,
      offlinePayments: service,
      brightness: base.brightness,
      connectivity: base.connectivity,
      lifecycle: base.lifecycle,
      feedback: base.feedback,
    );
    final container = ProviderContainer(
      overrides: [appRuntimeProvider.overrideWithValue(runtime)],
    );
    return _Harness(base, service, credentials, remote, online, container);
  }

  Future<void> mount(WidgetTester tester) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: PaymentCodePage()),
      ),
    );
    await _pump(tester);
  }

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    container.dispose();
    if (!remote.pending.isCompleted) remote.pending.complete(null);
    if (!online.pending.isCompleted) online.pending.complete(_frame());
    await _pump(tester);
    await service.dispose();
    await base.dispose();
  }
}

class _Card implements CardRepository {
  @override
  Future<CampusCard?> currentCard() async => const CampusCard(
        id: 'card',
        maskedNumber: '0001',
        ownerName: 'Test',
        balance: MoneyFen(10000),
        status: CampusCardStatus.normal,
        positionName: '',
        offlineCodeAllowed: true,
      );
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Online implements PaymentCodeRepository {
  Completer<PaymentCodeFrame>? retry;
  final pending = Completer<PaymentCodeFrame>();
  int calls = 0;
  @override
  Future<PaymentCodeFrame> generateOnlineCode() {
    calls++;
    return calls > 1 && retry != null ? retry!.future : pending.future;
  }

  @override
  Future<void> activateOnlineCode() async {}
  @override
  Future<PaymentCodePollResult> pollTransaction(
    String payCode, {
    PaymentRequestContext? context,
  }) async =>
      const PaymentPending();
}

class _Remote implements OfflineAuthorizationRemotePort {
  final pending = Completer<OfflineActivationResponse?>();
  int renewals = 0;
  @override
  Future<OfflineActivationResponse?> renew(OfflineAuthorization authorization) {
    renewals++;
    return pending.future;
  }

  @override
  Future<OfflineActivationResponse> activate(
    OfflineActivationRequest request,
  ) =>
      throw UnimplementedError();
}

class _Credentials implements OfflineCredentialRepository {
  _Credentials(this.delegate);
  final OfflineCredentialRepository delegate;
  Completer<void>? gate;
  int reservations = 0;
  @override
  Future<OfflineAuthorization> reserveUse(
    String cardId, {
    required String deviceCode,
  }) async {
    reservations++;
    await gate?.future;
    return delegate.reserveUse(cardId, deviceCode: deviceCode);
  }

  @override
  Future<OfflineAuthorization?> read(
    String cardId, {
    required String deviceCode,
  }) =>
      delegate.read(cardId, deviceCode: deviceCode);
  @override
  Future<OfflineAuthorization?> readMostRecent({required String deviceCode}) =>
      delegate.readMostRecent(deviceCode: deviceCode);
  @override
  Future<String?> readPrivateKey(String cardId, {required String deviceCode}) =>
      delegate.readPrivateKey(cardId, deviceCode: deviceCode);
  @override
  Future<void> install({
    required OfflineAuthorization authorization,
    required String privateKeyHex,
  }) =>
      delegate.install(
        authorization: authorization,
        privateKeyHex: privateKeyHex,
      );
  @override
  Future<void> updateAuthorization(
    OfflineAuthorization authorization, {
    bool resetUsage = false,
  }) =>
      delegate.updateAuthorization(authorization, resetUsage: resetUsage);
  @override
  Future<void> remove(String cardId) => delegate.remove(cardId);
  @override
  Future<void> removeAll() => delegate.removeAll();
}
