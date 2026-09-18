import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:techpie/features/campus_card/app/app_providers.dart';
import 'package:techpie/features/campus_card/app/app_runtime.dart';
import 'package:techpie/features/campus_card/app/demo_runtime_factory.dart';
import 'package:techpie/features/campus_card/domain/models/auth_models.dart';
import 'package:techpie/features/campus_card/domain/ports/auth_port.dart';
import 'package:techpie/features/campus_card/presentation/app/providers.dart';

void main() {
  testWidgets(
      'account changes clear page-local state within the existing route',
      (tester) async {
    final base = await buildDemoRuntime();
    final auth = _PageTestAuthPort();
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
    );
    final container = ProviderContainer(
      overrides: [
        appRuntimeProvider.overrideWithValue(runtime),
      ],
    );
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          pageBuilder: (context, state) =>
              gpPlatformPage(context, state, const _AccountLocalState()),
        ),
      ],
    );
    addTearDown(() async {
      router.dispose();
      container.dispose();
      await auth.dispose();
      await base.dispose();
    });
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Local state: 0'));
    await tester.pump();
    expect(find.text('Local state: 1'), findsOneWidget);

    auth.switchSubject('account-b');
    await tester.pumpAndSettle();
    expect(find.text('Local state: 1'), findsNothing);
    expect(find.text('Local state: 0'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  test(
    'iOS pages use Cupertino routes and Android pages use Material routes',
    () {
      expect(
        gpPageForPlatform(
          TargetPlatform.iOS,
          key: const ValueKey('ios'),
          child: const SizedBox(),
        ),
        isA<CupertinoPage<void>>(),
      );
      expect(
        gpPageForPlatform(
          TargetPlatform.android,
          key: const ValueKey('android'),
          child: const SizedBox(),
        ),
        isA<MaterialPage<void>>(),
      );
    },
  );

  testWidgets('iOS edge swipe moves the current page with the finger', (
    tester,
  ) async {
    late final GoRouter router;
    router = GoRouter(
      initialLocation: '/first',
      routes: [
        GoRoute(
          path: '/first',
          pageBuilder: (context, state) => gpPageForPlatform(
            TargetPlatform.iOS,
            key: state.pageKey,
            child: Scaffold(
              key: const Key('first-page'),
              body: Center(
                child: TextButton(
                  onPressed: () => context.push('/second'),
                  child: const Text('next'),
                ),
              ),
            ),
          ),
        ),
        GoRoute(
          path: '/second',
          pageBuilder: (context, state) => gpPageForPlatform(
            TargetPlatform.iOS,
            key: state.pageKey,
            child: const Scaffold(
              key: Key('second-page'),
              body: Center(child: Text('second')),
            ),
          ),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      MaterialApp.router(
        theme: ThemeData(platform: TargetPlatform.iOS),
        routerConfig: router,
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('next'));
    await tester.pumpAndSettle();

    final second = find.byKey(const Key('second-page'));
    expect(tester.getTopLeft(second).dx, closeTo(0, 0.1));
    final gesture = await tester.startGesture(const Offset(1, 400));
    await gesture.moveBy(const Offset(140, 0));
    await tester.pump();
    expect(tester.getTopLeft(second).dx, greaterThan(0));

    await gesture.moveBy(const Offset(260, 0));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('first-page')), findsOneWidget);
    expect(second, findsNothing);
  });
}

final class _PageTestAuthPort implements AuthPort {
  final _changes = StreamController<AuthSnapshot>.broadcast(sync: true);
  AuthSnapshot _snapshot = const AuthSnapshot(
    state: AuthState.authenticated,
    session: AuthSession(subjectId: 'account-a', orgId: '2'),
  );

  @override
  Stream<AuthSnapshot> get changes => _changes.stream;
  @override
  Future<AuthSnapshot> restoreLocal() async => _snapshot;
  @override
  Future<AuthSnapshot> restore() async => _snapshot;
  @override
  Future<AuthSnapshot> signIn(AuthCredential credential) async => _snapshot;
  @override
  Future<void> signOut() async {}

  void switchSubject(String subject) {
    _snapshot = AuthSnapshot(
      state: AuthState.authenticated,
      session: AuthSession(subjectId: subject, orgId: '2'),
    );
    _changes.add(_snapshot);
  }

  Future<void> dispose() => _changes.close();
}

final class _AccountLocalState extends StatefulWidget {
  const _AccountLocalState();
  @override
  State<_AccountLocalState> createState() => _AccountLocalStateState();
}

final class _AccountLocalStateState extends State<_AccountLocalState> {
  int value = 0;
  @override
  Widget build(BuildContext context) => Scaffold(
        body: Center(
          child: TextButton(
            onPressed: () => setState(() => value++),
            child: Text('Local state: $value'),
          ),
        ),
      );
}
