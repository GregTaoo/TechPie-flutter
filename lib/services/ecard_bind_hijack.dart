import 'package:flutter/services.dart';

import '../utils/platform.dart';

/// What the DNS-only tunnel for the bind-code flow is doing right now.
enum EcardBindHijackStatus {
  /// No implementation on this platform (iOS, desktop, web).
  unsupported,

  /// The platform can host it (Android, OHOS), and no tunnel is up.
  inactive,

  /// The tunnel is answering DNS for [EcardBindHijackService.host].
  active,

  /// The user refused the system VPN consent dialog.
  denied;

  static EcardBindHijackStatus parse(Object? value) => switch (value) {
    'active' => EcardBindHijackStatus.active,
    'denied' => EcardBindHijackStatus.denied,
    _ => EcardBindHijackStatus.inactive,
  };
}

/// The platform tunnel, as the service facade sees it — a seam for callers that
/// cannot start a real `VpnService` (tests, and every non-Android platform).
abstract interface class EcardBindHijackPort {
  Future<EcardBindHijackStatus> start();
  Future<void> stop();
  Future<EcardBindHijackStatus> status();
}

/// The platform tunnel that redirects one host name and leaves the rest alone.
///
/// `EcardBindVpnService` (Android) and `EcardBindVpnAbility` (OHOS) answer only
/// DNS for [EcardBindHijackService.host] with [EcardBindHijackService.targetIp];
/// TCP still goes out the ordinary network, so this does not proxy anything the
/// mini program or the exchange request actually send. It applies to every app,
/// not to a list of them.
final class EcardBindHijackService implements EcardBindHijackPort {
  static const _channel = MethodChannel('techpie/ecard_bind');

  /// The campus host the bind service is served under, and the address the
  /// tunnel answers with.
  static const host = 'ecard.shanghaitech.edu.cn';
  static const targetIp = '119.78.254.196';

  /// Android hosts the tunnel in a `VpnService`, OHOS in a `VpnExtensionAbility`
  /// (see ohos/entry/src/main/ets/ecardbind). Both answer the same three calls
  /// on the same channel, so the flow above them is one.
  static bool get _hostsTunnel => isAndroid() || isOhos();

  /// Nothing is filtered by package name: every app's name resolution goes
  /// through the tunnel while it is up. The code is read in the mini program and
  /// the exchange request is this app's, but neither is worth betting the hijack
  /// on — a list stops covering whichever app makes the first lookup, and breaks
  /// outright when an app's package name changes.
  static const Map<String, Object?> _arguments = <String, Object?>{
    'host': host,
    'ip': targetIp,
  };

  @override
  Future<EcardBindHijackStatus> start() async {
    if (!_hostsTunnel) return EcardBindHijackStatus.unsupported;
    try {
      return EcardBindHijackStatus.parse(
        await _channel.invokeMethod<String>('start', _arguments),
      );
    } on MissingPluginException {
      return EcardBindHijackStatus.unsupported;
    } on PlatformException {
      return EcardBindHijackStatus.inactive;
    }
  }

  @override
  Future<void> stop() async {
    if (!_hostsTunnel) return;
    try {
      await _channel.invokeMethod<void>('stop');
    } on MissingPluginException {
      // No host implementation: there is nothing to stop.
    } on PlatformException {
      // Same: the tunnel is gone either way.
    }
  }

  @override
  Future<EcardBindHijackStatus> status() async {
    if (!_hostsTunnel) return EcardBindHijackStatus.unsupported;
    try {
      return EcardBindHijackStatus.parse(
        await _channel.invokeMethod<String>('status'),
      );
    } on MissingPluginException {
      return EcardBindHijackStatus.unsupported;
    } on PlatformException {
      return EcardBindHijackStatus.inactive;
    }
  }
}
