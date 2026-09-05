import 'package:clock/clock.dart';

import '../../core/errors/app_failure.dart';
import '../../domain/models/payment_models.dart';
import '../../domain/money_fen.dart';
import '../../domain/ports/payment_ports.dart';
import '../api/ecard_api_client.dart';
import '../api/qr_payload_codec.dart';

final class EcardPaymentCodeRepository implements PaymentCodeRepository {
  EcardPaymentCodeRepository(this._client, {Clock? clock})
      : _clock = clock ?? const Clock();

  static const _gatewayFallbackMessages = {'开放平台返回失败', '开放平台请求超时'};

  final EcardTransport _client;
  final Clock _clock;

  @override
  Future<PaymentCodeFrame> generateOnlineCode() async {
    final response = requireObjectMap(
      await _client.post('/offlineCode/openVirtualcard', {
        'usertype': '8',
        'appcode': '1',
      }),
      context: 'PAYMENT_CODE',
    );
    if (!apiSuccess(response)) {
      final message = apiMessage(response, fallback: '付款码生成失败。');
      if (message.contains('未开通')) {
        throw AppFailure(
          FailureKind.unavailable,
          message,
          code: 'PAYMENT_CODE_NOT_ACTIVATED',
        );
      }
      throw AppFailure(
        FailureKind.server,
        message,
        code: 'PAYMENT_CODE_GENERATION_REJECTED',
        retryable: true,
      );
    }
    final data = requireObjectMap(
      response['data'],
      context: 'PAYMENT_CODE_DATA',
    );
    final payCode = data['code']?.toString() ?? '';
    final qrcode = data['qrcode']?.toString().trim() ?? '';
    final rawQrCode = qrcode.isEmpty ? payCode : qrcode;
    if (payCode.isEmpty || rawQrCode.isEmpty) {
      throw const AppFailure(
        FailureKind.protocol,
        '服务未返回完整付款码。',
        code: 'PAYMENT_CODE_FIELDS_MISSING',
      );
    }
    late String payload;
    try {
      payload = QrPayloadCodec.online(rawQrCode);
    } on FormatException catch (error) {
      throw AppFailure(
        FailureKind.protocol,
        '付款码内容格式无效。',
        code: 'PAYMENT_QR_PAYLOAD_INVALID',
        cause: error,
      );
    }
    return PaymentCodeFrame(
      payCode: payCode,
      rawQrCode: rawQrCode,
      qrPayload: payload,
      offlineAllowed: data['allowOfflineCode']?.toString() == '1',
      generatedAt: _clock.now().toUtc(),
    );
  }

  @override
  Future<void> activateOnlineCode() async {
    final response = requireObjectMap(
      await _client.post('/virtualcard/openVirtualCardSelf', const {}),
      context: 'PAYMENT_CODE_ACTIVATION',
    );
    if (!apiSuccess(response)) {
      throw AppFailure(
        FailureKind.server,
        apiMessage(response, fallback: '付款码开通失败。'),
        code: 'PAYMENT_CODE_ACTIVATION_REJECTED',
      );
    }
  }

  @override
  Future<PaymentCodePollResult> pollTransaction(String payCode) async {
    final response = requireObjectMap(
      await _client.post('/virtualcard/queryOrderStatus', {'paycode': payCode}),
      context: 'PAYMENT_RESULT',
    );
    final data = response['data'] is Map
        ? requireObjectMap(response['data'], context: 'PAYMENT_RESULT_DATA')
        : response;
    final message = (data['message'] ?? response['message'])?.toString() ?? '';
    if (_gatewayFallbackMessages.contains(message)) {
      return PaymentShouldUseOffline(message);
    }
    if (!apiSuccess(response)) {
      return PaymentShouldUseOffline(message.isEmpty ? '付款状态查询失败。' : message);
    }
    final status = int.tryParse(data['status']?.toString() ?? '');
    if (status == 5) return const PaymentPending();
    if (status == 3) return const PaymentCodeExpired();
    final resultUrl = (data['url'] ?? response['url'])?.toString().trim() ?? '';
    if (resultUrl.isNotEmpty && data['txamt'] != null) {
      return PaymentCompleted(
        TransactionResult(
          amount: _paymentResultFen(data['txamt']),
          confirmedLocallyAt: _clock.now().toUtc(),
          tradeAt: _date(data['paytime']),
        ),
      );
    }
    return PaymentShouldUseOffline(message.isEmpty ? '付款状态响应内容不完整。' : message);
  }

  MoneyFen _paymentResultFen(Object? value) {
    final source = value?.toString().trim() ?? '';
    final match = RegExp(r'^(\d+)(?:\.0+)?$').firstMatch(source);
    if (match == null) {
      throw const AppFailure(
        FailureKind.protocol,
        '付款结果金额格式无效。',
        code: 'PAYMENT_RESULT_AMOUNT_INVALID',
      );
    }
    return MoneyFen.fromApiFen(match.group(1)!, field: 'txamt');
  }

  DateTime? _date(Object? value) {
    final source = value?.toString().trim();
    if (source == null || source.isEmpty) return null;
    return DateTime.tryParse(source.replaceFirst(' ', 'T'))?.toUtc();
  }
}
