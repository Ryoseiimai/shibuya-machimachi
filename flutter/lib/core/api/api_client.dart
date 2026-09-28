// HTTP API（作る・のぞく・参加する の3つだけ）。SPEC.md §3.2。
// Origin ヘッダは付けない（サーバーは Origin で拒否しない）。URL・本文・secret をログに出さない。
import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/room_models.dart';

/// API の失敗。reason はサーバーの reason（rate_limited / invalid_nickname / not_found / expired /
/// full / invalid_invite / invalid_request / unauthorized）か、クライアント側の network / invalid_response。
class ApiException implements Exception {
  const ApiException(this.reason, {this.status, this.message});
  final String reason;
  final int? status;

  /// 429 のときだけサーバーが付ける日本語の文言。
  final String? message;

  @override
  String toString() => 'ApiException($reason, status: $status)';
}

abstract interface class ApiClient {
  /// POST /api/rooms
  Future<CreateRoomResult> createRoom(String nickname);

  /// GET /api/rooms/{id}/preview?invite= → ホストのニックネーム
  Future<String> preview(String roomId, String invite);

  /// POST /api/rooms/{id}/join。参加＝guest の同意（guest.approved=true になる）。
  Future<JoinResult> join(String roomId, String invite, String nickname);

  /// 招待 URL（本番ドメインで組み立てる）。
  String inviteUrl(String roomId, String inviteToken);

  /// WebSocket の URL（secret を含むので、ログ・クラッシュレポートに出さない）。
  Uri wsUri(String roomId, Role role, String secret);
}

class HttpApiClient implements ApiClient {
  HttpApiClient({required this.baseUrl, http.Client? client, this.timeout = const Duration(seconds: 15)})
      : _client = client ?? http.Client();

  final String baseUrl;
  final http.Client _client;
  final Duration timeout;

  Uri _u(String path, [Map<String, String>? q]) => Uri.parse(baseUrl).replace(path: path, queryParameters: q);

  Future<Map<String, Object?>> _send(Future<http.Response> Function() call) async {
    http.Response res;
    try {
      res = await call().timeout(timeout);
    } on TimeoutException {
      throw const ApiException('network');
    } catch (_) {
      // 例外の文言には URL が入りうるので捨てる。
      throw const ApiException('network');
    }
    Object? body;
    try {
      body = jsonDecode(utf8.decode(res.bodyBytes));
    } catch (_) {
      body = null;
    }
    final m = body is Map ? body.cast<String, Object?>() : const <String, Object?>{};
    if (res.statusCode == 200 && m['ok'] == true) return m;
    final reason = m['reason'];
    throw ApiException(
      reason is String ? reason : (m['error'] == 'not found' ? 'not_found' : 'invalid_response'),
      status: res.statusCode,
      message: m['message'] is String ? m['message'] as String : null,
    );
  }

  String _need(Map<String, Object?> m, String key) {
    final v = m[key];
    if (v is String && v.isNotEmpty) return v;
    throw const ApiException('invalid_response');
  }

  static const _json = {'content-type': 'application/json; charset=utf-8'};

  @override
  Future<CreateRoomResult> createRoom(String nickname) async {
    final m = await _send(() => _client.post(_u('/api/rooms'), headers: _json, body: jsonEncode({'nickname': nickname})));
    return CreateRoomResult(roomId: _need(m, 'roomId'), hostSecret: _need(m, 'hostSecret'), inviteToken: _need(m, 'inviteToken'));
  }

  @override
  Future<String> preview(String roomId, String invite) async {
    final m = await _send(() => _client.get(_u('/api/rooms/$roomId/preview', {'invite': invite})));
    return _need(m, 'hostNickname');
  }

  @override
  Future<JoinResult> join(String roomId, String invite, String nickname) async {
    final m = await _send(() => _client.post(_u('/api/rooms/$roomId/join'),
        headers: _json, body: jsonEncode({'invite': invite, 'nickname': nickname})));
    return JoinResult(guestSecret: _need(m, 'guestSecret'));
  }

  @override
  String inviteUrl(String roomId, String inviteToken) =>
      _u('/r/$roomId', {'invite': inviteToken}).toString();

  @override
  Uri wsUri(String roomId, Role role, String secret) {
    final base = Uri.parse(baseUrl);
    return base.replace(
      scheme: base.scheme == 'https' ? 'wss' : 'ws',
      path: '/api/rooms/$roomId/ws',
      queryParameters: {'role': role.name, 'secret': secret},
    );
  }
}
