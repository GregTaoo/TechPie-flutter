import 'dart:convert';

import 'api_base_url.dart';
import 'http_client.dart';
import 'live_classroom_cache.dart';
import 'storage_service.dart';
import 'third_party_auth_service.dart';

enum LiveCamera {
  screen('屏幕'),
  panorama('全景'),
  closeup('特写');

  const LiveCamera(this.label);

  final String label;
}

class LiveException implements Exception {
  const LiveException(this.message);

  final String message;

  @override
  String toString() => message;
}

class LiveClient {
  LiveClient(this.auth, this.storage, this.http);

  final ThirdPartyAuthService auth;
  final StorageService storage;
  final LoggingHttpClient http;

  String? get _owner {
    final account = auth.cpdailyNode.account;
    return account == null ? null : '${account.sid}:${account.account}';
  }

  Future<Uri> byClassroom(
    String classroom,
    LiveCamera camera, {
    required String semesterId,
    required String fingerprint,
  }) async {
    final owner = _owner;
    if (owner == null) throw const LiveException('请先绑定校园账号');
    final generation = storage.liveCacheGeneration;
    final baseUrl = apiBaseUrl(storage);
    bool current() =>
        _owner == owner &&
        storage.liveCacheGeneration == generation &&
        apiBaseUrl(storage) == baseUrl;
    try {
      final id = await LiveClassroomCache(storage).resolve(
        scope: jsonEncode([baseUrl, owner, semesterId, generation]),
        fingerprint: fingerprint,
        classroom: classroom,
        isCurrent: current,
        fetch: () async {
          final data = await _request('classrooms', {'semesterId': semesterId});
          final raw = data['classrooms'];
          if (raw is! Map<String, dynamic> ||
              raw.values
                  .any((v) => v != 'unknown' && !(v is int && v > 0 && v <= 9007199254740991))) {
            throw const LiveException('直播教室信息返回异常');
          }
          return raw.cast<String, Object>();
        },
      );
      if (id == null) throw const LiveException('暂未找到该课程对应的直播教室');
      if (!current()) throw const LiveException('账号已变化，请重新进入直播');
      return await byId(id, camera);
    } on StateError catch (error) {
      throw LiveException(error.message);
    }
  }

  Future<Uri> byId(int id, LiveCamera camera) async {
    final data = await _request('url', {'id': id, 'camera': camera.name});
    final raw = data['url'];
    final uri = raw is String ? Uri.tryParse(raw) : null;
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host != 'live.shanghaitech.edu.cn' ||
        uri.userInfo.isNotEmpty ||
        uri.fragment.isNotEmpty) {
      throw const LiveException('直播播放链接返回异常');
    }
    return uri;
  }

  Future<Map<String, dynamic>> _request(String endpoint, Map<String, Object> input) async {
    final owner = _owner;
    final generation = storage.liveCacheGeneration;
    final baseUrl = apiBaseUrl(storage);
    if (owner == null) throw const LiveException('请先绑定校园账号');
    final initialTgc = auth.cpdailyNode.rawFields['tgc'];
    for (var attempt = 0; attempt < 2; attempt++) {
      if (_owner != owner ||
          storage.liveCacheGeneration != generation ||
          apiBaseUrl(storage) != baseUrl) {
        throw const LiveException('账号已变化，请重新进入直播');
      }
      final tgc = auth.cpdailyNode.rawFields['tgc'];
      if (tgc is! String || tgc.isEmpty) throw const LiveException('请重新登录校园账号');
      final response = await http
          .post(
            Uri.parse('$baseUrl/live/$endpoint'),
            headers: {'Content-Type': 'application/json; charset=UTF-8'},
            body: jsonEncode({...input, 'tgc': tgc}),
            tag: 'liveRequest',
          )
          .timeout(Duration(seconds: endpoint == 'classrooms' ? 65 : 30));
      if (_owner != owner ||
          storage.liveCacheGeneration != generation ||
          apiBaseUrl(storage) != baseUrl) {
        throw const LiveException('账号已变化，请重新进入直播');
      }
      if (response.statusCode == 401 && attempt == 0) {
        final refreshed =
            auth.cpdailyNode.rawFields['tgc'] != initialTgc || await auth.refreshCastgc();
        if (!refreshed) throw const LiveException('校园登录已失效，请重新登录校园账号');
        continue;
      }
      final body = jsonDecode(response.body);
      if (body is! Map<String, dynamic>) throw const LiveException('直播服务返回异常');
      if (response.statusCode != 200 || body['success'] != true) {
        throw LiveException(body['error'] is String ? body['error'] as String : '直播服务暂不可用');
      }
      final data = body['data'];
      if (data is! Map<String, dynamic>) throw const LiveException('直播服务返回异常');
      return data;
    }
    throw const LiveException('校园登录已失效，请重新登录校园账号');
  }
}
