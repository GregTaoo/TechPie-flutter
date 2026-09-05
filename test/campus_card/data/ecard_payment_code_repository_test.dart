import 'package:clock/clock.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:techpie/features/campus_card/data/repositories/ecard_payment_code_repository.dart';
import 'package:techpie/features/campus_card/domain/models/payment_models.dart';
import 'package:techpie/features/campus_card/domain/money_fen.dart';

import '../support/fake_ecard_transport.dart';

void main() {
  test('uses live POST contract and accepts code as QR fallback', () async {
    final transport = FakeEcardTransport()
      ..enqueue('POST', '/offlineCode/openVirtualcard', {
        'success': true,
        'data': {
          'code': '5638AABBCCDD',
          'qrcode': '',
          'allowOfflineCode': '1',
          'idserial': 'SYNTHETIC-STUDENT',
        },
      });
    final repository = EcardPaymentCodeRepository(
      transport,
      clock: Clock.fixed(DateTime.utc(2026, 9, 1)),
    );

    final frame = await repository.generateOnlineCode();

    expect(frame.payCode, '5638AABBCCDD');
    expect(frame.rawQrCode, '5638AABBCCDD');
    expect(frame.qrPayload, isNotEmpty);
    expect(transport.requests.single.method, 'POST');
  });

  test('distinguishes unused and expired live statuses', () async {
    final transport = FakeEcardTransport()
      ..enqueue('POST', '/virtualcard/queryOrderStatus', {
        'success': true,
        'data': {'status': 5, 'txamt': 0},
      })
      ..enqueue('POST', '/virtualcard/queryOrderStatus', {
        'success': true,
        'data': {'status': 3, 'txamt': 0},
      });
    final repository = EcardPaymentCodeRepository(transport);

    expect(await repository.pollTransaction('code-1'), isA<PaymentPending>());
    expect(
      await repository.pollTransaction('code-1'),
      isA<PaymentCodeExpired>(),
    );
  });

  test('falls back for business rejection or incomplete status data', () async {
    final transport = FakeEcardTransport()
      ..enqueue('POST', '/virtualcard/queryOrderStatus', {
        'success': false,
        'message': 'synthetic rejection',
      })
      ..enqueue('POST', '/virtualcard/queryOrderStatus', {
        'success': true,
        'data': {'status': 1},
      });
    final repository = EcardPaymentCodeRepository(transport);

    expect(
      await repository.pollTransaction('code-1'),
      isA<PaymentShouldUseOffline>(),
    );
    expect(
      await repository.pollTransaction('code-1'),
      isA<PaymentShouldUseOffline>(),
    );
  });

  test('maps a non-pending nested result amount in fen', () async {
    final transport = FakeEcardTransport()
      ..enqueue('POST', '/virtualcard/queryOrderStatus', {
        'success': true,
        'data': {
          'status': 1,
          'txamt': '880.00',
          'url': '/pages/common/paysuccess/paysuccess',
          'paytime': '2026-09-02 12:30:45',
        },
      });
    final repository = EcardPaymentCodeRepository(
      transport,
      clock: Clock.fixed(DateTime.utc(2026, 9, 1)),
    );

    final result = await repository.pollTransaction('code-1');

    expect(result, isA<PaymentCompleted>());
    expect((result as PaymentCompleted).result.amount, const MoneyFen(880));
    expect(result.result.tradeAt, DateTime(2026, 9, 2, 12, 30, 45).toUtc());
  });
}
