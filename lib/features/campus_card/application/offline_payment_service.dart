import 'package:clock/clock.dart';

import '../core/errors/app_failure.dart';
import '../data/api/qr_payload_codec.dart';
import '../data/crypto/sm2_offline_crypto.dart';
import '../domain/models/offline_models.dart';
import '../domain/ports/offline_ports.dart';
import '../domain/ports/platform_ports.dart';

typedef OfflineDeviceCodeReader = Future<String?> Function();

final class OfflinePaymentService {
  OfflinePaymentService({
    required OfflineCredentialRepository credentials,
    required OfflineAuthorizationRemotePort remote,
    required ConnectivityPort connectivity,
    required Sm2OfflineCrypto crypto,
    required OfflineDeviceCodeReader deviceCodeReader,
    Clock? clock,
    Duration transientRetryDelay = const Duration(milliseconds: 180),
  })  : _credentials = credentials,
        _remote = remote,
        _connectivity = connectivity,
        _crypto = crypto,
        _deviceCodeReader = deviceCodeReader,
        _clock = clock ?? const Clock(),
        _transientRetryDelay = transientRetryDelay;

  final OfflineCredentialRepository _credentials;
  final OfflineAuthorizationRemotePort _remote;
  final ConnectivityPort _connectivity;
  final Sm2OfflineCrypto _crypto;
  final OfflineDeviceCodeReader _deviceCodeReader;
  final Clock _clock;
  final Duration _transientRetryDelay;
  final Map<String, Future<OfflineAuthorization>> _activations = {};
  final Map<String, Future<OfflineAuthorization>> _renewals = {};

  Future<OfflineAuthorization?> mostRecentAuthorization() async {
    final deviceCode = await _deviceCodeReader();
    if (deviceCode == null || deviceCode.isEmpty) return null;
    return _credentials.readMostRecent(deviceCode: deviceCode);
  }

  Future<OfflineAuthorizationView> status(String cardId) async {
    final deviceCode = await _requireDeviceCode();
    final authorization = await _credentials.read(
      cardId,
      deviceCode: deviceCode,
    );
    if (authorization == null) {
      return const OfflineAuthorizationView(
        state: OfflineAuthorizationState.missingCredential,
      );
    }
    final key = await _credentials.readPrivateKey(
      cardId,
      deviceCode: deviceCode,
    );
    if (key == null) {
      return OfflineAuthorizationView(
        state: OfflineAuthorizationState.missingCredential,
        authorization: authorization,
      );
    }
    if (authorization.isLimited && authorization.remaining == 0) {
      return OfflineAuthorizationView(
        state: OfflineAuthorizationState.exhausted,
        authorization: authorization,
      );
    }
    if (_isExpired(authorization.expiresOn)) {
      return OfflineAuthorizationView(
        state: OfflineAuthorizationState.expired,
        authorization: authorization,
      );
    }
    if (_renewalDue(authorization.expiresOn)) {
      return OfflineAuthorizationView(
        state: OfflineAuthorizationState.renewalDue,
        authorization: authorization,
      );
    }
    return OfflineAuthorizationView(
      state: OfflineAuthorizationState.active,
      authorization: authorization,
    );
  }

  Future<OfflineAuthorization> activate({required String cardId}) {
    final active = _activations[cardId];
    if (active != null) return active;
    late final Future<OfflineAuthorization> operation;
    operation = _activate(cardId).whenComplete(() {
      if (identical(_activations[cardId], operation)) {
        _activations.remove(cardId);
      }
    });
    _activations[cardId] = operation;
    return operation;
  }

  Future<OfflineAuthorization> _activate(String cardId) async {
    final deviceCode = await _requireDeviceCode();
    final keyPair = _crypto.generateKeyPair();
    final request = OfflineActivationRequest(
      cardId: cardId,
      deviceCode: deviceCode,
      publicKeyCompressed: keyPair.publicKeyCompressed,
      privateKeyHex: keyPair.privateKeyHex,
    );
    // Connectivity APIs can briefly report `none` while iOS is rebuilding its
    // path. The actual HTTPS request is authoritative. A transient failure is
    // retried once with the exact same key pair so the activation remains
    // idempotent from the device's point of view.
    final response = await _retryTransient(() => _remote.activate(request));
    final authorization = OfflineAuthorization(
      cardId: cardId,
      deviceCode: deviceCode,
      publicKeyCompressed: keyPair.publicKeyCompressed,
      authorInfo: response.authorInfo,
      totalUses: response.totalUses,
      used: 0,
      updatedAt: _clock.now().toUtc(),
      expiresOn: response.expiresOn,
    );
    await _credentials.install(
      authorization: authorization,
      privateKeyHex: keyPair.privateKeyHex,
    );
    return authorization;
  }

  Future<OfflineAuthorization> renew(
    String cardId, {
    bool force = false,
  }) async {
    final deviceCode = await _requireDeviceCode();
    final authorization = await _credentials.read(
      cardId,
      deviceCode: deviceCode,
    );
    if (authorization == null) {
      throw const AppFailure(
        FailureKind.credentialMissing,
        '此设备没有可续期的离线付款授权。',
        code: 'OFFLINE_CREDENTIAL_MISSING',
      );
    }
    if (!force && !_renewalDue(authorization.expiresOn)) return authorization;
    if (!await _connectivity.isOnline()) return authorization;
    final active = _renewals[cardId];
    if (active != null) return active;
    late final Future<OfflineAuthorization> operation;
    operation = _renewOnline(authorization).whenComplete(() {
      if (identical(_renewals[cardId], operation)) {
        _renewals.remove(cardId);
      }
    });
    _renewals[cardId] = operation;
    return operation;
  }

  Future<OfflineAuthorization> _renewOnline(
    OfflineAuthorization authorization,
  ) async {
    final response = await _retryTransient(() => _remote.renew(authorization));
    if (response == null) return authorization;
    final renewed = authorization.copyWith(
      authorInfo: response.authorInfo,
      totalUses: response.totalUses,
      replaceTotalUses: true,
      used: 0,
      updatedAt: _clock.now().toUtc(),
      expiresOn: response.expiresOn,
    );
    await _credentials.updateAuthorization(renewed, resetUsage: true);
    return renewed;
  }

  Future<T> _retryTransient<T>(Future<T> Function() request) async {
    try {
      return await request();
    } on AppFailure catch (failure) {
      final transient = failure.kind == FailureKind.network ||
          failure.kind == FailureKind.timeout ||
          failure.retryable;
      if (!transient) rethrow;
      if (_transientRetryDelay > Duration.zero) {
        await Future<void>.delayed(_transientRetryDelay);
      }
      return request();
    }
  }

  Future<OfflineQrCode> generate(String cardId) async {
    final view = await status(cardId);
    if (view.state == OfflineAuthorizationState.expired) {
      throw const AppFailure(
        FailureKind.offlineAuthorizationExpired,
        '离线付款授权已过期，请联网续期。',
        code: 'OFFLINE_AUTHORIZATION_EXPIRED',
      );
    }
    if (view.state == OfflineAuthorizationState.exhausted) {
      throw const AppFailure(
        FailureKind.offlineQuotaExhausted,
        '已达到离线付款码最大使用次数，之后的交易可能失效。请联网续期离线码。',
        code: 'OFFLINE_QUOTA_EXHAUSTED',
      );
    }
    final deviceCode = await _requireDeviceCode();
    final privateKey = await _credentials.readPrivateKey(
      cardId,
      deviceCode: deviceCode,
    );
    if (privateKey == null) {
      throw const AppFailure(
        FailureKind.credentialMissing,
        '此设备缺少离线付款私钥。',
        code: 'OFFLINE_PRIVATE_KEY_MISSING',
      );
    }
    // Reserve and persist before any QR payload is calculated or exposed.
    final reserved = await _credentials.reserveUse(
      cardId,
      deviceCode: deviceCode,
    );
    final generatedAt = _clock.now().toUtc();
    final hex = _crypto.buildOfflineQrHex(
      authorInfo: reserved.authorInfo,
      deviceCode: reserved.deviceCode,
      privateKeyHex: privateKey,
      now: generatedAt,
    );
    return OfflineQrCode(
      hex: hex,
      payload: QrPayloadCodec.offline(hex),
      reservedUse: reserved.used,
      generatedAt: generatedAt,
    );
  }

  Future<void> removeFromThisDevice(String cardId) async {
    final deviceCode = await _requireDeviceCode();
    await _credentials.read(cardId, deviceCode: deviceCode);
    await _credentials.remove(cardId);
  }

  Future<void> removeAllFromThisDevice() => _credentials.removeAll();

  Future<String> _requireDeviceCode() async {
    final deviceCode = await _deviceCodeReader();
    if (deviceCode == null || deviceCode.isEmpty) {
      throw const AppFailure(
        FailureKind.authenticationExpired,
        '登录状态缺少离线设备标识，请重新登录。',
        code: 'OFFLINE_DEVICE_CODE_MISSING',
      );
    }
    return deviceCode;
  }

  bool _isExpired(DateTime? expiration) {
    if (expiration == null) return false;
    final now = _dateOnly(_clock.now().toUtc());
    return expiration.isBefore(now);
  }

  bool _renewalDue(DateTime? expiration) {
    if (expiration == null) return true;
    final threshold = _dateOnly(
      _clock.now().toUtc(),
    ).add(const Duration(days: 4));
    return !expiration.isAfter(threshold);
  }

  DateTime _dateOnly(DateTime value) =>
      DateTime.utc(value.year, value.month, value.day);
}
