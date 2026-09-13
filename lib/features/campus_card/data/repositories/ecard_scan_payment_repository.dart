import 'package:techpie/features/campus_card/domain/models/payment_models.dart';
import '../../domain/models/scan_models.dart';
import '../../domain/money_fen.dart';
import '../../domain/ports/payment_ports.dart';
import '../api/ecard_api_client.dart';

final class EcardScanPaymentRepository implements ScanPaymentRepository {
  EcardScanPaymentRepository(this._client);

  final EcardTransport _client;

  static const _successResultPaths = {
    '/pages/common/success/success',
    '/pages/common/paysuccess/paysuccess',
  };

  @override
  Future<ScanPaymentResult> submit({
    required String qrCode,
    required DateTime payTime,
    String? password,
    PaymentRequestContext? context,
  }) async {
    // Preserve the server-returned challenge, including percent escapes, so
    // password retries match the code held by the payment context.
    final payload = <String, Object?>{
      'qrcode': qrCode,
      'paytime': payTime.toUtc().millisecondsSinceEpoch,
    };
    if (password != null) payload['password'] = password;
    final response = requireObjectMap(
      await (_client is EcardApiClient
          ? (_client).submitScanPayment(payload, context)
          : _client.post('/scan/scanningResult', payload)),
      context: 'SCAN_PAYMENT',
    );
    final status = response['issuccess']?.toString();
    final data = response['data'] is Map
        ? requireObjectMap(response['data'], context: 'SCAN_PAYMENT_DATA')
        : const <String, Object?>{};
    final resultUrl = response['url']?.toString().trim() ?? '';
    final resultPath = Uri.tryParse(resultUrl)?.path;
    if (status == '2004' ||
        (apiSuccess(response) &&
            !apiRejected(data) &&
            resultPath == '/pages/common/inputPass/inputPass')) {
      final serverQrCode =
          (data['qrcode'] ?? response['qrcode'])?.toString() ?? '';
      if (serverQrCode.trim().isEmpty) {
        return const ScanFailed(
          message: '服务未返回密码重试所需的付款码。',
          code: 'SCAN_PASSWORD_QR_MISSING',
        );
      }
      return ScanPasswordRequired(
        serverQrCode: serverQrCode,
        context: response is EcardResponseMap ? response.requestContext : null,
      );
    }
    if (apiSuccess(response) &&
        !apiRejected(data) &&
        ((status == '1' && resultUrl.isEmpty) ||
            _successResultPaths.contains(resultPath))) {
      final resultData = response['resultData'] is Map
          ? requireObjectMap(
              response['resultData'],
              context: 'SCAN_RESULT_DATA',
            )
          : const <String, Object?>{};
      final type = (resultData['type'] ?? response['type'])?.toString() ?? '';
      return ScanSucceeded(
        kind: switch (type) {
          '' => ScanSuccessKind.payment,
          'scj' => ScanSuccessKind.attendance,
          'opendevice' => ScanSuccessKind.openDevice,
          'bindTray' => ScanSuccessKind.bindTray,
          _ => ScanSuccessKind.unknown,
        },
        amount: _optionalFen(response['txamt'], 'txamt'),
        fee: _optionalFen(response['managefee'], 'managefee'),
        balance: _optionalFen(response['balance'], 'balance'),
        message: response['message']?.toString(),
      );
    }
    return ScanFailed(
      message: apiMessage(response, fallback: '扫码消费失败。'),
      code: status,
    );
  }

  MoneyFen? _optionalFen(Object? value, String field) =>
      value == null || value.toString().isEmpty
          ? null
          : MoneyFen.fromApiFen(value, field: field);
}
