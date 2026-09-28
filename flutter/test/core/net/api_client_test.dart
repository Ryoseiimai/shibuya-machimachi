// HttpApiClient: 成功・サーバーの reason・404・429 の文言・通信失敗・壊れた応答の振り分け。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shibuya_machimachi/core/core.dart';

HttpApiClient client(Future<http.Response> Function(http.Request r) h) =>
    HttpApiClient(baseUrl: 'https://example.invalid', client: MockClient(h));

http.Response json(int status, Object body) =>
    http.Response.bytes(utf8.encode(jsonEncode(body)), status, headers: {'content-type': 'application/json'});

Matcher reason(String r, {int? status}) =>
    throwsA(isA<ApiException>().having((e) => e.reason, 'reason', r).having((e) => e.status, 'status', status));

void main() {
  test('作成: 本文にニックネームだけを送り、3つの値を受け取る', () async {
    late http.Request req;
    final api = client((r) async {
      req = r;
      return json(200, {'ok': true, 'roomId': 'a' * 32, 'hostSecret': 'b' * 32, 'inviteToken': 'c' * 32});
    });
    final r = await api.createRoom('りょう');
    expect(req.method, 'POST');
    expect(req.url.path, '/api/rooms');
    expect(jsonDecode(req.body), {'nickname': 'りょう'});
    expect(req.headers.containsKey('origin'), isFalse);
    expect(r.roomId, 'a' * 32);
    expect(api.inviteUrl('a' * 32, 'c' * 32), 'https://example.invalid/r/${'a' * 32}?invite=${'c' * 32}');
    expect(api.wsUri('a' * 32, Role.host, 'b' * 32).scheme, 'wss');
  });

  test('サーバーの reason をそのまま渡す（429 は日本語の文言つき）', () async {
    final api = client((_) async => json(429, {'ok': false, 'reason': 'rate_limited', 'message': 'しばらく待って'}));
    await expectLater(api.createRoom('x'), reason('rate_limited', status: 429));
    try {
      await api.createRoom('x');
    } on ApiException catch (e) {
      expect(e.message, 'しばらく待って');
    }
    final full = client((_) async => json(409, {'ok': false, 'reason': 'full'}));
    await expectLater(full.join('a' * 32, 'c' * 32, 'x'), reason('full', status: 409));
  });

  test('{"error":"not found"} は not_found、壊れた応答・必須値の欠けは invalid_response', () async {
    await expectLater(client((_) async => json(404, {'error': 'not found'})).preview('a' * 32, 'c'), reason('not_found', status: 404));
    await expectLater(
        client((_) async => http.Response('<html>', 502)).preview('a' * 32, 'c'), reason('invalid_response', status: 502));
    await expectLater(client((_) async => json(200, {'ok': true})).preview('a' * 32, 'c'), reason('invalid_response'));
  });

  test('通信の失敗は network（例外の文言＝URL は捨てる）', () async {
    final api = client((_) async => throw http.ClientException('failed https://example.invalid/api/rooms?secret=x'));
    await expectLater(api.createRoom('x'), reason('network'));
  });
}
