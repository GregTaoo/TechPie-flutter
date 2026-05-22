import 'dart:async';
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:techpie/models/oa_gym.dart';
import 'package:techpie/models/user_session.dart';
import 'package:techpie/services/auth_service.dart';
import 'package:techpie/services/debug_logger.dart';
import 'package:techpie/services/http_client.dart';
import 'package:techpie/services/oa_gym_service.dart';
import 'package:techpie/services/storage_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('uses TechPie CASTGC to establish OA session and query availability',
      () async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final storage = StorageService(prefs);
    await storage.saveSession(
      UserSession(
        sessionToken: 'session',
        tgc: 'tgc-value',
        userId: 'user',
        userName: 'User',
        schoolName: 'School',
        tenantId: 'tenant',
        phoneNumber: '13800000000',
        cookies: 'happyVoyage=happy',
        studentId: '20240001',
        createdAt: DateTime.utc(2026),
      ),
    );
    final auth = AuthService(storage, LoggingHttpClient(DebugLogger()));
    await auth.loadSession();

    final client = _FakeClient((request) async {
      if (request.url.host == 'ids.shanghaitech.edu.cn') {
        expect(request.headers['Cookie'], contains('CASTGC=tgc-value'));
        return http.Response(
          '',
          302,
          headers: {
            'location': 'https://oa.shanghaitech.edu.cn/sso?ticket=ST-123',
          },
        );
      }
      if (request.url.host == 'oa.shanghaitech.edu.cn' &&
          request.url.path == '/sso') {
        return http.Response(
          '',
          302,
          headers: {
            'set-cookie':
                'shkjdx_session=session-value; Path=/, loginidweaver=16293; Path=/',
            'location':
                'https://oa.shanghaitech.edu.cn/workflow/request/AddRequest.jsp',
          },
        );
      }
      if (request.url.path.endsWith('AddRequest.jsp')) {
        return http.Response('ok', 200);
      }
      if (request.url.path.endsWith('CustomTreeBrowserAjax.jsp')) {
        final body = await request.finalize().bytesToString();
        expect(request.headers['Cookie'],
            contains('shkjdx_session=session-value'));
        if (body.contains('pid=63_1')) {
          return _utf8Response(
            '[{"name":"室内羽毛球场","id":"63_4","isParent":"true"}]',
            200,
          );
        }
        return _utf8Response(
          '[{"name":"羽毛球场地1号"},{"name":"羽毛球场地3号"}]',
          200,
        );
      }
      return http.Response('not found', 404);
    });

    final service = OaGymService(auth, storage, client: client);
    final result = await service.checkAvailability(
      sports: {OaSport.badminton},
      date: '2026-05-23',
      startSlot: 8,
      endSlot: 8,
    );

    expect(result, hasLength(1));
    expect(result.single.availableCourts, [1, 3]);
  });
}

http.Response _utf8Response(String body, int statusCode) => http.Response.bytes(
      utf8.encode(body),
      statusCode,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );

class _FakeClient extends http.BaseClient {
  _FakeClient(this._handler);

  final Future<http.Response> Function(http.BaseRequest request) _handler;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final response = await _handler(request);
    return http.StreamedResponse(
      Stream<List<int>>.value(response.bodyBytes),
      response.statusCode,
      headers: response.headers,
      request: request,
    );
  }
}
