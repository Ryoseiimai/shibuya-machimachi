// RoomConnection の終わり方（404 が2回＝期限切れ・401＝認証切れ・接続中の dispose）と再接続。
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shibuya_machimachi/core/ws/room_connection.dart';
import 'package:shibuya_machimachi/core/ws/room_socket.dart';

import '../room_controller_test.dart' show FakeSocket;

class Harness {
  Harness(this.connector);
  final RoomSocketConnector connector;
  final statuses = <ConnectionStatus>[];
  late final RoomConnection conn = RoomConnection(
    uri: Uri.parse('wss://example.invalid/ws'),
    connector: connector,
    onEvent: (_) {},
    onStatus: statuses.add,
  );
  ConnectionEnd? get ended => switch (statuses.lastOrNull) { Ended(:final reason) => reason, _ => null };
}

void main() {
  test('404 が2回続いたら期限切れで終わる（1回目は再接続する）', () async {
    var calls = 0;
    final h = Harness((_) async {
      calls++;
      throw const WsHandshakeException(404, 'not_found');
    });
    h.conn.start();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(h.statuses.last, isA<WaitingRetry>());
    await Future<void>.delayed(const Duration(milliseconds: 1100));
    expect(calls, 2);
    expect(h.ended, ConnectionEnd.expired);
    await h.conn.dispose();
  });

  test('401・400 はすぐ認証切れで終わる', () async {
    for (final code in [401, 400]) {
      final h = Harness((_) async => throw WsHandshakeException(code));
      h.conn.start();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(h.ended, ConnectionEnd.unauthorized);
      await h.conn.dispose();
    }
  });

  test('つながる前に dispose したら、届いた socket は閉じ、Connected を知らせない', () async {
    final pending = Completer<RoomSocket>();
    final h = Harness((_) => pending.future);
    h.conn.start();
    await h.conn.dispose();
    final s = FakeSocket();
    var closed = false;
    s.messages.listen((_) {}, onDone: () => closed = true);
    pending.complete(s);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(closed, isTrue);
    expect(h.statuses.whereType<Connected>(), isEmpty);
    expect(h.conn.isOpen, isFalse);
  });

  test('ネットワークの失敗は再接続し、つながったら回数を戻して送れる', () async {
    var calls = 0;
    final s = FakeSocket();
    final h = Harness((_) async {
      calls++;
      if (calls == 1) throw const WsHandshakeException(null, 'network');
      return s;
    });
    h.conn.start();
    await Future<void>.delayed(const Duration(milliseconds: 1100));
    expect(h.statuses.last, isA<Connected>());
    expect(h.conn.send('{"type":"judge"}'), isTrue);
    expect(s.sent.single['type'], 'judge');
    await h.conn.dispose();
  });
}
