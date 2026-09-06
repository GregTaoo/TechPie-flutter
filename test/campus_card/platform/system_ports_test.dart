import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:techpie/features/campus_card/domain/models/feedback_models.dart';
import 'package:techpie/features/campus_card/domain/ports/platform_ports.dart';
import 'package:techpie/features/campus_card/platform/system_ports.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final platform in [TargetPlatform.iOS, TargetPlatform.android]) {
    test('$platform schedules success sound and vibration in one native call',
        () async {
      const channel = MethodChannel('techpie/feedback');
      final calls = <MethodCall>[];
      debugDefaultTargetPlatformOverride = platform;
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return null;
      });
      addTearDown(() {
        debugDefaultTargetPlatformOverride = null;
        messenger.setMockMethodCallHandler(channel, null);
      });
      final port = SystemFeedbackPort();
      await port.play(FeedbackEvent.paymentSuccess);
      expect(calls.single.method, 'play');
      expect(
        calls.single.arguments,
        {'event': 'paymentSuccess', 'sound': true, 'vibration': true},
      );

      await port.setEnabled(
        FeedbackScenario.paymentSuccess,
        FeedbackChannel.sound,
        false,
      );
      await port.play(FeedbackEvent.paymentSuccess);
      expect(
        calls.last.arguments,
        {'event': 'paymentSuccess', 'sound': false, 'vibration': true},
      );
      await port.setEnabled(
        FeedbackScenario.paymentSuccess,
        FeedbackChannel.vibration,
        false,
      );
      await port.play(FeedbackEvent.paymentSuccess);
      expect(calls, hasLength(2));
      final restored = await SystemFeedbackPort()
          .settingsFor(FeedbackScenario.paymentSuccess);
      expect(restored.sound, isFalse);
      expect(restored.vibration, isFalse);

      await port.play(FeedbackEvent.networkDisconnected);
      expect(
        calls.last.arguments,
        {'event': 'networkDisconnected', 'sound': true, 'vibration': true},
      );
      await port.setEnabled(
        FeedbackScenario.networkDisconnected,
        FeedbackChannel.vibration,
        false,
      );
      await port.play(FeedbackEvent.networkDisconnected);
      expect(
        calls.last.arguments,
        {'event': 'networkDisconnected', 'sound': true, 'vibration': false},
      );
    });
  }

  test('other successes stay haptic-only and respect the interaction switch',
      () async {
    final calls = <MethodCall>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      calls.add(call);
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
    );
    final port = SystemFeedbackPort();
    await port.play(FeedbackEvent.success);
    expect(calls, hasLength(2));
    await port.setEnabled(
      FeedbackScenario.interaction,
      FeedbackChannel.vibration,
      false,
    );
    await port.play(FeedbackEvent.selection);
    await port.play(FeedbackEvent.success);
    expect(calls, hasLength(2));
  });
}
