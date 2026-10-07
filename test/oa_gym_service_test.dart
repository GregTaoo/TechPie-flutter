import 'dart:async';
import 'dart:convert';

import 'package:flutter_secure_storage_ohos/flutter_secure_storage_ohos.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:techpie/models/oa_gym.dart';
import 'package:techpie/models/third_party_account.dart';
import 'package:techpie/models/user_session.dart';
import 'package:techpie/services/auth_service.dart';
import 'package:techpie/services/debug_logger.dart';
import 'package:techpie/services/http_client.dart';
import 'package:techpie/services/oa_gym_service.dart';
import 'package:techpie/services/storage_service.dart';
import 'package:techpie/services/third_party_auth_service.dart';
import 'package:techpie/services/uni_auth_service.dart';

void main() {
  test('queries availability through TechPie backend with CASTGC payload',
      () async {
    final fixture = await _serviceFixture();
    final requests = <Uri>[];
    final client = _FakeClient((request) async {
      requests.add(request.url);
      expect(request.url.host, anyOf('techpie.geekpie.club', 'localhost'));
      expect(request.url.path, '/api/oa/gym/availability');
      expect(request.headers['Content-Type'], contains('application/json'));

      final body = jsonDecode(await request.finalize().bytesToString())
          as Map<String, dynamic>;
      expect(body['auth']['tgc'], 'tgc-value');
      expect(body['auth']['cookies'], 'happyVoyage=happy; CASTGC=tgc-value');
      expect(body['sports'], ['badminton']);
      expect(body['date'], '2026-05-23');
      expect(body['startSlot'], 8);
      expect(body['endSlot'], 8);
      return _jsonResponse({
        'success': true,
        'data': [
          {
            'sport': 'badminton',
            'date': '2026-05-23',
            'timeSlot': 8,
            'availableCourts': [1, 3],
            'totalCourts': 6,
          }
        ],
      });
    });

    final service = OaGymService(
      fixture.auth,
      fixture.storage,
      fixture.tpAuth,
      client: client,
    );
    final result = await service.checkAvailability(
      sports: {OaSport.badminton},
      date: '2026-05-23',
      startSlot: 8,
      endSlot: 8,
    );

    expect(result, hasLength(1));
    expect(result.single.availableCourts, [1, 3]);
    expect(requests.single.host, isNot(contains('shanghaitech.edu.cn')));
  });

  test('loads metadata and searches courts through TechPie backend', () async {
    final fixture = await _serviceFixture();
    final paths = <String>[];
    final client = _FakeClient((request) async {
      paths.add(request.url.path);
      expect(request.url.host, anyOf('techpie.geekpie.club', 'localhost'));
      final body = jsonDecode(await request.finalize().bytesToString())
          as Map<String, dynamic>;
      expect(body['auth']['tgc'], 'tgc-value');

      if (request.url.path == '/api/oa/gym/metadata') {
        return _jsonResponse({
          'success': true,
          'data': {
            'venues': {
              '所有场地': 'all',
              '室内羽毛球场': 'badminton_group',
              '羽毛球场地 １ 号（东馆）': '13',
            },
            'allVenues': {
              '羽毛球场地 １ 号（东馆）': '13',
            },
            'timeSlots': {
              '18:00-19:00': '8',
            },
          },
        });
      }

      expect(request.url.path, '/api/oa/gym/search');
      expect(body['startDate'], '2026-05-23');
      expect(body['endDate'], '2026-05-23');
      expect(body['venueNames'], ['羽毛球场地 １ 号（东馆）']);
      expect(body['timeRanges'], ['18:00-19:00']);
      return _jsonResponse({
        'success': true,
        'data': [
          {
            'venue': '羽毛球场地 １ 号（东馆）',
            'timeRange': '18:00-19:00',
            'rows': [
              [
                '1',
                '',
                '2026-05-23',
                '',
                '',
                '',
                '已通过',
                'User',
                '',
                '2026-05-24',
              ],
            ],
          }
        ],
      });
    });

    final service = OaGymService(
      fixture.auth,
      fixture.storage,
      fixture.tpAuth,
      client: client,
    );
    final result = await service.searchCourts(
      startDate: '2026-05-23',
      endDate: '2026-05-23',
      venueNames: {'室内羽毛球场'},
      timeRanges: const ['18:00-19:00'],
    );

    expect(result, hasLength(1));
    expect(result.single.venue, '羽毛球场地 １ 号（东馆）');
    expect(result.single.rows.single[6], '已通过');
    expect(paths, ['/api/oa/gym/metadata', '/api/oa/gym/search']);
  });

  test('books courts through TechPie backend', () async {
    final fixture = await _serviceFixture();
    final client = _FakeClient((request) async {
      expect(request.url.path, '/api/oa/gym/book');
      final body = jsonDecode(await request.finalize().bytesToString())
          as Map<String, dynamic>;
      expect(body['auth']['tgc'], 'tgc-value');
      expect(body['booking']['sport'], 'badminton');
      expect(body['booking']['studentId'], '20240001');
      expect(body['booking']['userName'], 'User');
      expect(body['booking']['phone'], '13800000000');
      return _jsonResponse({
        'success': true,
        'data': {
          'success': true,
          'message': '羽毛球 羽毛球场地1号 18:00-19:00 预约成功',
        },
      });
    });

    final service = OaGymService(
      fixture.auth,
      fixture.storage,
      fixture.tpAuth,
      client: client,
    );
    final result = await service.bookCourt(
      sport: OaSport.badminton,
      date: '2026-05-23',
      timeSlot: 8,
      courtNumber: 1,
      playersCount: 2,
    );

    expect(result.success, isTrue);
    expect(result.message, contains('预约成功'));
  });

  test(
      'shared courts use physical availability and never expose the unused court',
      () async {
    final fixture = await _serviceFixture();
    final slots = <int>[];
    final client = _FakeClient((request) async {
      final body = jsonDecode(await request.finalize().bytesToString())
          as Map<String, dynamic>;
      expect((body['sports'] as List).toSet(), {'tennis', 'pickleball'});
      expect(body['startSlot'], body['endSlot']);
      final slot = body['startSlot'] as int;
      slots.add(slot);
      return _jsonResponse({
        'success': true,
        'data': [
          {
            'sport': 'tennis',
            'date': '2026-10-08',
            'timeSlot': slot,
            'availableCourts': [1, 3],
          },
          // Even an old backend returning the bogus OA leaf must not expose it.
          {
            'sport': 'pickleball',
            'date': '2026-10-08',
            'timeSlot': slot,
            'availableCourts': [1, 2],
          },
        ],
      });
    });
    final service = OaGymService(
      fixture.auth,
      fixture.storage,
      fixture.tpAuth,
      client: client,
    );
    final progress = <int>[];
    final result = await service.checkAvailability(
      sports: {OaSport.tennis, OaSport.pickleball},
      date: '2026-10-08',
      startSlot: 8,
      endSlot: 9,
      onProgress: (data) => progress.add(data.length),
    );
    expect(slots, [8, 9]);
    expect(progress, [2, 4]);
    expect(
      result.where((row) => row.sport == OaSport.tennis).first.availableCourts,
      [1, 3, 4],
    );
    expect(
      result.where((row) => row.sport == OaSport.tennis).first.totalCourts,
      4,
    );
    expect(
      result
          .where((row) => row.sport == OaSport.pickleball)
          .first
          .availableCourts,
      [1, 2],
    );
    expect(oaCourtForSport(OaSport.pickleball, 2).label, contains('网球场1号'));
    expect(
      oaCourtsForSport(OaSport.pickleball).map((court) => court.physicalKey),
      ['pickleball|1', 'tennis|1'],
    );
  });

  test('booking shared courts submits the original OA category and number',
      () async {
    final fixture = await _serviceFixture();
    final bookings = <Map<String, dynamic>>[];
    final client = _FakeClient((request) async {
      final body = jsonDecode(await request.finalize().bytesToString())
          as Map<String, dynamic>;
      bookings.add((body['booking'] as Map).cast<String, dynamic>());
      return _jsonResponse({
        'success': true,
        'data': {'success': true, 'message': '预约成功'},
      });
    });
    final service = OaGymService(
      fixture.auth,
      fixture.storage,
      fixture.tpAuth,
      client: client,
    );
    await service.bookCourt(
      sport: OaSport.tennis,
      date: '2026-10-08',
      timeSlot: 8,
      courtNumber: 4,
      playersCount: 2,
    );
    await service.bookCourt(
      sport: OaSport.pickleball,
      date: '2026-10-08',
      timeSlot: 8,
      courtNumber: 2,
      playersCount: 2,
    );
    expect(
      bookings.map((booking) => booking['sport']),
      ['pickleball', 'tennis'],
    );
    expect(bookings.map((booking) => booking['courtNumber']), [1, 1]);
    await expectLater(
      service.bookCourt(
        sport: OaSport.pickleball,
        date: '2026-10-08',
        timeSlot: 8,
        courtNumber: 3,
        playersCount: 2,
      ),
      throwsA(isA<OaGymException>()),
    );
    expect(bookings, hasLength(2));
  });

  test(
      'metadata is single flight and OA cookies survive only within the same session',
      () async {
    final fixture = await _serviceFixture();
    final metadata = Completer<http.Response>();
    var metadataCalls = 0;
    var availabilityCalls = 0;
    final client = _FakeClient((request) async {
      final body = jsonDecode(await request.finalize().bytesToString())
          as Map<String, dynamic>;
      if (request.url.path.endsWith('/metadata')) {
        metadataCalls++;
        return metadata.future;
      }
      availabilityCalls++;
      if (availabilityCalls == 1) {
        expect(body['auth']['oaCookies'], 'shkjdx_session=oa-session');
      } else {
        expect(body['auth']['oaCookies'], isNull);
      }
      return _jsonResponse({
        'success': true,
        'data': [
          {
            'sport': 'badminton',
            'date': '2026-10-08',
            'timeSlot': 8,
            'availableCourts': [1],
          },
        ],
      });
    });
    final service = OaGymService(
      fixture.auth,
      fixture.storage,
      fixture.tpAuth,
      client: client,
    );
    final first = service.ensureReady();
    final second = service.ensureReady();
    await Future<void>.delayed(Duration.zero);
    expect(metadataCalls, 1);
    metadata.complete(
      _jsonResponse({
        'success': true,
        'session': {'oaCookies': 'shkjdx_session=oa-session'},
        'data': {
          'venues': {'羽毛球场地1号': '13'},
          'allVenues': {'羽毛球场地1号': '13'},
          'timeSlots': {'18:00-19:00': '8'},
        },
      }),
    );
    await Future.wait([first, second]);
    await service.checkAvailability(
      sports: {OaSport.badminton},
      date: '2026-10-08',
      startSlot: 8,
      endSlot: 8,
    );
    service.clearSession();
    await service.checkAvailability(
      sports: {OaSport.badminton},
      date: '2026-10-08',
      startSlot: 8,
      endSlot: 8,
    );
    expect(service.loading, isFalse);
  });

  test('bulk search uses one request and filters unused pickleball metadata',
      () async {
    final fixture = await _serviceFixture();
    var searches = 0;
    final client = _FakeClient((request) async {
      final body = jsonDecode(await request.finalize().bytesToString())
          as Map<String, dynamic>;
      if (request.url.path.endsWith('/metadata')) {
        return _jsonResponse({
          'success': true,
          'capabilities': {'bulkSearch': true},
          'data': {
            'venues': {
              '所有场地': 'all',
              '网球场1号': '25',
              '网球场2号': '26',
              '网球场3号': '27',
              '匹克球1号场地': '43',
              '匹克球２号场地': '44',
            },
            'allVenues': {'匹克球２号场地': '44'},
            'timeSlots': {'18:00-19:00': '8', '19:00-20:00': '9'},
          },
        });
      }
      searches++;
      expect(
        (body['venueNames'] as List).toSet(),
        {'网球场1号', '网球场2号', '网球场3号', '匹克球1号场地'},
      );
      return _jsonResponse({
        'success': true,
        'data': [
          for (final venue in body['venueNames'] as List)
            for (final time in body['timeRanges'] as List)
              {'venue': venue, 'timeRange': time, 'rows': <dynamic>[]},
        ],
      });
    });
    final service = OaGymService(
      fixture.auth,
      fixture.storage,
      fixture.tpAuth,
      client: client,
    );
    await service.searchCourts(
      startDate: '2026-10-08',
      endDate: '2026-10-08',
      venueNames: {},
      timeRanges: ['18:00-19:00', '19:00-20:00'],
    );
    expect(searches, 1);
    expect(service.venues.keys, isNot(contains('匹克球２号场地')));
  });

  test(
      'legacy searches are bounded and failures are not reported as empty results',
      () async {
    final fixture = await _serviceFixture();
    var active = 0;
    var peak = 0;
    var searches = 0;
    final client = _FakeClient((request) async {
      final body = jsonDecode(await request.finalize().bytesToString())
          as Map<String, dynamic>;
      if (request.url.path.endsWith('/metadata')) {
        return _jsonResponse({
          'success': true,
          'data': {
            'venues': {for (var i = 1; i <= 6; i++) '羽毛球场地$i号': '${12 + i}'},
            'timeSlots': {'18:00-19:00': '8'},
          },
        });
      }
      expect(body['venueNames'], hasLength(1));
      searches++;
      active++;
      if (active > peak) peak = active;
      await Future<void>.delayed(const Duration(milliseconds: 5));
      active--;
      return _jsonResponse({
        'success': true,
        'data': [
          for (final venue in body['venueNames'] as List)
            for (final time in body['timeRanges'] as List)
              {'venue': venue, 'timeRange': time, 'rows': <dynamic>[]},
        ],
      });
    });
    final service = OaGymService(
      fixture.auth,
      fixture.storage,
      fixture.tpAuth,
      client: client,
    );
    await service.searchCourts(
      startDate: '2026-10-08',
      endDate: '2026-10-08',
      venueNames: {},
      timeRanges: ['18:00-19:00'],
    );
    expect(searches, 6);
    expect(peak, 3);
    await expectLater(
      service.searchCourts(
        startDate: '2026-10-09',
        endDate: '2026-10-08',
        venueNames: {},
        timeRanges: [],
      ),
      throwsA(isA<OaGymException>()),
    );
    expect(searches, 6);
  });

  test('missing availability rows are unknown rather than fully booked',
      () async {
    final fixture = await _serviceFixture();
    final client = _FakeClient(
      (request) async => _jsonResponse({'success': true, 'data': <dynamic>[]}),
    );
    final service = OaGymService(
      fixture.auth,
      fixture.storage,
      fixture.tpAuth,
      client: client,
    );
    await expectLater(
      service.checkAvailability(
        sports: {OaSport.tennis},
        date: '2026-10-08',
        startSlot: 8,
        endSlot: 8,
      ),
      throwsA(isA<OaGymException>()),
    );
  });

  test('superseded availability checks stop queued hours without overlapping',
      () async {
    final fixture = await _serviceFixture();
    final firstEntered = Completer<void>();
    final releaseFirst = Completer<void>();
    final slots = <int>[];
    var active = 0;
    var peak = 0;
    var current = true;
    final client = _FakeClient((request) async {
      final body = jsonDecode(await request.finalize().bytesToString())
          as Map<String, dynamic>;
      final slot = body['startSlot'] as int;
      slots.add(slot);
      active++;
      if (active > peak) peak = active;
      if (slots.length == 1) {
        firstEntered.complete();
        await releaseFirst.future;
      }
      active--;
      return _jsonResponse({
        'success': true,
        'data': [
          {
            'sport': 'badminton',
            'date': body['date'],
            'timeSlot': slot,
            'availableCourts': [1],
          },
        ],
      });
    });
    final service = OaGymService(
      fixture.auth,
      fixture.storage,
      fixture.tpAuth,
      client: client,
    );
    final first = service.checkAvailability(
      sports: {OaSport.badminton},
      date: '2026-10-08',
      startSlot: 8,
      endSlot: 10,
      shouldContinue: () => current,
    );
    await firstEntered.future;
    current = false;
    final second = service.checkAvailability(
      sports: {OaSport.badminton},
      date: '2026-10-09',
      startSlot: 9,
      endSlot: 9,
    );
    await Future<void>.delayed(Duration.zero);
    expect(slots, [8]);
    releaseFirst.complete();
    final results = await Future.wait([first, second]);
    expect(slots, [8, 9]);
    expect(peak, 1);
    expect(results.first, hasLength(1));
    expect(results.last.single.date, '2026-10-09');
    expect(service.loading, isFalse);
  });

  test('incomplete search responses are reported instead of hiding failures',
      () async {
    final fixture = await _serviceFixture();
    final client = _FakeClient((request) async {
      if (request.url.path.endsWith('/metadata')) {
        return _jsonResponse({
          'success': true,
          'data': {
            'venues': {'网球场1号': '25'},
            'timeSlots': {'18:00-19:00': '8', '19:00-20:00': '9'},
          },
        });
      }
      return _jsonResponse({
        'success': true,
        'data': [
          {'venue': '网球场1号', 'timeRange': '18:00-19:00', 'rows': <dynamic>[]},
        ],
      });
    });
    final service = OaGymService(
      fixture.auth,
      fixture.storage,
      fixture.tpAuth,
      client: client,
    );
    await expectLater(
      service.searchCourts(
        startDate: '2026-10-08',
        endDate: '2026-10-08',
        venueNames: {'网球场1号'},
        timeRanges: ['18:00-19:00', '19:00-20:00'],
      ),
      throwsA(
        isA<OaGymException>().having(
          (error) => error.message,
          'message',
          contains('结果不完整'),
        ),
      ),
    );
  });

  test('booking timeout warns to check records and never retries submission',
      () async {
    final fixture = await _serviceFixture();
    var calls = 0;
    final client = _FakeClient((request) async {
      calls++;
      throw TimeoutException('simulated transport timeout');
    });
    final service = OaGymService(
      fixture.auth,
      fixture.storage,
      fixture.tpAuth,
      client: client,
    );
    await expectLater(
      service.bookCourt(
        sport: OaSport.tennis,
        date: '2026-10-08',
        timeSlot: 8,
        courtNumber: 1,
        playersCount: 2,
      ),
      throwsA(
        isA<OaGymException>().having(
          (error) => error.message,
          'message',
          contains('先查询预约记录确认结果'),
        ),
      ),
    );
    expect(calls, 1);
  });

  test('throws when eGate binding is absent', () async {
    final fixture = await _serviceFixture(bindEgate: false);
    final client = _FakeClient(
      (request) async => _jsonResponse({
        'success': true,
        'data': const <String, dynamic>{},
      }),
    );
    final service = OaGymService(
      fixture.auth,
      fixture.storage,
      fixture.tpAuth,
      client: client,
    );

    expect(
      () => service.checkAvailability(
        sports: {OaSport.badminton},
        date: '2026-05-23',
        startSlot: 8,
        endSlot: 8,
      ),
      throwsA(isA<OaGymException>()),
    );
  });
}

Future<_Fixture> _serviceFixture({
  bool bindEgate = true,
}) async {
  SharedPreferences.setMockInitialValues({});
  FlutterSecureStorage.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final storage = StorageService(prefs);
  // Primary account is the GeekPie SSO identity session — it carries no
  // CASTGC / CpDaily session at all.
  await storage.saveSession(
    UserSession(
      userId: 'user',
      userName: 'User',
      schoolName: 'School',
      phoneNumber: '13800000000',
      studentId: '',
      createdAt: DateTime.utc(2026),
    ),
  );
  if (bindEgate) {
    await storage.saveThirdPartyAccount(
      ThirdPartyAccount(
        platform: ThirdPartyPlatform.cpdaily,
        account: '20240001',
        sid: '20240001',
        token: 'session',
        raw: const {
          'tgc': 'tgc-value',
          'cookies': 'happyVoyage=happy',
          'sessionToken': 'session',
          'userId': 'user',
          'tenantId': 'tenant',
        },
        boundAt: DateTime.utc(2026),
      ),
    );
  }
  final logger = DebugLogger();
  final httpClient = LoggingHttpClient(logger);
  final uniAuth = UniAuthService();
  final auth = AuthService(storage, httpClient, uniAuth);
  final tpAuth = ThirdPartyAuthService(storage, httpClient);
  await auth.loadSession();
  await tpAuth.initialize();
  return _Fixture(storage, auth, tpAuth);
}

http.Response _jsonResponse(Map<String, dynamic> body) => http.Response(
      jsonEncode(body),
      200,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );

class _Fixture {
  final StorageService storage;
  final AuthService auth;
  final ThirdPartyAuthService tpAuth;

  const _Fixture(this.storage, this.auth, this.tpAuth);
}

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
