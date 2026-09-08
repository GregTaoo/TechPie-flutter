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

  test('keeps polling when the query has no confirmed result', () async {
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
      isA<PaymentPending>(),
    );
    expect(
      await repository.pollTransaction('code-1'),
      isA<PaymentPending>(),
    );
  });

  test('unused-code failure wording is a pending result, never a rejection',
      () async {
    for (final success in [true, false]) {
      for (final status in [5, null]) {
        final transport = FakeEcardTransport()
          ..enqueue('POST', '/virtualcard/queryOrderStatus', {
            'success': success,
            'data': {
              if (status != null) 'status': status,
              'message': '支付失败，付款码未使用',
              'txamt': 0,
            },
          });
        expect(
          await EcardPaymentCodeRepository(transport).pollTransaction('code'),
          isA<PaymentPending>(),
        );
      }
    }
  });

  test('maps the explicitly successful result page amount in fen', () async {
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

  test('a failure result URL and amount never imply payment success', () async {
    final transport = FakeEcardTransport()
      ..enqueue('POST', '/virtualcard/queryOrderStatus', {
        'success': true,
        'data': {
          'status': 2,
          'txamt': '880.00',
          'url': '/pages/common/payfailure/payfailure',
          'message': '密码错误',
        },
      });
    final result = await EcardPaymentCodeRepository(transport)
        .pollTransaction('test-failed-code');

    expect(result, isA<PaymentNotCompleted>());
    expect((result as PaymentNotCompleted).reason, '密码错误');
  });

  test('a password error overrides a contradictory success result URL',
      () async {
    final transport = FakeEcardTransport()
      ..enqueue('POST', '/virtualcard/queryOrderStatus', {
        'success': true,
        'data': {
          'status': 1,
          'txamt': 880,
          'url': '/pages/common/paysuccess/paysuccess',
          'message': '密码错误',
        },
      });
    expect(
      await EcardPaymentCodeRepository(transport).pollTransaction('code'),
      isA<PaymentNotCompleted>(),
    );
  });

  test('unrecognized result destinations do not confirm payment', () async {
    for (final url in [
      '/pages/common/payfailure/payfailure',
      '/unknown-result?next=/pages/common/paysuccess/paysuccess',
    ]) {
      final transport = FakeEcardTransport()
        ..enqueue('POST', '/virtualcard/queryOrderStatus', {
          'success': true,
          'data': {'status': 9, 'txamt': 880, 'url': url},
        });
      expect(
        await EcardPaymentCodeRepository(transport).pollTransaction('code'),
        isA<PaymentNotCompleted>(),
      );
    }
  });

  test('nested rejection cannot confirm a successful payment', () async {
    final transport = FakeEcardTransport()
      ..enqueue('POST', '/virtualcard/queryOrderStatus', {
        'success': true,
        'data': {
          'success': false,
          'txamt': 880,
          'url': '/pages/common/paysuccess/paysuccess',
        },
      });
    expect(
      await EcardPaymentCodeRepository(transport).pollTransaction('code'),
      isA<PaymentNotCompleted>(),
    );
  });

  test('gateway failures still select offline fallback', () async {
    for (final message in ['开放平台返回失败', '开放平台请求超时']) {
      final transport = FakeEcardTransport()
        ..enqueue('POST', '/virtualcard/queryOrderStatus', {
          'success': false,
          'message': message,
        });
      expect(
        await EcardPaymentCodeRepository(transport).pollTransaction('code'),
        isA<PaymentShouldUseOffline>(),
      );
    }
  });
}
