import '../../domain/models/scan_models.dart';
import '../../domain/money_fen.dart';
import '../../domain/ports/payment_ports.dart';
import '../api/ecard_api_client.dart';

final class EcardScanPaymentRepository implements ScanPaymentRepository {
  EcardScanPaymentRepository(this._client);

  final EcardTransport _client;

  @override
  Future<ScanPaymentResult> submit({
    required String qrCode,
    required DateTime payTime,
    String? password,
  }) async {
    final outboundQrCode = password == null ? qrCode : Uri.decodeFull(qrCode);
    final payload = <String, Object?>{
      'qrcode': outboundQrCode,
      'paytime': payTime.toUtc().millisecondsSinceEpoch,
    };
    if (password != null) payload['password'] = password;
    final response = requireObjectMap(
      await _client.post('/scan/scanningResult', payload),
      context: 'SCAN_PAYMENT',
    );
    final status = response['issuccess']?.toString();
    if (status == '2004') {
      final serverQrCode = response['qrcode']?.toString() ?? '';
      if (serverQrCode.isEmpty) {
        return const ScanFailed(
          message: '服务未返回密码重试所需的付款码。',
          code: 'SCAN_PASSWORD_QR_MISSING',
        );
      }
      return ScanPasswordRequired(serverQrCode: serverQrCode);
    }
    final resultUrl = response['url']?.toString().trim() ?? '';
    if (apiSuccess(response) &&
        (status == '1' || (password != null && resultUrl.isNotEmpty))) {
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
