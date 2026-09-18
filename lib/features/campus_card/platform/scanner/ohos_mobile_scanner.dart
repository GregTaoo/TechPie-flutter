import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
// The pinned 7.0.0-beta.6 implementation supplies camera/texture lifecycle,
// but rejects OHOS while decoding events. Override that boundary only.
// ignore: implementation_imports
import 'package:mobile_scanner/src/method_channel/mobile_scanner_method_channel.dart';

final class OhosMobileScanner extends MethodChannelMobileScanner {
  static const _methods = MethodChannel(
    'dev.steenbakker.mobile_scanner/scanner/method',
  );

  @override
  Stream<BarcodeCapture?> get barcodesStream => eventsStream
      .where((event) => event['name'] == 'barcode')
      .map(decodeCapture);

  @override
  Future<BarcodeCapture?> analyzeImage(
    String path, {
    List<BarcodeFormat> formats = const [],
  }) async {
    try {
      final event = await _methods.invokeMapMethod<Object?, Object?>(
        'analyzeImage',
        {
          'filePath': path,
          'formats': formats.isEmpty
              ? null
              : formats.map((format) => format.rawValue).toList(),
        },
      );
      return decodeCapture(event);
    } on PlatformException catch (error) {
      throw MobileScannerException(
        errorCode: MobileScannerErrorCode.genericError,
        errorDetails: MobileScannerErrorDetails(
          code: error.code,
          message: error.message,
        ),
      );
    }
  }

  static BarcodeCapture? decodeCapture(Map<Object?, Object?>? event) {
    final data = event?['data'];
    if (data is! List || data.isEmpty) return null;
    return BarcodeCapture(
      barcodes:
          data.cast<Map<Object?, Object?>>().map(Barcode.fromNative).toList(),
    );
  }
}
