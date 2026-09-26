import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shibuya_machimachi/core/core.dart';
import 'package:shibuya_machimachi/core/deep_link.dart';
import 'package:shibuya_machimachi/core/ws/outbound_guard.dart';
import 'package:shibuya_machimachi/core/ws/room_connection.dart';

void main() {
  group('ServerEvent', () {
    test('完全な state を読む', () {
      final ev = ServerEvent.fromJson(jsonDecode('''{
        "type":"state","role":"host","phase":"active","roomId":"${'a' * 32}","expiresAt":1790000000000,
        "self":{"nickname":"りょう","approved":true,"floor":"1F","inArea":true},
        "other":{"nickname":"すず","approved":true,"connected":true,"inArea":true,"floor":"2F","lastUpdatedAt":1789999999000},
        "distance_m":155,"bearing_deg":300,"floorDiffText":"相手は1つ上の階にいます",
        "meetSpot":{"id":"hachiko","byMe":false},"stopped":null,
        "judge":{"found":false,"probability":null,"source":null,"at":null,"callsUsed":0,"maxCalls":10,"limitReached":false}}'''));
      expect(ev, isA<StateEvent>());
      final s = (ev as StateEvent).state;
      expect(s.phase, Phase.active);
      expect(s.role, Role.host);
      expect(s.other!.floor, '2F');
      expect(s.distanceM, 155);
      expect(s.meetSpot!.id, 'hachiko');
      expect(s.meetSpot!.byMe, isFalse);
      expect(s.judge!.maxCalls, 10);
    });

    test('alarm の最小形（phase だけ）でも落ちない', () {
      final ev = ServerEvent.fromJson({'type': 'state', 'phase': 'expired'}) as StateEvent;
      expect(ev.state.phase, Phase.expired);
      expect(ev.state.phase.isTerminal, isTrue);
      expect(ev.state.self, isNull);
      expect(ev.state.judge, isNull);
    });

    test('judgeResult / locationRejected / error / 未知', () {
      final j = ServerEvent.fromJson({'type': 'judgeResult', 'ok': false, 'reason': 'too_far', 'distance_m': 42}) as JudgeResultEvent;
      expect(j.reason, 'too_far');
      expect(j.distanceM, 42);
      expect((ServerEvent.fromJson({'type': 'locationRejected', 'reason': 'out_of_area'}) as LocationRejectedEvent).reason, 'out_of_area');
      expect((ServerEvent.fromJson({'type': 'error', 'code': 'invalid_spot'}) as ErrorEvent).code, 'invalid_spot');
      expect(ServerEvent.fromJson({'type': 'ping'}), isNull);
      expect(ServerEvent.fromJson('x'), isNull);
    });
  });

  test('sanitizeNickname はサーバーと同じ（制御文字除去・trim・1〜20 UTF-16）', () {
    expect(sanitizeNickname('  りょう\u0007 '), 'りょう');
    expect(sanitizeNickname('   '), isNull);
    expect(sanitizeNickname('a' * 20), 'a' * 20);
    expect(sanitizeNickname('a' * 21), isNull);
    expect(sanitizeNickname('😀' * 10), '😀' * 10); // 絵文字は2文字分
    expect(sanitizeNickname('😀' * 11), isNull);
  });

  test('RoomSession は secret を文字列に出さない', () {
    final s = RoomSession(roomId: 'a' * 32, role: Role.guest, secret: 'b' * 32);
    expect(s.toString(), isNot(contains('b' * 32)));
    expect(RoomSession.fromJson(s.toJson())!.secret, 'b' * 32);
  });

  group('OutboundGuard', () {
    test('2048バイトを超えたら送らない', () {
      final g = OutboundGuard();
      expect(g.encode({'type': 'floor', 'floor': '1F'}), isNotNull);
      expect(g.encode({'type': 'x', 'pad': 'あ' * 700}), isNull); // 3バイト×700 > 2048
    });
    test('location は 1.2秒に1回', () {
      final g = OutboundGuard();
      expect(g.locationWaitMs(1000), 0);
      g.markLocationSent(1000);
      expect(g.locationWaitMs(1500), 700);
      expect(g.locationWaitMs(2200), 0);
    });
  });

  test('再接続の待ち時間は 1,2,4,8,15,15…秒', () {
    expect([for (var i = 0; i < 6; i++) reconnectDelay(i).inSeconds], [1, 2, 4, 8, 15, 15]);
  });

  group('deepLinkToLocation', () {
    final id = 'a1' * 16;
    test('https の招待リンク', () {
      expect(deepLinkToLocation(Uri.parse('https://shibuya-machimachi.kaeru3160.workers.dev/r/$id?invite=${'b' * 32}')),
          '/r/$id?invite=${'b' * 32}');
    });
    test('カスタムスキーム', () {
      expect(deepLinkToLocation(Uri.parse('shibuyamachimachi-flutter://r/$id?invite=x')), '/r/$id?invite=x');
      expect(deepLinkToLocation(Uri.parse('shibuyamachimachi-flutter://demo')), '/new?demo=1');
      expect(deepLinkToLocation(Uri.parse('shibuyamachimachi-flutter://go')), '/go');
    });
    test('知らない形・他のホスト・大文字の ID は無視', () {
      expect(deepLinkToLocation(Uri.parse('https://example.com/r/$id')), isNull);
      expect(deepLinkToLocation(Uri.parse('https://shibuya-machimachi.kaeru3160.workers.dev/r/${'A' * 32}')), isNull);
      expect(deepLinkToLocation(Uri.parse('https://shibuya-machimachi.kaeru3160.workers.dev/privacy')), isNull);
      expect(deepLinkToLocation(Uri.parse('https://shibuya-machimachi.kaeru3160.workers.dev/')), '/new');
    });
  });
}
