import 'dart:convert';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:techpie/features/campus_card/core/errors/app_failure.dart';
import 'package:techpie/features/campus_card/data/auth/ecard_openid_auth_port.dart';
import 'package:techpie/features/campus_card/data/auth/geekpie_ecard_session_issuer.dart';
import 'package:techpie/features/campus_card/data/mock/in_memory_ports.dart';
import 'package:techpie/features/campus_card/data/storage/flutter_secure_credential_store.dart';
import 'package:techpie/features/campus_card/domain/models/auth_models.dart';

const _openid = 'SYNTHETIC_OPENID_ACCOUNT_A';
const _endpoint = '/api/auth/third-party/ecard';
const _quota = '/virtualcard/openQrcodeQuotaModify';

void main() {
  for (final operation in ['login', 'verify', 'missingCookie', 'missingIdentity', 'recover401']) {
    test('TechPie acquires the session for $operation', () async {
      final rig = await _Rig.create();
      addTearDown(rig.auth.dispose);
      switch (operation) {
        case 'login': await rig.auth.signIn(const OpenIdAuthCredential(openId: _openid));
        case 'verify': await rig.auth.verifyOpenId(_openid);
        case 'missingCookie':
          await rig.store.clearSessionCookie();
          await rig.auth.restore();
        case 'missingIdentity':
          await rig.secure.deleteAll({'geekpay.auth.verified_idserial', 'geekpay.auth.verified_cardid'});
          await rig.auth.restore();
        case 'recover401': await rig.auth.handleAuthenticationFailure(401);
      }
      expect(rig.adapter.paths, [_endpoint, _quota]);
      final request = rig.adapter.requests.first;
      expect(request.method, 'POST');
      expect(request.uri.host, 'techpie.invalid');
      expect(request.data, {'method': 'wechat_openid', 'openid': _openid});
      expect(request.followRedirects, isFalse);
      expect(await rig.store.readSessionCookie(), operation == 'verify' ? 'JSESSIONID=initial' : 'JSESSIONID=issued');
      expect(await rig.store.readVerifiedIdSerial(), 'STUDENT-A');
    });
  }
  test('local restore has no network requirement', () async {
    final rig = await _Rig.create();
    addTearDown(rig.auth.dispose);
    expect((await rig.auth.restoreLocal()).state, AuthState.authenticated);
    expect(rig.adapter.paths, isEmpty);
  });
  test('verified restoration checks quota without issuing another session', () async {
    final rig = await _Rig.create();
    addTearDown(rig.auth.dispose);
    await rig.auth.restore();
    await rig.auth.verifyCurrentIdentity();
    expect(rig.adapter.paths, [_quota, _quota]);
  });
  test('transient verification failure preserves local session', () async {
    final rig = await _Rig.create();
    addTearDown(rig.auth.dispose);
    rig.adapter.quotaStatus = 503;
    expect((await rig.auth.restore()).state, AuthState.authenticated);
    expect(await rig.store.readSessionCookie(), 'JSESSIONID=initial');
    expect(rig.adapter.paths, [_quota]);
  });
  test('expired quota verification recovers through TechPie', () async {
    final rig = await _Rig.create();
    addTearDown(rig.auth.dispose);
    rig.adapter.quotaStatus = 401;
    await rig.auth.restore();
    expect(rig.adapter.paths, [_quota, _endpoint, _quota]);
    expect(await rig.store.readSessionCookie(), 'JSESSIONID=issued');
  });
  test('issuer failure cannot fall back to campus session acquisition', () async {
    final rig = await _Rig.create();
    addTearDown(rig.auth.dispose);
    rig.adapter.issuerStatus = 503;
    await expectLater(rig.auth.signIn(const OpenIdAuthCredential(openId: _openid)), throwsA(isA<AppFailure>()));
    expect(rig.adapter.paths, [_endpoint]);
    expect(await rig.store.readSessionCookie(), 'JSESSIONID=initial');
  });
  test('quota identity cannot replace the trusted issuer identity', () async {
    final rig = await _Rig.create();
    addTearDown(rig.auth.dispose);
    rig.adapter.otherIdentity = true;
    await expectLater(rig.auth.signIn(const OpenIdAuthCredential(openId: _openid)), throwsA(isA<AppFailure>()));
    expect(rig.adapter.paths, [_endpoint, _quota]);
    expect(await rig.store.readVerifiedIdSerial(), 'STUDENT-A');
    expect(await rig.store.readSessionCookie(), isNull);
  });
  test('expected identity mismatch stops before business requests', () async {
    final rig = await _Rig.create();
    addTearDown(rig.auth.dispose);
    await expectLater(rig.auth.signIn(const OpenIdAuthCredential(openId: _openid, expectedIdSerial: 'WRONG')), throwsA(isA<AppFailure>()));
    expect(rig.adapter.paths, [_endpoint]);
  });
  test('invalid OPENID sends no request', () async {
    final rig = await _Rig.create();
    addTearDown(rig.auth.dispose);
    await expectLater(rig.auth.signIn(const OpenIdAuthCredential(openId: 'short')), throwsFormatException);
    expect(rig.adapter.paths, isEmpty);
  });
  test('logout clears local identity and account material', () async {
    final rig = await _Rig.create();
    addTearDown(rig.auth.dispose);
    await rig.auth.signOut();
    expect(rig.purges, 1);
    expect(await rig.store.readOpenId(), isNull);
    expect(await rig.store.readSessionCookie(), isNull);
    expect((await rig.auth.restore()).state, AuthState.signedOut);
    expect(rig.adapter.paths, isEmpty);
  });
}

class _Rig {
  _Rig(this.store, this.adapter, this.secure);
  final InMemorySecureCredentialStore secure;
  final SecureSessionCredentialStore store;
  final _Adapter adapter;
  late EcardOpenIdAuthPort auth;
  int purges = 0;
  static Future<_Rig> create() async {
    final secure = InMemorySecureCredentialStore();
    final store = SecureSessionCredentialStore(secure);
    await store.writeSession(sessionCookie: 'JSESSIONID=initial', openId: _openid, orgId: '2',
      verifiedIdSerial: 'STUDENT-A', verifiedCardId: 'CARD-A',);
    final adapter = _Adapter();
    Dio dio() => Dio(BaseOptions(baseUrl: 'https://campus.invalid'))..httpClientAdapter = adapter;
    final rig = _Rig(store, adapter, secure);
    rig.auth = EcardOpenIdAuthPort(dio: dio(), sessionStore: store,
      sessionIssuer: GeekPieEcardSessionIssuer(dio: dio(), endpoint: () => Uri.parse('https://techpie.invalid$_endpoint')),
      purgeAccountBoundCredentials: () async { rig.purges++; },);
    return rig;
  }
}
class _Adapter implements HttpClientAdapter {
  final requests = <RequestOptions>[];
  List<String> get paths => requests.map((request) => request.uri.path).toList();
  int issuerStatus = 200;
  int quotaStatus = 200;
  bool otherIdentity = false;
  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    requests.add(options);
    final Map<String, Object?> body;
    final int status;
    switch (options.uri.path) {
      case _endpoint:
        status = issuerStatus;
        body = {'success': true, 'data': {'sid': 'STUDENT-A', 'token': 'JSESSIONID=issued',
          'raw': {'idserial': 'STUDENT-A', 'cardid': 'CARD-A', 'cookies': 'JSESSIONID=issued', 'orgid': '2'},},};
      case _quota:
        status = quotaStatus;
        quotaStatus = 200;
        body = {'success': true, 'data': {'idserial': otherIdentity ? 'STUDENT-B' : 'STUDENT-A', 'cardid': 'CARD-A'}};
      default: throw StateError('Unexpected session acquisition endpoint');
    }
    return ResponseBody.fromString(jsonEncode(body), status, headers: {Headers.contentTypeHeader: ['application/json']});
  }
  @override
  void close({bool force = false}) {}
}
