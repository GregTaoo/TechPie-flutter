import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:techpie/features/campus_card/app/app_providers.dart';
import 'package:techpie/features/campus_card/app/app_runtime.dart';
import 'package:techpie/features/campus_card/app/demo_runtime_factory.dart';
import 'package:techpie/features/campus_card/core/config/scan_payment_preferences.dart';
import 'package:techpie/features/campus_card/data/mock/in_memory_ports.dart';
import 'package:techpie/features/campus_card/domain/models/scan_models.dart';
import 'package:techpie/features/campus_card/presentation/scanner/scan_result_content.dart';
import 'package:techpie/features/campus_card/presentation/scanner/scanner_modal.dart';

void main() {
  group('ScanFailureContent', () {
    testWidgets('renders server-provided message and rescan action', (
      tester,
    ) async {
      var rescanned = false;
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: ScanFailureContent(
            message: '无效的支付码',
            onRescan: () => rescanned = true,
          ),
        ),
      );

      expect(find.text('识别失败'), findsOneWidget);
      expect(find.text('无效的支付码'), findsOneWidget);

      await tester.tap(find.text('重新扫码'));
      await tester.pump();
      expect(rescanned, isTrue);
    });
  });

  group('gpScannerEntranceTransition', () {
    testWidgets('normal mode produces a slide transition', (tester) async {
      const controller = AlwaysStoppedAnimation<double>(1);
      final result = gpScannerEntranceTransition(
        controller,
        const Text('scanner'),
        reduceMotion: false,
      );
      expect(result, isA<SlideTransition>());
    });

    testWidgets('Reduce Motion produces a fade transition, never zero slide', (
      tester,
    ) async {
      const controller = AlwaysStoppedAnimation<double>(1);
      final result = gpScannerEntranceTransition(
        controller,
        const Text('scanner'),
        reduceMotion: true,
      );
      expect(result, isA<FadeTransition>());
    });
  });

  group('gpScannerPopupTransition', () {
    testWidgets('normal mode fades and moves the popup', (tester) async {
      const controller = AlwaysStoppedAnimation<double>(1);
      final result = gpScannerPopupTransition(
        controller,
        const Text('popup'),
        reduceMotion: false,
      );
      expect(result, isA<FadeTransition>());
      expect((result as FadeTransition).child, isA<SlideTransition>());
    });

    testWidgets('Reduce Motion keeps a fade-only popup', (tester) async {
      const controller = AlwaysStoppedAnimation<double>(1);
      final result = gpScannerPopupTransition(
        controller,
        const Text('popup'),
        reduceMotion: true,
      );
      expect(result, isA<FadeTransition>());
      expect((result as FadeTransition).child, isA<Text>());
    });
  });

  testWidgets('closing the scanner releases its camera after unmount',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final scanner = InMemoryScannerPort();
    final (base, runtime) = await _scannerRuntime(scanner);
    addTearDown(base.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [appRuntimeProvider.overrideWithValue(runtime)],
        child: MaterialApp(home: ScannerModal(onClose: () {})),
      ),
    );
    await tester.pumpAndSettle();
    expect(scanner.running, isTrue);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(scanner.running, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('asks for confirmation before submitting a scan by default', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final scanner = InMemoryScannerPort();
    final (base, runtime) = await _scannerRuntime(scanner);
    addTearDown(base.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [appRuntimeProvider.overrideWithValue(runtime)],
        child: MaterialApp(home: ScannerModal(onClose: () {})),
      ),
    );
    await tester.pumpAndSettle();

    scanner.emit('SYNTHETIC-SCAN-CODE');
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
    expect(find.text('是否继续扫码交易？'), findsOneWidget);
    expect(
      find.ancestor(
        of: find.byKey(const ValueKey('scan-confirmation-popup')),
        matching: find.byType(FadeTransition),
      ),
      findsWidgets,
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('¥'), findsNothing);
    final container = ProviderScope.containerOf(
      tester.element(find.byType(ScannerModal)),
    );
    expect(
      container.read(scanPaymentControllerProvider).phase,
      ScanFlowPhase.idle,
    );

    await tester.tap(find.text('继续'));
    await tester.pumpAndSettle();
    expect(
      container.read(scanPaymentControllerProvider).phase,
      ScanFlowPhase.succeeded,
    );
  });

  testWidgets('submits immediately when scan confirmation is skipped', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final scanner = InMemoryScannerPort();
    final (base, runtime) = await _scannerRuntime(scanner);
    addTearDown(base.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [appRuntimeProvider.overrideWithValue(runtime)],
        child: MaterialApp(home: ScannerModal(onClose: () {})),
      ),
    );
    await tester.pumpAndSettle();
    final container = ProviderScope.containerOf(
      tester.element(find.byType(ScannerModal)),
    );
    await container
        .read(skipScanConfirmationProvider.notifier)
        .setEnabled(true);

    scanner.emit('SYNTHETIC-SCAN-CODE');
    await tester.pumpAndSettle();

    expect(find.text('是否继续扫码交易？'), findsNothing);
    expect(
      container.read(scanPaymentControllerProvider).phase,
      ScanFlowPhase.succeeded,
    );
  });
}

Future<(AppRuntime, AppRuntime)> _scannerRuntime(
  InMemoryScannerPort scanner,
) async {
  final base = await buildDemoRuntime();
  final runtime = AppRuntime(
    environment: base.environment,
    capabilities: base.capabilities,
    auth: base.auth,
    cards: base.cards,
    paymentCodes: base.paymentCodes,
    scanPayments: base.scanPayments,
    transactions: base.transactions,
    securitySettings: base.securitySettings,
    offlinePayments: base.offlinePayments,
    brightness: base.brightness,
    connectivity: base.connectivity,
    lifecycle: base.lifecycle,
    haptics: base.haptics,
    scanner: scanner,
  );
  return (base, runtime);
}
