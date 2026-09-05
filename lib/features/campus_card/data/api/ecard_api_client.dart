import 'dart:async';

import 'package:dio/dio.dart';

import '../../core/async_mutex.dart';
import '../../core/errors/app_failure.dart';
import '../../core/errors/core_error_catalog.dart';
import 'decrypted_http_trace.dart';
import 'ecard_cipher.dart';

final class EcardVerifiedIdentity {
  const EcardVerifiedIdentity({
    required this.subjectId,
    required this.idSerial,
    required this.cardId,
  });

  final String subjectId;
  final String idSerial;
  final String cardId;

  @override
  bool operator ==(Object other) =>
      other is EcardVerifiedIdentity &&
      other.subjectId == subjectId &&
      other.idSerial == idSerial &&
      other.cardId == cardId;

  @override
  int get hashCode => Object.hash(subjectId, idSerial, cardId);
}

final class EcardSession {
  const EcardSession({
    required this.sessionCookie,
    required this.openId,
    required this.orgId,
    required this.subjectId,
  });

  final String sessionCookie;
  final String openId;
  final String orgId;
  final String subjectId;
}

typedef EcardSessionReader = Future<EcardSession?> Function();
typedef EcardIdentityGuard = Future<EcardVerifiedIdentity> Function();
typedef AuthenticationExpiredCallback = FutureOr<void> Function(int statusCode);
typedef IdentityMismatchCallback = FutureOr<void> Function();

abstract interface class EcardTransport {
  Future<Object?> get(
    String path,
    Map<String, Object?> data, {
    bool includeOpenId = true,
  });

  Future<Object?> post(
    String path,
    Map<String, Object?> data, {
    bool includeOpenId = true,
  });

  Future<List<int>> download(String path);

  Future<Object?> getPlain(
    String path,
    Map<String, Object?> query, {
    bool includeOpenId = false,
  });
}

final class EcardApiClient implements EcardTransport {
  EcardApiClient({
    Dio? dio,
    EcardCipher? cipher,
    required EcardSessionReader sessionReader,
    required EcardIdentityGuard identityGuard,
    required AuthenticationExpiredCallback onAuthenticationExpired,
    required IdentityMismatchCallback onIdentityMismatch,
    String baseUrl = 'https://ecard.shanghaitech.edu.cn',
  })  : _cipher = cipher ?? EcardCipher(),
        _sessionReader = sessionReader,
        _identityGuard = identityGuard,
        _onAuthenticationExpired = onAuthenticationExpired,
        _onIdentityMismatch = onIdentityMismatch,
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
                },
              ),
            ) {
    installDecryptedHttpTrace(_dio);
  }

  final Dio _dio;
  final EcardCipher _cipher;
  final EcardSessionReader _sessionReader;
  final EcardIdentityGuard _identityGuard;
  final AuthenticationExpiredCallback _onAuthenticationExpired;
  final IdentityMismatchCallback _onIdentityMismatch;
  final AsyncMutex _requestMutex = AsyncMutex();

  Dio get dioForTesting => _dio;

  void dispose() => _dio.close(force: true);

  @override
  Future<Object?> get(
    String path,
    Map<String, Object?> data, {
    bool includeOpenId = true,
  }) =>
      _withVerifiedIdentity((identity, session) async {
        final request =
            _requestData(data, session, includeOpenId: includeOpenId);
        _validateRequestIdentity(path, request, identity);
        final response = await _sendWithAuthRecovery(
          (credentials) async => _dio.get<Object?>(
            path,
            queryParameters: {'datajson': _cipher.encodeRequest(request)},
            options: Options(
              headers: {
                'cookie': credentials.sessionCookie,
                'orgid': credentials.orgId,
              },
            ),
          ),
          expectedIdentity: identity,
          session: session,
        );
        return _validatedResponse(response.data, identity);
      });

  @override
  Future<Object?> post(
    String path,
    Map<String, Object?> data, {
    bool includeOpenId = true,
  }) =>
      _withVerifiedIdentity((identity, session) async {
        final request =
            _requestData(data, session, includeOpenId: includeOpenId);
        _validateRequestIdentity(path, request, identity);
        final response = await _sendWithAuthRecovery(
          (credentials) async => _dio.post<Object?>(
            path,
            data: {'datajson': _cipher.encodeRequest(request)},
            options: Options(
              headers: {
                'cookie': credentials.sessionCookie,
                'orgid': credentials.orgId,
              },
            ),
          ),
          expectedIdentity: identity,
          session: session,
        );
        return _validatedResponse(response.data, identity);
      });

  @override
  Future<List<int>> download(String path) =>
      _withVerifiedIdentity((identity, session) async {
        final response = await _sendWithAuthRecovery(
          (credentials) async => _dio.get<List<int>>(
            path,
            options: Options(
              responseType: ResponseType.bytes,
              headers: {
                'cookie': credentials.sessionCookie,
                'orgid': credentials.orgId,
              },
            ),
          ),
          expectedIdentity: identity,
          session: session,
        );
        await _assertSessionSubject(identity);
        final data = response.data;
        if (data == null) throw const FormatException('Empty binary response');
        return data;
      });

  @override
  Future<Object?> getPlain(
    String path,
    Map<String, Object?> query, {
    bool includeOpenId = false,
  }) =>
      _withVerifiedIdentity((identity, session) async {
        final request =
            _requestData(query, session, includeOpenId: includeOpenId);
        _validateRequestIdentity(path, request, identity);
        final response = await _sendWithAuthRecovery(
          (credentials) async => _dio.get<Object?>(
            path,
            queryParameters: request,
            options: Options(
              headers: {
                'cookie': credentials.sessionCookie,
                'orgid': credentials.orgId,
              },
            ),
          ),
          expectedIdentity: identity,
          session: session,
        );
        return _validatedResponse(response.data, identity);
      });

  Future<T> _withVerifiedIdentity<T>(
    Future<T> Function(EcardVerifiedIdentity identity, EcardSession session)
        operation,
  ) =>
      _requestMutex.protect(() async {
        final identity = await _identityGuard();
        final session = await _sessionForIdentity(identity);
        return operation(identity, session);
      });

  Map<String, Object?> _requestData(
    Map<String, Object?> data,
    EcardSession session, {
    required bool includeOpenId,
  }) {
    final request = Map<String, Object?>.from(data);
    if (includeOpenId && !request.containsKey('openid')) {
      request['openid'] = session.openId;
    }
    if (request.containsKey('openid') && request['openid'] != session.openId) {
      throw _identityFailure('AUTH_REQUEST_IDENTITY_MISMATCH');
    }
    return request;
  }

  Object? _decode(Object? body) {
    try {
      return EcardCipher.decodeResponse(body);
    } on FormatException catch (error) {
      throw AppFailure(
        FailureKind.protocol,
        '服务返回了无法识别的数据。',
        code: 'ECARD_DECRYPT_FAILED',
        cause: error,
      );
    }
  }

  Future<Response<T>> _sendWithAuthRecovery<T>(
    Future<Response<T>> Function(EcardSession session) send, {
    required EcardSession session,
    required EcardVerifiedIdentity expectedIdentity,
  }) async {
    try {
      return await send(session);
    } on DioException catch (error) {
      if (error.response?.statusCode != 401) {
        throw await _mapDioFailure(error);
      }
      await _onAuthenticationExpired(401);
      if (await _sessionReader() == null) {
        throw await _mapDioFailure(error, notifyAuthentication: false);
      }
      final recoveredIdentity = await _identityGuard();
      if (recoveredIdentity != expectedIdentity) {
        throw _identityFailure('AUTH_RECOVERY_IDENTITY_CHANGED');
      }
      final recoveredSession = await _sessionForIdentity(expectedIdentity);
      try {
        return await send(recoveredSession);
      } on DioException catch (retryError) {
        throw await _mapDioFailure(retryError, notifyAuthentication: false);
      }
    }
  }

  Future<EcardSession> _sessionForIdentity(
    EcardVerifiedIdentity identity,
  ) async {
    final session = await _sessionReader();
    if (session == null || session.subjectId != identity.subjectId) {
      throw _identityFailure('AUTH_SESSION_SUBJECT_CHANGED');
    }
    return session;
  }

  Future<void> _assertSessionSubject(EcardVerifiedIdentity identity) async {
    await _sessionForIdentity(identity);
  }

  Future<Object?> _validatedResponse(
    Object? body,
    EcardVerifiedIdentity identity,
  ) async {
    final decoded = _decode(body);
    await _assertSessionSubject(identity);
    try {
      _validateIdentityFields(decoded, identity);
    } on AppFailure {
      await _onIdentityMismatch();
      rethrow;
    }
    return decoded;
  }

  void _validateIdentityFields(Object? value, EcardVerifiedIdentity identity) {
    if (value is List) {
      for (final item in value) {
        _validateIdentityFields(item, identity);
      }
      return;
    }
    if (value is! Map) return;
    for (final entry in value.entries) {
      final key = entry.key.toString().toLowerCase();
      final fieldValue = entry.value?.toString().trim() ?? '';
      if (key == 'idserial' &&
          fieldValue.isNotEmpty &&
          fieldValue != identity.idSerial) {
        throw _identityFailure('AUTH_RESPONSE_IDENTITY_MISMATCH');
      }
      if (key == 'cardid' &&
          fieldValue.isNotEmpty &&
          fieldValue != identity.cardId) {
        throw _identityFailure('AUTH_RESPONSE_IDENTITY_MISMATCH');
      }
      _validateIdentityFields(entry.value, identity);
    }
  }

  void _validateRequestIdentity(
    String path,
    Map<String, Object?> request,
    EcardVerifiedIdentity identity,
  ) {
    if (path == '/bind/wechatBind') return;
    final idSerial = request['idserial']?.toString().trim();
    final cardId = request['cardid']?.toString().trim();
    if ((idSerial != null &&
            idSerial.isNotEmpty &&
            idSerial != identity.idSerial) ||
        (cardId != null && cardId.isNotEmpty && cardId != identity.cardId)) {
      throw _identityFailure('AUTH_REQUEST_IDENTITY_MISMATCH');
    }
  }

  AppFailure _identityFailure(String code) => AppFailure(
        FailureKind.authenticationExpired,
        '服务端身份校验不一致，已丢弃本次响应。请稍后重新登录。',
        code: code,
      );

  Future<AppFailure> _mapDioFailure(
    DioException error, {
    bool notifyAuthentication = true,
  }) async {
    final status = error.response?.statusCode;
    if (status == 401 || status == 403) {
      if (notifyAuthentication) await _onAuthenticationExpired(status!);
      return AppFailure(
        FailureKind.authenticationExpired,
        status == 403 ? '登录状态无权访问，请重新登录。' : '登录状态已过期，请重新登录。',
        code: 'HTTP_$status',
      );
    }
    return switch (error.type) {
      DioExceptionType.connectionTimeout ||
      DioExceptionType.sendTimeout ||
      DioExceptionType.receiveTimeout =>
        const AppFailure(
          FailureKind.timeout,
          '连接校园支付服务超时，请重试。',
          code: 'NETWORK_TIMEOUT',
          retryable: true,
        ),
      DioExceptionType.connectionError => const AppFailure(
          FailureKind.network,
          '当前无法连接校园支付服务。',
          code: 'NETWORK_UNREACHABLE',
          retryable: true,
        ),
      DioExceptionType.cancel => const AppFailure(
          FailureKind.cancelled,
          '请求已取消。',
          code: 'REQUEST_CANCELLED',
        ),
      _ => AppFailure(
          FailureKind.server,
          '校园支付服务暂时不可用。',
          code: status == null ? 'HTTP_UNKNOWN' : 'HTTP_$status',
          retryable: status == null || status >= 500,
        ),
    };
  }
}

Map<String, Object?> requireObjectMap(
  Object? value, {
  required String context,
}) {
  if (value is Map) {
    return value.map((key, value) => MapEntry(key.toString(), value));
  }
  if (value is String && CoreErrorCatalog.isCoreCode(value)) {
    final code = value.trim();
    if (code == 'CORE10007' || code == 'CORE10008') {
      return {'success': true, 'message': code};
    }
    throw AppFailure(
      FailureKind.server,
      CoreErrorCatalog.resolve(code),
      code: code,
    );
  }
  throw AppFailure(
    FailureKind.protocol,
    '服务返回了无法识别的数据。',
    code: 'INVALID_$context',
  );
}

List<Object?> requireList(Object? value, {required String context}) {
  if (value is List) return List<Object?>.from(value);
  if (value is String && CoreErrorCatalog.isCoreCode(value)) {
    final code = value.trim();
    if (code == 'CORE10007' || code == 'CORE10008') return const [];
    throw AppFailure(
      FailureKind.server,
      CoreErrorCatalog.resolve(code),
      code: code,
    );
  }
  throw AppFailure(
    FailureKind.protocol,
    '服务返回了无法识别的数据。',
    code: 'INVALID_$context',
  );
}

bool apiSuccess(Map<String, Object?> map) {
  final value = map['success'];
  return value == true ||
      value == 1 ||
      value?.toString().toLowerCase() == 'true';
}

bool apiRejected(Map<String, Object?> map) =>
    map.containsKey('success') && !apiSuccess(map);

String apiMessage(Map<String, Object?> map, {String fallback = '请求失败'}) {
  final raw = map['message']?.toString().trim();
  if (raw == null || raw.isEmpty) return fallback;
  return CoreErrorCatalog.resolve(raw);
}
