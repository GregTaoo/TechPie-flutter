import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:techpie/features/campus_card/app/app_runtime.dart';
import 'package:techpie/features/campus_card/app/demo_runtime_factory.dart';
import 'package:techpie/features/campus_card/core/errors/app_failure.dart';
import 'package:techpie/features/campus_card/data/mock/in_memory_ports.dart';
import 'package:techpie/features/campus_card/data/storage/flutter_secure_credential_store.dart';
import 'package:techpie/features/campus_card/domain/models/auth_models.dart';
import 'package:techpie/features/campus_card/domain/ports/auth_port.dart';
import 'package:techpie/features/campus_card/domain/ports/credential_store.dart';
import 'package:techpie/pages/campus_card_account_page.dart';
import 'package:techpie/services/assignment_service.dart';
import 'package:techpie/services/auth_service.dart';
import 'package:techpie/services/campus_card_service.dart';
import 'package:techpie/services/debug_logger.dart';
import 'package:techpie/services/egate_app_service.dart';
import 'package:techpie/services/http_client.dart';
import 'package:techpie/services/oa_gym_service.dart';
import 'package:techpie/services/schedule_service.dart';
import 'package:techpie/services/service_provider.dart';
import 'package:techpie/services/storage_service.dart';
import 'package:techpie/services/sync_service.dart';
import 'package:techpie/services/theme_service.dart';
import 'package:techpie/services/third_party_auth_service.dart';
import 'package:techpie/services/uni_auth_service.dart';
import 'package:techpie/services/update_service.dart';
import 'package:techpie/widgets/adaptive_select.dart';

/// The host's eCard account editor owns the OPENID the app authenticates with:
/// checking it must not store anything, saving must store it, and removing must
/// clear it. Those three writes are what this file exercises against a scripted
/// identity port, so a regression in the credential path fails here.
void main() {
  const openId = 'SYNTHETIC_OPENID_0123456789ABCDEF';

  late InMemorySecureCredentialStore secureStore;
  late SecureSessionCredentialStore sessionStore;
  late _ScriptedAuthPort auth;
  late CampusCardService service;

  Future<Widget> mount() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final storage = StorageService(prefs);
    final logger = DebugLogger()..enabled = true;
    final http = LoggingHttpClient(logger);
    final uniAuth = UniAuthService();
    final hostAuth = AuthService(storage, http, uniAuth);
    final theme = ThemeService(storage);
    final tpAuth = ThirdPartyAuthService(storage, http);
    final schedule = ScheduleService(storage, http, hostAuth, tpAuth);
    final assignments =
        AssignmentService(storage, http, hostAuth, tpAuth, schedule);
    final oaGym = OaGymService(hostAuth, storage, tpAuth);
    final egateApp = EgateAppService(hostAuth, storage, tpAuth);

    secureStore = InMemorySecureCredentialStore();
    sessionStore = SecureSessionCredentialStore(secureStore);
    auth = _ScriptedAuthPort(sessionStore);
    addTearDown(auth.dispose);
    final base = await buildDemoRuntime();
    final runtime = AppRuntime(
      environment: base.environment,
      capabilities: base.capabilities,
      auth: auth,
      cards: base.cards,
      paymentCodes: base.paymentCodes,
      scanPayments: base.scanPayments,
      transactions: base.transactions,
      securitySettings: base.securitySettings,
      offlinePayments: base.offlinePayments,
      brightness: base.brightness,
      connectivity: base.connectivity,
      lifecycle: base.lifecycle,
      feedback: base.feedback,
      scanner: base.scanner,
      disposeRuntime: base.dispose,
    );
    service = CampusCardService.withStore(
      secureStore,
      runtimeFactory: () => runtime,
    );
    addTearDown(service.dispose);
    // Sync is built after the card service it pushes to, exactly as main.dart
    // wires them.
    final sync = SyncService(hostAuth, tpAuth, storage, ecard: service);

    return ServiceProvider(
      authService: hostAuth,
      debugLogger: logger,
      storageService: storage,
      themeService: theme,
      scheduleService: schedule,
      assignmentService: assignments,
      thirdPartyAuthService: tpAuth,
      oaGymService: oaGym,
      egateAppService: egateApp,
      uniAuthService: uniAuth,
      syncService: sync,
      updateService: UpdateService(),
      campusCardService: service,
      child: const MaterialApp(home: CampusCardAccountPage()),
    );
  }

  testWidgets('loads the stored OPENID and channel, and offers an update', (
    WidgetTester tester,
  ) async {
    final app = await mount();
    await service.connect(openId, channel: EcardOpenIdChannel.alipay);

    await tester.pumpWidget(app);
    await tester.pumpAndSettle();

    expect(find.text(openId), findsOneWidget);
    expect(
      tester.widget<AdaptiveSelect>(find.byType(AdaptiveSelect)).value,
      EcardOpenIdChannel.alipay.method,
    );
    expect(find.text('更新 eCard'), findsOneWidget);
    expect(find.text('移除 eCard'), findsOneWidget);
  });

  testWidgets('checking the OPENID verifies it without storing anything', (
    WidgetTester tester,
  ) async {
    final app = await mount();
    await tester.pumpWidget(app);
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), openId);
    await tester.tap(find.text('检查登录'));
    await tester.pumpAndSettle();

    expect(auth.verifyCalls, 1);
    expect(find.text('OPENID 可以正常登录 eCard'), findsOneWidget);
    expect(await service.readOpenId(), isNull);
    expect(service.configured, isFalse);
  });

  testWidgets('saving connects the account and stores the OPENID', (
    WidgetTester tester,
  ) async {
    final app = await mount();
    await tester.pumpWidget(app);
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), openId);
    await tester.tap(find.text('连接 eCard'));
    await tester.pumpAndSettle();

    expect(auth.signInCalls, 1);
    expect(find.text('eCard 已连接'), findsOneWidget);
    expect(await service.readOpenId(), openId);
    expect(service.configured, isTrue);
  });

  testWidgets('a rejected OPENID is reported inline and stored nowhere', (
    WidgetTester tester,
  ) async {
    final app = await mount();
    auth.verifyFailure = const FormatException('malformed OPENID');
    await tester.pumpWidget(app);
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'not-an-openid');
    await tester.tap(find.text('检查登录'));
    await tester.pumpAndSettle();

    expect(find.text('OPENID 格式无效'), findsOneWidget);
    expect(await service.readOpenId(), isNull);
    expect(service.configured, isFalse);
  });

  testWidgets('a failed save reports the reason and stays unconfigured', (
    WidgetTester tester,
  ) async {
    final app = await mount();
    auth.signInFailure = const AppFailure(
      FailureKind.network,
      '网络不可用，请稍后重试',
      code: 'ECARD_SIGN_IN_OFFLINE',
    );
    await tester.pumpWidget(app);
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), openId);
    await tester.tap(find.text('连接 eCard'));
    await tester.pumpAndSettle();

    expect(find.text('网络不可用，请稍后重试'), findsOneWidget);
    expect(service.configured, isFalse);
    expect(await service.readOpenId(), isNull);
  });

  testWidgets('removing the account clears the OPENID after confirmation', (
    WidgetTester tester,
  ) async {
    final app = await mount();
    await service.connect(openId);
    await tester.pumpWidget(app);
    await tester.pumpAndSettle();

    await tester.tap(find.text('移除 eCard'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('移除'));
    await tester.pumpAndSettle();

    expect(find.text('eCard 已移除'), findsOneWidget);
    expect(await service.readOpenId(), isNull);
    expect(service.configured, isFalse);
  });
}

/// Identity port that records what the form asked for and can be told to refuse,
/// so the page's success and failure branches are both reachable without a network.
final class _ScriptedAuthPort implements AuthPort, OpenIdAuthVerifier {
  _ScriptedAuthPort(this._sessionStore);

  final SessionCredentialStore _sessionStore;
  final _changes = StreamController<AuthSnapshot>.broadcast(sync: true);

  Object? verifyFailure;
  Object? signInFailure;
  int verifyCalls = 0;
  int signInCalls = 0;

  @override
  Stream<AuthSnapshot> get changes => _changes.stream;

  @override
  Future<AuthSnapshot> restoreLocal() => restore();

  @override
  Future<AuthSnapshot> restore() async {
    final openId = await _sessionStore.readOpenId();
    return openId == null
        ? const AuthSnapshot(state: AuthState.signedOut)
        : _authenticated();
  }

  @override
  Future<void> verifyOpenId(
    String openId, {
    EcardOpenIdChannel channel = EcardOpenIdChannel.wechat,
  }) async {
    final failure = verifyFailure;
    if (failure != null) throw failure;
    OpenIdAuthCredential(openId: openId).validate();
    verifyCalls += 1;
  }

  @override
  Future<AuthSnapshot> signIn(AuthCredential credential) async {
    final failure = signInFailure;
    if (failure != null) throw failure;
    final openIdCredential = credential as OpenIdAuthCredential;
    await verifyOpenId(
      openIdCredential.openId,
      channel: openIdCredential.channel,
    );
    signInCalls += 1;
    await _sessionStore.writeSession(
      sessionCookie: 'JSESSIONID=synthetic',
      openId: openIdCredential.openId,
      orgId: '2',
      verifiedIdSerial: 'SYNTHETIC-STUDENT',
      verifiedCardId: 'SYNTHETIC-CARD',
      channel: openIdCredential.channel,
    );
    final snapshot = _authenticated();
    _changes.add(snapshot);
    return snapshot;
  }

  @override
  Future<void> signOut() async {
    await _sessionStore.clear();
    _changes.add(const AuthSnapshot(state: AuthState.signedOut));
  }

  AuthSnapshot _authenticated() => const AuthSnapshot(
        state: AuthState.authenticated,
        session: AuthSession(
          subjectId: 'synthetic',
          orgId: '2',
          maskedIdentity: 'SYNT****CDEF',
        ),
      );

  Future<void> dispose() => _changes.close();
}
