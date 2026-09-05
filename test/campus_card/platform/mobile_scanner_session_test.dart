import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:techpie/features/campus_card/platform/scanner/mobile_scanner_session.dart';

void main() {
  test('permission transitions serialize camera start, stop and restart',
      () async {
    final controller = _DelayedScannerController();
    final session = MobileScannerSession(controller: controller);
    final start = session.start();
    await Future<void>.delayed(Duration.zero);
    final stop = session.stop();
    final restart = session.start();
    expect(controller.events, ['start']);
    controller.permission.complete();
    await Future.wait([start, stop, restart]);
    expect(controller.events, ['start', 'stop', 'start']);
    await session.dispose();
    expect(controller.events, ['start', 'stop', 'start', 'stop', 'dispose']);
  });

  test('duplicate starts share a running camera and disposal waits for startup',
      () async {
    final controller = _DelayedScannerController();
    final session = MobileScannerSession(controller: controller);
    final first = session.start();
    final second = session.start();
    final dispose = session.dispose();
    await Future<void>.delayed(Duration.zero);
    expect(controller.events, ['start']);
    controller.permission.complete();
    await Future.wait([first, second, dispose, session.dispose()]);
    expect(controller.events, ['start', 'stop', 'dispose']);
    await expectLater(session.start(), throwsStateError);
  });
}

class _DelayedScannerController extends MobileScannerController {
  _DelayedScannerController() : super(autoStart: false);

  final events = <String>[];
  final permission = Completer<void>();

  @override
  Future<void> start({CameraFacing? cameraDirection}) async {
    events.add('start');
    await permission.future;
  }

  @override
  Future<void> stop() async => events.add('stop');

  @override
  // This fake never acquires the native resources released by the superclass.
  // ignore: must_call_super
  Future<void> dispose() async => events.add('dispose');
}
