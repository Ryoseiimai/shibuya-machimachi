// connectIoRoomSocket: 自前ハンドシェイクで 404 の状態と reason を取れる・101 なら送受信できる。
// 端末内の使い捨てポート（0＝空いている番号）で動かす。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shibuya_machimachi/core/ws/room_socket.dart';

void main() {
  late HttpServer server;

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      if (req.uri.path == '/gone') {
        req.response
          ..statusCode = 404
          ..headers.contentType = ContentType.json
          ..write(jsonEncode({'ok': false, 'reason': 'not_found'}));
        await req.response.close();
        return;
      }
      final ws = await WebSocketTransformer.upgrade(req);
      ws.listen((m) => ws.add('echo:$m'));
    });
  });
  tearDown(() => server.close(force: true));

  Uri u(String path) => Uri.parse('ws://127.0.0.1:${server.port}$path');

  test('404 は状態と reason つきの WsHandshakeException', () async {
    await expectLater(
      connectIoRoomSocket(u('/gone')),
      throwsA(isA<WsHandshakeException>()
          .having((e) => e.statusCode, 'statusCode', 404)
          .having((e) => e.reason, 'reason', 'not_found')),
    );
  });

  test('101 なら送受信できる', () async {
    final s = await connectIoRoomSocket(u('/ws?role=host'));
    final first = s.messages.first;
    s.send('hi');
    expect(await first, 'echo:hi');
    await s.close(1000);
  });

  test('つながらないときは network（URL は例外に入れない）', () async {
    final port = server.port;
    await server.close(force: true);
    await expectLater(
      connectIoRoomSocket(Uri.parse('ws://127.0.0.1:$port/ws?secret=${'b' * 32}')),
      throwsA(isA<WsHandshakeException>().having((e) => e.toString(), 'text', isNot(contains('secret')))),
    );
  });
}
