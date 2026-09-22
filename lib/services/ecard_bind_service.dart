import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../features/campus_card/core/errors/app_failure.dart';
import '../features/campus_card/data/auth/ecard_bind_code_client.dart';
import '../features/campus_card/domain/models/auth_models.dart';
import 'ecard_bind_hijack.dart';

/// An OPENID read out of a bind code, with the channel the code belongs to.
final class RedeemedOpenId {
  const RedeemedOpenId(this.openId, this.channel);

  final String openId;
  final EcardOpenIdChannel channel;
}

/// What this device can currently see of the bind path: whether the tunnel is
/// up, what the eCard host resolves to *from this process*, and whether the bind
/// service answers over it.
///
/// The resolver answer is the one that matters: a tunnel that is up but not
/// carrying this app's lookups looks exactly like a working one until a code is
/// redeemed.
final class EcardBindDiagnosis {
  const EcardBindDiagnosis({
    required this.status,
    required this.addresses,
    this.lookupError,
    this.health,
    this.healthError,
  });

  final EcardBindHijackStatus status;

  /// Addresses [EcardBindHijackService.host] resolves to here.
  final List<String> addresses;
  final String? lookupError;
  final EcardBindHealth? health;
  final String? healthError;

  /// The host points at the bind service rather than at the campus itself.
  bool get routesToBindService =>
      addresses.contains(EcardBindHijackService.targetIp);

  /// The bind service answered, and said so itself.
  ///
  /// A status code alone cannot tell the mirror apart from whatever else may be
  /// listening on that host: the service answers `{"ok": true, "codes": 0}`, and
  /// anything whose body is not that is not the bind service.
  bool get reachable {
    final response = health;
    if (response == null || response.status != 200) return false;
    try {
      final Object? decoded = jsonDecode(response.body);
      return decoded is Map<String, Object?> && decoded['ok'] == true;
    } on FormatException {
      return false;
    }
  }

  /// The health line: the status, the service's own verdict, and the JSON it
  /// actually answered with, because "HTTP 200" on its own has already been
  /// misleading once.
  String get healthLine {
    if (healthError case final error?) return error;
    final response = health;
    if (response == null) return '未检查';
    final body = response.body.trim();
    final shown = body.length > 120 ? '${body.substring(0, 117)}…' : body;
    final verdict = reachable ? '绑定服务正常' : '响应异常';
    return 'HTTP ${response.status}${shown.isEmpty ? '' : ' $shown'}（$verdict）';
  }
}

/// Everything the eCard page needs for the code-based path: turn the DNS tunnel
/// on, redeem the code, turn it off again.
///
/// It stores nothing itself — `CampusCardService.connect` stays the only writer
/// of the OPENID — and it does not decide when to stop the tunnel, because that
/// depends on whether the caller is done with the mini program.
final class EcardBindService extends ChangeNotifier {
  EcardBindService({
    EcardBindHijackPort? hijack,
    EcardBindCodeClient? client,
    Future<List<String>> Function(String host)? resolve,
  }) : _hijack = hijack ?? EcardBindHijackService(),
       _client = client ?? EcardBindCodeClient(),
       _resolve = resolve ?? _resolveWithPlatform;

  final EcardBindHijackPort _hijack;
  final EcardBindCodeClient _client;
  final Future<List<String>> Function(String host) _resolve;
  EcardBindHijackStatus _status = EcardBindHijackStatus.inactive;

  EcardBindHijackStatus get status => _status;
  bool get hijackActive => _status == EcardBindHijackStatus.active;

  Future<EcardBindHijackStatus> refreshStatus() async =>
      _record(await _hijack.status());

  Future<EcardBindHijackStatus> startHijack() async =>
      _record(await _hijack.start());

  Future<void> stopHijack() async {
    await _hijack.stop();
    _record(await _hijack.status());
  }

  Future<RedeemedOpenId> redeem(String code) async {
    final result = await _client.exchange(code);
    return RedeemedOpenId(result.openId, result.channel);
  }

  /// Never throws: every failure is reported as part of the result, because the
  /// caller is showing this to a user who is trying to find out what is wrong.
  Future<EcardBindDiagnosis> diagnose() async {
    final status = await refreshStatus();

    List<String> addresses = const <String>[];
    String? lookupError;
    try {
      addresses = await _resolve(EcardBindHijackService.host);
    } catch (error) {
      lookupError = _describe(error);
    }

    EcardBindHealth? health;
    String? healthError;
    try {
      health = await _client.fetchHealth();
    } catch (error) {
      healthError = _describe(error);
    }

    return EcardBindDiagnosis(
      status: status,
      addresses: addresses,
      lookupError: lookupError,
      health: health,
      healthError: healthError,
    );
  }

  static String _describe(Object error) =>
      error is AppFailure ? error.safeMessage : '$error';

  static Future<List<String>> _resolveWithPlatform(String host) async => [
    for (final address in await InternetAddress.lookup(host)) address.address,
  ];

  EcardBindHijackStatus _record(EcardBindHijackStatus status) {
    if (_status != status) {
      _status = status;
      notifyListeners();
    }
    return status;
  }
}
