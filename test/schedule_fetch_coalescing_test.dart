import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:techpie/models/third_party_account.dart';
import 'package:techpie/services/auth_service.dart';
import 'package:techpie/services/debug_logger.dart';
import 'package:techpie/services/http_client.dart';
import 'package:techpie/services/schedule_service.dart';
import 'package:techpie/services/storage_service.dart';
import 'package:techpie/services/third_party_auth_service.dart';
import 'package:techpie/services/uni_auth_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Around a login the triggers all fire inside the same second — the binding
  // lands, the session is renewed, a child cookie is minted — and each of them
  // used to start a round of its own: three rounds of three requests for one
  // login. They go through one funnel now, which collapses the burst.
  test('a burst of triggers is one round of requests, not one each', () async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final storage = StorageService(prefs);
    await storage.saveThirdPartyAccount(
      ThirdPartyAccount(
        platform: ThirdPartyPlatform.cpdaily,
        account: '20240001',
        sid: '20240001',
        token: 'session',
        raw: const {'tgc': 'tgc-value'},
        boundAt: DateTime.utc(2026),
      ),
    );

    final logger = DebugLogger();
    final requests = <Uri>[];
    final http = LoggingHttpClient(logger, inner: _RecordingClient(requests));
    final uniAuth = UniAuthService();
    final auth = AuthService(storage, http, uniAuth);
    await auth.loadSession();
    final tpAuth = ThirdPartyAuthService(storage, http);
    await tpAuth.initialize();

    final schedule = ScheduleService(storage, http, auth, tpAuth);
    expect(schedule.semesterInfo, isNull, reason: 'nothing in hand yet');

    // The burst: every one of these notifies the schedule through the same
    // listener, milliseconds apart.
    for (final marker in ['a', 'b', 'c']) {
      await tpAuth.updateRaw(
        ThirdPartyPlatform.cpdaily,
        {'tgc': 'tgc-value', 'cookies': 'CASTGC=$marker'},
      );
    }

    // Past the coalescing window.
    await Future<void>.delayed(const Duration(milliseconds: 900));

    expect(
      requests.length,
      1,
      reason: 'the burst is one round; the client fails on the first request, '
          'so a second round would show up as a second request',
    );
  });
}

/// Counts what was asked for and answers with a failure: this test is about how
/// many rounds are started, not about what comes back.
class _RecordingClient extends http.BaseClient {
  _RecordingClient(this.requests);

  final List<Uri> requests;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add(request.url);
    throw const _Refused();
  }
}

class _Refused implements Exception {
  const _Refused();

  @override
  String toString() => 'SocketException: connection refused';
}
