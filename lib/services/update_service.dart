import 'dart:convert';

import 'package:http/http.dart' as http;

import '../utils/product_version.dart';

/// Thrown when the check cannot produce an answer. The message is user-facing,
/// so it says what happened in the user's terms rather than in HTTP's.
class UpdateCheckException implements Exception {
  UpdateCheckException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// A published release that is newer than the running build.
class ReleaseInfo {
  const ReleaseInfo({
    required this.version,
    required this.name,
    required this.notes,
  });

  /// The version the release carries, comparable with the running one.
  final ProductVersion version;

  /// What the release calls itself — `v1.0.1`, `v1.0.1-rc.2`.
  final String name;

  /// The release's changelog, with the pipeline's checksum block removed.
  final String notes;

  @override
  String toString() => 'ReleaseInfo($name)';
}

/// Checks GitHub for a newer release than the one running.
///
/// Deliberately not part of the backend: the answer comes from the releases
/// page a user would look at anyway, so it stays correct even when the API is
/// down, and it needs no account.
class UpdateService {
  UpdateService({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  static const repository = 'HeZeBang/TechPie-flutter';

  /// Where the update button sends the user. `releases/latest` is GitHub's own
  /// redirect to the newest non-prerelease release, so the link stays right as
  /// releases land — and our pipeline never marks a candidate as latest.
  static const latestReleasePage =
      'https://github.com/$repository/releases/latest';

  static Uri get _latestReleaseUri =>
      Uri.https('api.github.com', '/repos/$repository/releases/latest');

  /// The newest published release when it is newer than [current], or null when
  /// the running build is already the newest — which is not a failure, and must
  /// not read like one.
  Future<ReleaseInfo?> checkForUpdate(ProductVersion current) async {
    final http.Response response;
    try {
      response = await _client.get(
        _latestReleaseUri,
        headers: {
          // Pin the API version this payload is read under, and say who is
          // asking: GitHub rejects a request with no user agent.
          'Accept': 'application/vnd.github+json',
          'X-GitHub-Api-Version': '2022-11-28',
          'User-Agent': 'TechPie/$current',
        },
      );
    } catch (error) {
      throw UpdateCheckException('无法连接 GitHub：$error');
    }

    switch (response.statusCode) {
      case 200:
        break;
      case 404:
        // No published release yet: nothing to update to, and nothing broken.
        throw UpdateCheckException('GitHub 上还没有已发布的版本。');
      case 403:
        // Unauthenticated requests are capped at 60 an hour per address.
        throw UpdateCheckException('GitHub 暂时拒绝了请求（可能是请求过于频繁），请稍后再试。');
      default:
        throw UpdateCheckException('GitHub 返回了 HTTP ${response.statusCode}。');
    }

    final Map<String, dynamic> payload;
    try {
      payload = jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
    } catch (_) {
      throw UpdateCheckException('GitHub 的响应无法解析。');
    }

    final tag = (payload['tag_name'] as String? ?? '').trim();
    final title = (payload['name'] as String? ?? '').trim();
    final published =
        ProductVersion.tryParse(tag) ?? ProductVersion.tryParse(title);
    if (published == null) {
      // Better to say we cannot tell than to prompt for an update we do not
      // understand: a wrong prompt is worse than none.
      throw UpdateCheckException('无法识别 GitHub 上的版本号（$tag）。');
    }
    if (!published.isNewerThan(current)) {
      return null;
    }

    return ReleaseInfo(
      version: published,
      name: title.isNotEmpty ? title : tag,
      notes: _changelog(payload['body'] as String? ?? ''),
    );
  }

  static final RegExp _checksumBlock = RegExp(r'\n#+ *SHA-256\b');

  /// `release.yml` writes the changelog and the checksums into one body. A
  /// checksum list is not a changelog, so the block is dropped before the text
  /// reaches a dialog.
  static String _changelog(String body) {
    final match = _checksumBlock.firstMatch(body);
    final changelog = (match == null ? body : body.substring(0, match.start)).trim();
    return changelog.isEmpty ? '（这个版本没有写更新说明。）' : changelog;
  }
}
