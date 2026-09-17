import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:techpie/services/webview_bridge.dart';

/// Records what the bridge asked the host to do, and answers like the app.
class _FakeHost implements BhMobileSdkHost {
  _FakeHost({
    this.files = const <BhMobileSdkFile>[],
    this.throwOnPick = false,
    this.pickedDate,
    this.throwOnPickDate = false,
    this.noDatePicker = false,
  });

  final List<BhMobileSdkFile> files;
  final bool throwOnPick;
  final String? pickedDate;
  final bool throwOnPickDate;
  final bool noDatePicker;

  @override
  bool get hasDatePicker => !noDatePicker;
  final List<String> calls = <String>[];
  BhMobileSdkPickerSource? lastSource;
  int? lastLimit;
  BhMobileSdkDateRequest? lastDateRequest;
  String? lastTitle;
  bool? lastNavBarVisible;
  String? lastUrl;

  @override
  Future<List<BhMobileSdkFile>> pickFiles(
    BhMobileSdkPickerSource source,
    int limit,
  ) async {
    calls.add('pick');
    lastSource = source;
    lastLimit = limit;
    if (throwOnPick) throw StateError('no picker');
    return files;
  }

  @override
  Future<String?> pickDateTime(BhMobileSdkDateRequest request) async {
    calls.add('pickDate');
    lastDateRequest = request;
    if (throwOnPickDate) throw UnsupportedError('date picker');
    return pickedDate;
  }

  @override
  void openUrl(String url) {
    calls.add('openUrl');
    lastUrl = url;
  }

  @override
  void closeWebView() => calls.add('close');

  @override
  void setNavBarVisible(bool visible) {
    calls.add('setNavBar');
    lastNavBarVisible = visible;
  }

  @override
  void setTitle(String title) {
    calls.add('setTitle');
    lastTitle = title;
  }
}

/// Stands in for the webview: records the scripts the bridge runs in the page.
class _ScriptRecorder {
  final List<String> scripts = <String>[];

  Future<void> call(String script) async {
    scripts.add(script);
  }
}

Map<String, dynamic> _response(List<String> scripts) {
  expect(scripts, hasLength(1));
  final script = scripts.single;
  const prefix = 'window.__techPieHandleBhMobileSdkResponse(';
  expect(script.startsWith(prefix), isTrue, reason: script);
  expect(script.endsWith(');'), isTrue, reason: script);
  final literal = script.substring(prefix.length, script.length - 2);
  final payload = jsonDecode(literal) as String;
  return jsonDecode(payload) as Map<String, dynamic>;
}

void main() {
  late _FakeHost host;
  late _ScriptRecorder recorder;
  late BhMobileSdkBridge bridge;

  setUp(() {
    host = _FakeHost();
    recorder = _ScriptRecorder();
    bridge = BhMobileSdkBridge(host: host, runJavaScript: recorder.call);
  });

  test('a pick request hands the page the bytes the host read', () async {
    host = _FakeHost(
      files: <BhMobileSdkFile>[
        BhMobileSdkFile(
          name: 'proof.png',
          mime: 'image/png',
          bytes: Uint8List.fromList(<int>[1, 2, 3]),
          path: '/tmp/proof.png',
        ),
      ],
    );
    bridge = BhMobileSdkBridge(host: host, runJavaScript: recorder.call);

    await bridge.handleMessage(
      jsonEncode(<String, dynamic>{
        'type': 'bh_mobile_sdk',
        'action': 'takePhoto',
        'requestId': 'bh-7',
        'source': 'camera',
        'limit': 3,
      }),
    );

    expect(host.lastSource, BhMobileSdkPickerSource.camera);
    expect(host.lastLimit, 3);
    final response = _response(recorder.scripts);
    expect(response['requestId'], 'bh-7');
    final result = (response['result'] as List<dynamic>).single as Map<String, dynamic>;
    expect(result['name'], 'proof.png');
    expect(result['mime'], 'image/png');
    expect(result['size'], 3);
    expect(result['base64'], base64Encode(<int>[1, 2, 3]));
    expect(result['path'], '/tmp/proof.png');
  });

  test('a page whose platform has no picker is told to fall back', () async {
    host = _FakeHost(throwOnPick: true);
    bridge = BhMobileSdkBridge(host: host, runJavaScript: recorder.call);

    await bridge.handleMessage(
      jsonEncode(<String, dynamic>{
        'type': 'bh_mobile_sdk',
        'action': 'takePhoto',
        'requestId': 'bh-1',
      }),
    );

    final response = _response(recorder.scripts);
    expect(response['requestId'], 'bh-1');
    expect(response['unsupported'], isTrue);
    expect(response.containsKey('result'), isFalse);
  });

  test('the requested limit is clamped to what the picker can return', () async {
    await bridge.handleMessage(
      jsonEncode(<String, dynamic>{
        'type': 'bh_mobile_sdk',
        'action': 'takePhoto',
        'requestId': 'bh-2',
        'limit': 99,
      }),
    );
    expect(host.lastLimit, 9);
    expect(host.lastSource, BhMobileSdkPickerSource.gallery);
  });

  test('host chrome and navigation actions reach the host', () async {
    for (final message in <Map<String, dynamic>>[
      <String, dynamic>{'type': 'bh_mobile_sdk', 'action': 'setTitle', 'title': '学生请假'},
      <String, dynamic>{'type': 'bh_mobile_sdk', 'action': 'setNavBar', 'visible': false},
      <String, dynamic>{'type': 'bh_mobile_sdk', 'action': 'openUrl', 'url': 'https://example.com/f.pdf'},
      <String, dynamic>{'type': 'bh_mobile_sdk', 'action': 'close'},
    ]) {
      await bridge.handleMessage(jsonEncode(message));
    }

    expect(host.lastTitle, '学生请假');
    expect(host.lastNavBarVisible, isFalse);
    expect(host.lastUrl, 'https://example.com/f.pdf');
    expect(host.calls, <String>['setTitle', 'setNavBar', 'openUrl', 'close']);
    expect(recorder.scripts, isEmpty);
  });





  test('a date request answers the page with the picked value', () async {
    host = _FakeHost(pickedDate: '2026-09-18');
    bridge = BhMobileSdkBridge(host: host, runJavaScript: recorder.call);

    await bridge.handleMessage(
      jsonEncode(<String, dynamic>{
        'type': 'bh_mobile_sdk',
        'action': 'pickDate',
        'requestId': 'bh-9',
        'mode': 'datetime',
        'value': '2026-09-01 08:30',
        'min': '2026-01-01',
      }),
    );

    expect(host.lastDateRequest?.mode, BhMobileSdkDateMode.dateTime);
    expect(host.lastDateRequest?.value, '2026-09-01 08:30');
    expect(host.lastDateRequest?.min, '2026-01-01');
    expect(host.lastDateRequest?.max, isNull);
    final response = _response(recorder.scripts);
    expect(response['requestId'], 'bh-9');
    expect(response['value'], '2026-09-18');
  });

  test('a dismissed date picker leaves the field alone', () async {
    host = _FakeHost();
    bridge = BhMobileSdkBridge(host: host, runJavaScript: recorder.call);

    await bridge.handleMessage(
      jsonEncode(<String, dynamic>{
        'type': 'bh_mobile_sdk',
        'action': 'pickDate',
        'requestId': 'bh-10',
        'mode': 'date',
      }),
    );

    final response = _response(recorder.scripts);
    expect(response['cancelled'], isTrue);
    expect(response.containsKey('value'), isFalse);
  });

  test('a host without a date picker says so instead of hanging the page', () async {
    host = _FakeHost(throwOnPickDate: true);
    bridge = BhMobileSdkBridge(host: host, runJavaScript: recorder.call);

    await bridge.handleMessage(
      jsonEncode(<String, dynamic>{
        'type': 'bh_mobile_sdk',
        'action': 'pickDate',
        'requestId': 'bh-11',
        'mode': 'time',
      }),
    );

    final response = _response(recorder.scripts);
    expect(response['unsupported'], isTrue);
    expect(host.lastDateRequest?.mode, BhMobileSdkDateMode.time);
  });

  test('the page learns at load whether the host has a date picker', () async {
    await bridge.handleMessage(
      jsonEncode(<String, dynamic>{
        'type': 'bh_mobile_sdk',
        'action': 'capabilities',
        'requestId': 'bh-12',
      }),
    );
    expect(_response(recorder.scripts)['datePicker'], isTrue);

    recorder.scripts.clear();
    host = _FakeHost(noDatePicker: true);
    bridge = BhMobileSdkBridge(host: host, runJavaScript: recorder.call);
    await bridge.handleMessage(
      jsonEncode(<String, dynamic>{
        'type': 'bh_mobile_sdk',
        'action': 'capabilities',
        'requestId': 'bh-13',
      }),
    );
    expect(_response(recorder.scripts)['datePicker'], isFalse);
  });

  test('messages from other page traffic are ignored', () async {
    for (final message in <String>[
      'not json at all',
      jsonEncode(<String, dynamic>{'type': 'ping'}),
      jsonEncode(<String, dynamic>{'type': 'bh_mobile_sdk', 'action': 'takePhoto'}),
      jsonEncode(<String, dynamic>{'type': 'bh_mobile_sdk', 'action': 'probe'}),
    ]) {
      await bridge.handleMessage(message);
    }

    expect(host.calls, isEmpty);
    expect(recorder.scripts, isEmpty);
  });

  test('resuming the page runs its webviewOnResume handlers', () async {
    await bridge.notifyResumed();

    expect(recorder.scripts.single, contains('__techPieHandleWebviewResume'));
    expect(host.calls, isEmpty);
  });
}
