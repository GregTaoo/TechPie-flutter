import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:techpie/features/campus_card/domain/ports/platform_ports.dart';
import 'package:techpie/features/campus_card/platform/system_ports.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('iOS payment success uses the native notification haptic', () async {
    const channel = MethodChannel('club.geekpie.pay/haptics');
    MethodCall? received;
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      received = call;
      return null;
    });
    addTearDown(() {
      debugDefaultTargetPlatformOverride = null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    await SystemHapticsPort().play(HapticEvent.success);

    expect(received?.method, 'paymentSuccess');
  });

  test('Android payment success uses a strong two-part fallback', () async {
    final calls = <MethodCall>[];
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'HapticFeedback.vibrate') calls.add(call);
      return null;
    });
    addTearDown(() {
      debugDefaultTargetPlatformOverride = null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    });

    await SystemHapticsPort().play(HapticEvent.success);

    expect(calls, hasLength(2));
    expect(calls[0].arguments, 'HapticFeedbackType.heavyImpact');
    expect(calls[1].arguments, 'HapticFeedbackType.mediumImpact');
  });
}
