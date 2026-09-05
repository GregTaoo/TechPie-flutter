import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:techpie/features/campus_card/core/config/app_environment.dart';
import 'package:techpie/features/campus_card/data/repositories/disabled_ports.dart';
import 'package:techpie/features/campus_card/domain/models/security_models.dart';
import 'package:techpie/features/campus_card/domain/money_fen.dart';

void main() {
  test('production advertises verified reads but not unverified writes', () {
    final capabilities = AppCapabilities.forEnvironment(
      AppEnvironment.production,
    );
    expect(capabilities.authConfigured, isTrue);
    expect(capabilities.transactionHistory, isTrue);
    expect(capabilities.cardRecharge, isFalse);
    expect(capabilities.rechargeInitialization, isTrue);
    expect(capabilities.spendingLimits, isTrue);
    expect(capabilities.spendingLimitsRead, isTrue);
    expect(capabilities.changeSpendingPassword, isTrue);
    expect(capabilities.spendingPasswordInitialization, isTrue);
    expect(capabilities.offlinePaymentCode, isTrue);
  });

  test('real composition root has no dependency on demo repositories', () {
    final source = File(
      'lib/features/campus_card/app/real_runtime_factory.dart',
    ).readAsStringSync();
    expect(source, isNot(contains('/mock/')));
    expect(source, isNot(contains('Demo')));
    expect(source, contains('EcardOpenIdAuthPort'));
    expect(source, contains('EcardTransactionHistoryRepository'));
    expect(source, contains('EcardSecuritySettingsRepository'));
    expect(source, contains('EcardOfflineAuthorizationRemote'));
    expect(source, contains('identityGuard: auth.verifyCurrentIdentity'));
    expect(source, contains('verifiedIdSerialReader'));
    expect(source, contains('subjectReader: readSubjectId'));
  });

  test('disabled production adapters can never return success', () async {
    await expectLater(
      const DisabledRechargePort().create(
        amount: const MoneyFen(1000),
        channel: RechargeChannel.bankTransfer,
      ),
      throwsA(isA<Exception>()),
    );
    await expectLater(
      const DisabledSecuritySettingsPort().changeSpendingPassword(
        accountKey: 'SYNTHETIC-STUDENT',
        oldPassword: '000000',
        newPassword: '111111',
      ),
      throwsA(isA<Exception>()),
    );
    await expectLater(
      const DisabledTransactionHistoryPort().timeline(month: '2026-08'),
      throwsA(isA<Exception>()),
    );
  });

  test('recharge writes remain fail-closed', () {
    final rechargeSource = File(
      'lib/features/campus_card/data/repositories/ecard_recharge_repository.dart',
    ).readAsStringSync();
    expect(rechargeSource, contains('RECHARGE_WRITE_NOT_AUTHORIZED'));
  });

  test('settings are local and hidden flows are absent from routing', () {
    final settings = File(
      'lib/features/campus_card/presentation/screens/settings_screen.dart',
    ).readAsStringSync();
    final routes = File(
      'lib/features/campus_card/presentation/app/providers.dart',
    ).readAsStringSync();
    final information = File(
      'lib/features/campus_card/presentation/screens/card_manage_screen.dart',
    ).readAsStringSync();
    final providers = File(
      'lib/features/campus_card/app/app_providers.dart',
    ).readAsStringSync();
    expect(settings, isNot(contains('settingsControllerProvider')));
    expect(routes, isNot(contains('RechargeScreen')));
    expect(routes, isNot(contains('UnbindScreen')));
    expect(routes, isNot(contains('BillScreen')));
    expect(routes, isNot(contains('BillTimelineScreen')));
    expect(routes, contains('GpRoutes.transactions'));
    expect(information, isNot(contains('GpRoutes.recharge')));
    expect(information, isNot(contains('billSummary')));
    expect(information, isNot(contains("context.push('/unbind')")));
    expect(
      providers,
      contains(
        'AsyncNotifierProvider.autoDispose<SpendingLimitsController, SpendingLimits>',
      ),
    );
  });

  test(
    'sensitive payload tracing is isolated behind debug and explicit opt-in',
    () {
      final loggingCall = RegExp(
        r'(^|[^A-Za-z0-9_])(print|debugPrint|debugPrintSynchronously|log)\s*\(',
        multiLine: true,
      );
      final dartFiles = Directory('lib/features/campus_card')
          .listSync(recursive: true)
          .whereType<File>()
          .where((file) => file.path.endsWith('.dart'));
      for (final file in dartFiles) {
        final source = file.readAsStringSync();
        if (file.path.endsWith('decrypted_http_trace.dart')) {
          expect(
            source,
            contains('debugModeFeaturesAvailable && _traceRequested'),
          );
          expect(source, contains('GEEKPAY_TRACE_DECRYPTED_HTTP'));
          expect(source, matches(loggingCall));
          continue;
        }
        expect(source, isNot(matches(loggingCall)), reason: file.path);
      }
    },
  );
}
