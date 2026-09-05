import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';

import '../../core/async_mutex.dart';
import '../../core/errors/app_failure.dart';
import '../../domain/models/auth_models.dart';
import '../../domain/ports/auth_port.dart';
import '../../domain/ports/credential_store.dart';
import '../api/decrypted_http_trace.dart';
import '../api/ecard_api_client.dart';
import '../api/ecard_cipher.dart';
import 'geekpie_ecard_session_issuer.dart';

typedef AuthSecurityCleanup = Future<void> Function();
typedef AuthPinnedIdSerialReader = Future<String?> Function();

final class EcardOpenIdAuthPort implements AuthPort, OpenIdAuthVerifier {
  EcardOpenIdAuthPort({
    Dio? dio,
    EcardSessionIssuer? sessionIssuer,
    EcardCipher? cipher,
    required SessionCredentialStore sessionStore,
    required AuthSecurityCleanup purgeAccountBoundCredentials,
    AuthPinnedIdSerialReader? pinnedIdSerialReader,
    String baseUrl = 'https://ecard.shanghaitech.edu.cn',
  })  : _sessionIssuer = sessionIssuer ?? GeekPieEcardSessionIssuer(
          endpoint: () => Uri.parse('https://techpie.geekpie.club/api/auth/third-party/ecard'),
        ),
        _dio = dio ??
            Dio(
              BaseOptions(
                baseUrl: baseUrl,
                connectTimeout: const Duration(seconds: 6),
                receiveTimeout: const Duration(seconds: 6),
                sendTimeout: const Duration(seconds: 6),
                headers: const {
                  'content-type': 'application/json',
                  'x-requested-with': 'XMLHttpRequest',
                  'session-type': 'uniapp',
                  'isWechatApp': 'true',
                  'orgid': '2',
                },
              ),
            ),
        _cipher = cipher ?? EcardCipher(),
        _sessionStore = sessionStore,
        _purgeAccountBoundCredentials = purgeAccountBoundCredentials,
        _pinnedIdSerialReader = pinnedIdSerialReader {
    installDecryptedHttpTrace(_dio);
  }

  final Dio _dio;
  final EcardSessionIssuer _sessionIssuer;
  final EcardCipher _cipher;
  final SessionCredentialStore _sessionStore;
  final AuthSecurityCleanup _purgeAccountBoundCredentials;
  final AuthPinnedIdSerialReader? _pinnedIdSerialReader;
  final AsyncMutex _sessionMutex = AsyncMutex();
  Future<void>? _sessionRecovery;
  Future<AuthSnapshot>? _sessionRefresh;
  Future<EcardVerifiedIdentity>? _identityVerification;
  final StreamController<AuthSnapshot> _changes =
      StreamController<AuthSnapshot>.broadcast(sync: true);

  @override
  Stream<AuthSnapshot> get changes => _changes.stream;

  /// Reads one complete session while account updates hold the same lock.
  Future<EcardSession?> readSession() => _sessionMutex.protect(() async {
        final cookie = await _sessionStore.readSessionCookie();
        final openId = await _sessionStore.readOpenId();
        final orgId = await _sessionStore.readOrgId();
        if (cookie == null || openId == null || orgId == null) return null;
        return EcardSession(
          sessionCookie: cookie,
          openId: openId,
          orgId: orgId,
          subjectId: sha256.convert(utf8.encode(openId)).toString(),
        );
      });

  @override
  Future<AuthSnapshot> restoreLocal() async {
    final openId = await _sessionStore.readOpenId();
    final orgId = await _sessionStore.readOrgId() ?? '2';
    if (openId == null || openId.isEmpty) {
      return const AuthSnapshot(state: AuthState.signedOut);
    }
    return _authenticated(openId, orgId);
  }

  @override
  Future<AuthSnapshot> restore() {
    final active = _sessionRefresh;
    if (active != null) return active;
    late final Future<AuthSnapshot> operation;
    operation = _sessionMutex.protect(_restoreFromServer).whenComplete(() {
      if (identical(_sessionRefresh, operation)) _sessionRefresh = null;
    });
    _sessionRefresh = operation;
    return operation;
  }

  Future<AuthSnapshot> _restoreFromServer() async {
    final cookie = await _sessionStore.readSessionCookie();
    final openId = await _sessionStore.readOpenId();
    final orgId = await _sessionStore.readOrgId() ?? '2';
    if (openId == null || openId.isEmpty) {
      return _emit(const AuthSnapshot(state: AuthState.signedOut));
    }
    try {
      final identity = await _storedIdentity();
      if (cookie == null || cookie.isEmpty || identity == null) {
        final replacement = await _replaceStoredSession(openId);
        return _authenticated(openId, replacement.orgId);
      }
      await _verifyQuotaIdentity(cookie: cookie, openId: openId, orgId: orgId, expected: identity);
      if (await _sessionStore.readOpenId() != openId) {
        throw const AppFailure(FailureKind.authenticationExpired,
          '校验期间登录账户发生变化，已丢弃本次会话。', code: 'AUTH_SESSION_SUBJECT_CHANGED',);
      }
      return _emit(_authenticated(openId, orgId));
    } on AppFailure catch (failure) {
      if (_isTransient(failure)) return _emit(_authenticated(openId, orgId));
      if (_canRebindStoredOpenId(failure)) {
        try {
          final replacement = await _replaceStoredSession(openId);
          return _authenticated(openId, replacement.orgId);
        } on AppFailure catch (rebindFailure) {
          if (_isTransient(rebindFailure)) return _emit(_authenticated(openId, orgId));
          if (_isIdentityMismatch(rebindFailure)) await _sessionStore.clearSessionCookie();
          rethrow;
        }
      }
      if (_isIdentityMismatch(failure)) await _sessionStore.clearSessionCookie();
      rethrow;
    }
  }

  @override
  Future<AuthSnapshot> signIn(AuthCredential credential) =>
      _sessionMutex.protect(() => _signIn(credential));

  Future<AuthSnapshot> _signIn(AuthCredential credential) async {
    if (credential is! OpenIdAuthCredential) {
      throw const AppFailure(
        FailureKind.invalidInput,
        '当前登录适配器需要 OpenID。',
        code: 'OPENID_CREDENTIAL_REQUIRED',
      );
    }
    credential.validate();
    final openId = credential.openId.trim();
    _emit(const AuthSnapshot(state: AuthState.signingIn));

    final previousOpenId = await _sessionStore.readOpenId();
    try {
      final verified = await _authenticate(credential);
      if (previousOpenId != null && previousOpenId != openId) {
        // Validate the replacement first. A typo must not destroy the current
        // account or its usable offline authorization.
        await _clearSessionAndAccountMaterial();
      } else {
        await _sessionStore.clearSessionCookie();
      }
      await _sessionStore.writeSession(
        sessionCookie: verified.cookie,
        openId: openId,
        orgId: verified.orgId,
        verifiedIdSerial: verified.identity.idSerial,
        verifiedCardId: verified.identity.cardId,
      );
      return _emit(_authenticated(openId, verified.orgId));
    } catch (error) {
      final identityMismatch =
          error is AppFailure && _isIdentityMismatch(error);
      if (identityMismatch && previousOpenId == null) {
        await _clearSessionAndAccountMaterial();
      } else if (identityMismatch && previousOpenId == openId) {
        await _sessionStore.clearSessionCookie();
      }
      final restoredOpenId = await _sessionStore.readOpenId();
      final restoredOrgId = await _sessionStore.readOrgId() ?? '2';
      _emit(
        restoredOpenId == null
            ? const AuthSnapshot(state: AuthState.signedOut)
            : _authenticated(restoredOpenId, restoredOrgId),
      );
      rethrow;
    }
  }

  @override
  Future<void> verifyOpenId(String openId) => _sessionMutex.protect(() async {
        final credential = OpenIdAuthCredential(openId: openId.trim());
        credential.validate();
        await _authenticate(credential);
      });

  Future<_VerifiedEcardSession> _replaceStoredSession(String openId) async {
    final verified = await _authenticate(OpenIdAuthCredential(openId: openId));
    if (await _sessionStore.readOpenId() != openId) {
      throw const AppFailure(
        FailureKind.authenticationExpired,
        '校验期间登录账户发生变化，已丢弃本次会话。',
        code: 'AUTH_SESSION_SUBJECT_CHANGED',
      );
    }
    await _sessionStore.writeSession(
      sessionCookie: verified.cookie,
      openId: openId,
      orgId: verified.orgId,
      verifiedIdSerial: verified.identity.idSerial,
      verifiedCardId: verified.identity.cardId,
    );
    _emit(_authenticated(openId, verified.orgId));
    return verified;
  }

  Future<_VerifiedEcardSession> _authenticate(
    OpenIdAuthCredential credential,
  ) async {
    credential.validate();
    final openId = credential.openId.trim();
    final issued = await _sessionIssuer.issue(openId);
    final issuedIdentity = _EcardIdentity(issued.idSerial, issued.cardId);
    _assertOptionalExpectedIdentity(issuedIdentity, credential);
    final currentOpenId = await _sessionStore.readOpenId();
    final storedIdentity = currentOpenId == openId ? await _storedIdentity() : null;
    final pinned = currentOpenId == openId && storedIdentity == null
        ? await _readPinnedIdSerial() : null;
    if (storedIdentity != null && storedIdentity != issuedIdentity ||
        pinned != null && pinned.isNotEmpty && pinned != issuedIdentity.idSerial) {
      throw const AppFailure(FailureKind.authenticationExpired,
        'eCard 会话身份与本机已验证身份不一致。', code: 'AUTH_PINNED_IDENTITY_MISMATCH',);
    }
    final quota = await _quotaIdentity(cookie: issued.cookie, openId: openId, orgId: issued.orgId);
    if (quota != issuedIdentity) {
      throw const AppFailure(FailureKind.authenticationExpired,
        '登录身份校验不一致，已停止请求。', code: 'AUTH_IDENTITY_MISMATCH',);
    }
    return _VerifiedEcardSession(cookie: issued.cookie, orgId: issued.orgId,
      identity: _verifiedIdentity(openId, issuedIdentity),);
  }

  Future<void> rejectCurrentOnlineSession() =>
      _sessionMutex.protect(_sessionStore.clearSessionCookie);

  Future<EcardVerifiedIdentity> verifyCurrentIdentity() {
    final active = _identityVerification;
    if (active != null) return active;
    late final Future<EcardVerifiedIdentity> operation;
    operation = _sessionMutex.protect(_verifyCurrentIdentity).whenComplete(() {
      if (identical(_identityVerification, operation)) {
        _identityVerification = null;
      }
    });
    _identityVerification = operation;
    return operation;
  }

  Future<EcardVerifiedIdentity> _verifyCurrentIdentity() async {
    final cookie = await _sessionStore.readSessionCookie();
    final openId = await _sessionStore.readOpenId();
    final orgId = await _sessionStore.readOrgId() ?? '2';
    if (cookie == null || openId == null || openId.isEmpty) {
      throw const AppFailure(FailureKind.authenticationExpired,
        '登录身份尚未通过在线校验。', code: 'AUTH_VERIFIED_SESSION_MISSING',);
    }
    try {
      final stored = await _storedIdentity();
      if (stored == null) return (await _replaceStoredSession(openId)).identity;
      return await _verifyQuotaIdentity(cookie: cookie, openId: openId, orgId: orgId, expected: stored);
    } on AppFailure catch (failure) {
      if (_canRebindStoredOpenId(failure)) return (await _replaceStoredSession(openId)).identity;
      if (_isIdentityMismatch(failure)) await _sessionStore.clearSessionCookie();
      rethrow;
    }
  }

  @override
  Future<void> signOut() => _sessionMutex.protect(_signOut);

  Future<void> _signOut() async {
    await _clearSessionAndAccountMaterial();
    _emit(const AuthSnapshot(state: AuthState.signedOut));
  }

  Future<void> dispose() async {
    final verification = _identityVerification;
    if (verification != null) {
      try {
        await verification;
      } catch (_) {
        // A failed identity check is already reflected in the session store.
      }
    }
    final refresh = _sessionRefresh;
    if (refresh != null) {
      try {
        await refresh;
      } catch (_) {
        // Background refresh errors are intentionally non-fatal.
      }
    }
    final recovery = _sessionRecovery;
    if (recovery != null) {
      try {
        await recovery;
      } catch (_) {
        // Runtime shutdown does not surface an already-failed recovery.
      }
    }
    await _changes.close();
  }

  Future<void> handleAuthenticationFailure(int statusCode) {
    if (statusCode != 401) {
      return _sessionMutex.protect(_expireWithoutAutomaticRecovery);
    }
    final active = _sessionRecovery;
    if (active != null) return active;
    late final Future<void> recovery;
    recovery = _sessionMutex.protect(_recoverExpiredSession).whenComplete(() {
      if (identical(_sessionRecovery, recovery)) _sessionRecovery = null;
    });
    _sessionRecovery = recovery;
    return recovery;
  }

  Future<void> _recoverExpiredSession() async {
    final openId = await _sessionStore.readOpenId();
    if (openId == null || openId.isEmpty) {
      await _expireWithoutAutomaticRecovery();
      return;
    }
    await _sessionStore.clearSessionCookie();
    _emit(
      const AuthSnapshot(state: AuthState.expired, message: '登录状态已过期，正在自动恢复。'),
    );
    try {
      await _signIn(OpenIdAuthCredential(openId: openId));
    } catch (_) {
      // signIn already clears the invalid session and emits signedOut. The
      // original business request remains failed and can be retried by the UI.
    }
  }

  Future<void> _expireWithoutAutomaticRecovery() async {
    await _sessionStore.clear();
    _emit(
      const AuthSnapshot(state: AuthState.expired, message: '登录状态已过期，请重新登录。'),
    );
  }

  bool _canRebindStoredOpenId(AppFailure failure) => const {
        'HTTP_401',
        'HTTP_403',
        'AUTH_BUSINESS_REJECTED',
        'INVALID_AUTH_CARDINFO',
        'AUTH_IDENTITY_FIELDS_MISSING',
      }.contains(failure.code);

  bool _isTransient(AppFailure failure) =>
      failure.kind == FailureKind.network ||
      failure.kind == FailureKind.timeout ||
      failure.retryable;

  bool _isIdentityMismatch(AppFailure failure) => const {
        'AUTH_IDENTITY_MISMATCH',
        'AUTH_PINNED_IDENTITY_MISMATCH',
        'AUTH_EXPECTED_IDSERIAL_MISMATCH',
        'AUTH_EXPECTED_CARDID_MISMATCH',
        'AUTH_RESPONSE_IDENTITY_MISMATCH',
        'AUTH_SESSION_SUBJECT_CHANGED',
        'AUTH_RECOVERY_IDENTITY_CHANGED',
      }.contains(failure.code);

  Future<Map<String, Object?>> _encryptedRequest({
    required String method,
    required String path,
    required String cookie,
    required String orgId,
    required Map<String, Object?> payload,
  }) async {
    final envelope = _cipher.encodeRequest(payload);
    try {
      final response = method == 'GET'
          ? await _dio.get<Object?>(
              path,
              queryParameters: {'datajson': envelope},
              options: Options(headers: {'cookie': cookie, 'orgid': orgId}),
            )
          : await _dio.post<Object?>(
              path,
              data: {'datajson': envelope},
              options: Options(headers: {'cookie': cookie, 'orgid': orgId}),
            );
      final decoded = EcardCipher.decodeResponse(response.data);
      final map = requireObjectMap(decoded, context: 'AUTH_RESPONSE');
      if (apiRejected(map)) {
        throw AppFailure(
          FailureKind.server,
          apiMessage(map, fallback: '登录验证失败。'),
          code: 'AUTH_BUSINESS_REJECTED',
        );
      }
      return map;
    } on DioException catch (error) {
      throw _mapDio(error);
    } on FormatException catch (error) {
      throw AppFailure(
        FailureKind.protocol,
        '登录响应格式无效。',
        code: 'AUTH_RESPONSE_INVALID',
        cause: error,
      );
    }
  }

  Future<EcardVerifiedIdentity> _verifyQuotaIdentity({
    required String cookie, required String openId, required String orgId,
    required _EcardIdentity expected,
  }) async {
    final actual = await _quotaIdentity(cookie: cookie, openId: openId, orgId: orgId);
    if (actual != expected) {
      throw const AppFailure(FailureKind.authenticationExpired,
        '当前会话身份与本机已验证身份不一致，已停止请求。', code: 'AUTH_IDENTITY_MISMATCH',);
    }
    return _verifiedIdentity(openId, expected);
  }

  Future<_EcardIdentity> _quotaIdentity({
    required String cookie,
    required String openId,
    required String orgId,
  }) async {
    final response = await _encryptedRequest(
      method: 'POST',
      path: '/virtualcard/openQrcodeQuotaModify',
      cookie: cookie,
      orgId: orgId,
      payload: {'openid': openId},
    );
    return _identityFromCard(_unwrapData(response));
  }

  Future<_EcardIdentity?> _storedIdentity() async {
    final idSerial = await _sessionStore.readVerifiedIdSerial();
    final cardId = await _sessionStore.readVerifiedCardId();
    if (idSerial == null ||
        idSerial.isEmpty ||
        cardId == null ||
        cardId.isEmpty) {
      return null;
    }
    return _EcardIdentity(idSerial, cardId);
  }

  Future<String?> _readPinnedIdSerial() =>
      _pinnedIdSerialReader?.call() ?? Future<String?>.value();

  EcardVerifiedIdentity _verifiedIdentity(
    String openId,
    _EcardIdentity identity,
  ) =>
      EcardVerifiedIdentity(
        subjectId: sha256.convert(utf8.encode(openId)).toString(),
        idSerial: identity.idSerial,
        cardId: identity.cardId,
      );

  Map<String, Object?> _unwrapData(Map<String, Object?> response) {
    final data = response['data'];
    if (data is Map) return requireObjectMap(data, context: 'AUTH_DATA');
    return response;
  }

  _EcardIdentity _identityFromCard(Map<String, Object?> card) {
    final idSerial = card['idserial']?.toString() ?? '';
    final cardId = card['cardid']?.toString() ?? '';
    if (idSerial.isEmpty || cardId.isEmpty) {
      throw const AppFailure(
        FailureKind.protocol,
        '服务未返回完整身份字段。',
        code: 'AUTH_IDENTITY_FIELDS_MISSING',
      );
    }
    return _EcardIdentity(idSerial, cardId);
  }

  void _assertOptionalExpectedIdentity(
    _EcardIdentity actual,
    OpenIdAuthCredential credential,
  ) {
    if (credential.expectedIdSerial != null &&
        credential.expectedIdSerial != actual.idSerial) {
      throw const AppFailure(
        FailureKind.authenticationExpired,
        '登录学号与预期不一致，已停止请求。',
        code: 'AUTH_EXPECTED_IDSERIAL_MISMATCH',
      );
    }
    if (credential.expectedCardId != null &&
        credential.expectedCardId != actual.cardId) {
      throw const AppFailure(
        FailureKind.authenticationExpired,
        '登录卡号与预期不一致，已停止请求。',
        code: 'AUTH_EXPECTED_CARDID_MISMATCH',
      );
    }
  }

  AuthSnapshot _authenticated(String openId, String orgId) => AuthSnapshot(
        state: AuthState.authenticated,
        session: AuthSession(
          subjectId: sha256.convert(utf8.encode(openId)).toString(),
          orgId: orgId,
          maskedIdentity: _maskOpenId(openId),
        ),
      );

  String _maskOpenId(String value) {
    if (value.length <= 8) return '****';
    return '${value.substring(0, 4)}****${value.substring(value.length - 4)}';
  }

  AuthSnapshot _emit(AuthSnapshot value) {
    _changes.add(value);
    return value;
  }

  Future<void> _clearSessionAndAccountMaterial() async {
    await _sessionStore.clear();
    await _purgeAccountBoundCredentials();
  }

  AppFailure _mapDio(DioException error) {
    final status = error.response?.statusCode;
    if (status == 401 || status == 403) {
      return AppFailure(
        FailureKind.authenticationExpired,
        '登录状态已失效。',
        code: 'HTTP_$status',
      );
    }
    return switch (error.type) {
      DioExceptionType.connectionTimeout ||
      DioExceptionType.sendTimeout ||
      DioExceptionType.receiveTimeout =>
        const AppFailure(
          FailureKind.timeout,
          '连接校园支付服务超时。',
          code: 'AUTH_NETWORK_TIMEOUT',
          retryable: true,
        ),
      DioExceptionType.connectionError => const AppFailure(
          FailureKind.network,
          '当前无法连接校园支付服务。',
          code: 'AUTH_NETWORK_UNREACHABLE',
          retryable: true,
        ),
      _ => AppFailure(
          FailureKind.server,
          '校园登录服务暂时不可用。',
          code: status == null ? 'AUTH_HTTP_UNKNOWN' : 'AUTH_HTTP_$status',
          retryable: status == null || status >= 500,
        ),
    };
  }
}

final class _EcardIdentity {
  const _EcardIdentity(this.idSerial, this.cardId);
  final String idSerial;
  final String cardId;

  @override
  bool operator ==(Object other) =>
      other is _EcardIdentity &&
      other.idSerial == idSerial &&
      other.cardId == cardId;

  @override
  int get hashCode => Object.hash(idSerial, cardId);
}

final class _VerifiedEcardSession {
  const _VerifiedEcardSession({
    required this.cookie,
    required this.orgId,
    required this.identity,
  });

  final String cookie;
  final String orgId;
  final EcardVerifiedIdentity identity;
}
