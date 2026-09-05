import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:techpie/services/ios/ecard_deep_link_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
      'cold-start eCard link opens after the navigator handler attaches', (
    tester,
  ) async {
    const channel = MethodChannel('test/ecard_deep_link');
    final nativeCalls = <String>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      nativeCalls.add(call.method);
      if (call.method == 'consumePendingRoute') return 'pay';
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final service = EcardDeepLinkService(channel: channel);
    addTearDown(service.dispose);
    var opened = 0;

    service.initialize();
    await tester.pump();
    service.setOpenPayHandler(() async => opened += 1);
    await tester.pump();

    expect(opened, 1);
    expect(nativeCalls, ['consumePendingRoute', 'acknowledgePendingRoute']);
  });
}
