import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:techpie/features/campus_card/platform/scanner/ohos_mobile_scanner.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel =
      MethodChannel('dev.steenbakker.mobile_scanner/scanner/method');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test(
      'OHOS image and camera payloads decode without the upstream platform gate',
      () async {
    final payload = <Object?, Object?>{
      'name': 'barcode',
      'data': [
        <Object?, Object?>{
          'rawValue': 'TECHPIE_OHOS_SCANNER_TEST',
          'displayValue': 'TECHPIE_OHOS_SCANNER_TEST',
          'format': BarcodeFormat.qrCode.rawValue,
        },
      ],
    };
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'analyzeImage');
      expect((call.arguments as Map)['filePath'], 'file://media/test.png');
      return payload;
    });
    final capture =
        await OhosMobileScanner().analyzeImage('file://media/test.png');
    expect(capture?.barcodes.single.rawValue, 'TECHPIE_OHOS_SCANNER_TEST');
    expect(OhosMobileScanner.decodeCapture(payload)?.barcodes.single.format,
        BarcodeFormat.qrCode,);
    expect(OhosMobileScanner.decodeCapture({'data': []}), isNull);
  });

  test('OHOS image decoder errors remain visible to the scanner UI', () async {
    messenger.setMockMethodCallHandler(channel, (_) async {
      throw PlatformException(
          code: 'MOBILE_SCANNER_BARCODE_ERROR', message: 'Invalid image',);
    });
    await expectLater(
      OhosMobileScanner().analyzeImage('file://media/test.png'),
      throwsA(
        isA<MobileScannerException>().having(
          (error) => error.errorDetails?.code,
          'native error code',
          'MOBILE_SCANNER_BARCODE_ERROR',
        ),
      ),
    );
  });
}
