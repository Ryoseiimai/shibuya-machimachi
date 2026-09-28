// レビューで見つかった穴の回帰テスト:
//   - 通信が切れている間の「共有をやめる」が、アプリ終了→開き直し・つなぎ直しで忘れられない
//   - 本物の部屋の途中でデモ・別の部屋を始めない（stop を送らずに部屋を捨てない）
//   - 古い測位・止まった GPS の位置を送らない
//   - 場所モード（/go）の階を部屋へ持ち込まない・サーバーの「未選択」を反映する

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shibuya_machimachi/core/core.dart';
import 'package:shibuya_machimachi/core/ws/room_socket.dart';

import 'room_controller_test.dart' show FakeApi, FakeLocation, FakeSocket, pump, stateMsg;

final String roomId = 'a' * 32;

/// 1回目の接続は socket を返し、以後は offline なら失敗、そうでなければ新しい FakeSocket を返す。
class Net {
  final sockets = <FakeSocket>[];
  bool offline = false;

  Future<RoomSocket> connect(Uri _) async {
    if (offline) throw const WsHandshakeException(null, 'network');
    final s = FakeSocket();
    sockets.add(s);
    return s;
  }

  FakeSocket get last => sockets.last;
  List<Map<String, Object?>> ofType(String t) => [for (final s in sockets) ...s.ofType(t)];
}

ProviderContainer makeContainer(SessionStore store, Net net, FakeLocation loc) {
  final c = ProviderContainer(overrides: [
    apiClientProvider.overrideWithValue(FakeApi()),
    roomSocketConnectorProvider.overrideWithValue(net.connect),
    activeSessionStoreProvider.overrideWithValue(store),
    locationServiceProvider.overrideWithValue(loc),
  ]);
  c.listen(roomControllerProvider, (_, _) {});
  return c;
}

void main() {
  group('通信が切れている間の「共有をやめる」', () {
    test('アプリが終了して開き直しても、位置は送らず stop だけを送る', () async {
      final store = MemorySessionStore();
      final net = Net();
      final loc = FakeLocation();
      final a = makeContainer(store, net, loc);
      final ctrl = a.read(roomControllerProvider.notifier);
      await ctrl.createRoom('りょう');
      await pump();
      net.last.push(stateMsg('active'));
      loc.emit(35.6585, 139.7016);
      await pump();
      expect(net.ofType('location'), hasLength(1));

      // 地下で切れる → 共有をやめる（送れない）
      net.offline = true;
      net.last.serverClose(1006, '');
      await pump();
      expect(ctrl.stop(), isFalse);
      await pump();
      expect(net.ofType('stop'), isEmpty);
      expect((await store.load(roomId))!.stopPending, isTrue, reason: 'stop を押したことが保存されている');

      // アプリが終了させられる
      a.dispose();

      // 開き直す（通信は戻っている）
      net.offline = false;
      final loc2 = FakeLocation();
      final b = makeContainer(store, net, loc2);
      addTearDown(b.dispose);
      final ctrl2 = b.read(roomControllerProvider.notifier);
      expect(await ctrl2.resume(roomId), isTrue);
      expect(b.read(roomControllerProvider).stopRequested, isTrue);
      await pump();
      expect(net.last.ofType('stop'), hasLength(1), reason: 'つながったら stop を送る');
      net.last.push(stateMsg('active'));
      loc2.emit(35.6585, 139.7016);
      await pump();
      expect(net.last.ofType('location'), isEmpty, reason: '開き直しても位置は送らない');

      // サーバーが止めたら保存ごと消える
      net.last.push(stateMsg('stopped'));
      await pump();
      expect(await store.load(roomId), isNull);
    });

    test('二重接続のあと「もう一度つなぐ」でも stop を忘れない', () async {
      final store = MemorySessionStore();
      final net = Net();
      final loc = FakeLocation();
      final c = makeContainer(store, net, loc);
      addTearDown(c.dispose);
      final ctrl = c.read(roomControllerProvider.notifier);
      await ctrl.createRoom('りょう');
      await pump();
      net.last.push(stateMsg('active'));
      await pump();
      net.last.serverClose(4001, 'duplicate_connection');
      await pump();
      expect(ctrl.stop(), isFalse);
      expect(ctrl.reconnect(), isTrue);
      expect(c.read(roomControllerProvider).stopRequested, isTrue);
      await pump();
      net.last.push(stateMsg('active'));
      loc.emit(35.6585, 139.7016);
      await pump();
      expect(net.last.ofType('stop'), hasLength(1));
      expect(net.ofType('location'), isEmpty);
    });
  });

  group('本物の部屋の途中', () {
    late ProviderContainer c;
    late Net net;
    late MemorySessionStore store;
    late FakeLocation loc;

    setUp(() async {
      store = MemorySessionStore();
      net = Net();
      loc = FakeLocation();
      c = makeContainer(store, net, loc);
      await c.read(roomControllerProvider.notifier).createRoom('りょう');
      await pump();
      net.last.push(stateMsg('active'));
      loc.emit(35.6585, 139.7016);
      await pump();
    });
    tearDown(() => c.dispose());

    test('デモは始めず（room_active）、部屋と保存をそのまま残す', () async {
      final ctrl = c.read(roomControllerProvider.notifier);
      expect(ctrl.hasLiveRealRoom, isTrue);
      await expectLater(ctrl.startDemo('x'), throwsA(isA<ApiException>().having((e) => e.reason, 'reason', 'room_active')));
      expect(c.read(demoModeProvider), isFalse);
      expect(c.read(roomControllerProvider).session?.roomId, roomId);
      expect(c.read(roomControllerProvider).wsConnected, isTrue);
      expect(await store.load(roomId), isNotNull);
    });

    test('別の部屋も作らない', () async {
      await expectLater(c.read(roomControllerProvider.notifier).createRoom('りょう'),
          throwsA(isA<ApiException>().having((e) => e.reason, 'reason', 'room_active')));
      expect(net.sockets, hasLength(1));
    });

    test('共有をやめて stopped になったあとはデモを始められる', () async {
      final ctrl = c.read(roomControllerProvider.notifier);
      ctrl.stop();
      await pump();
      expect(ctrl.hasLiveRealRoom, isTrue, reason: 'stopped が届くまでは続いている扱い');
      net.last.push(stateMsg('stopped'));
      await pump();
      expect(ctrl.hasLiveRealRoom, isFalse);
    });
  });

  group('古い位置を送らない', () {
    late ProviderContainer c;
    late Net net;
    late FakeLocation loc;

    setUp(() async {
      net = Net();
      loc = FakeLocation();
      c = makeContainer(MemorySessionStore(), net, loc);
      await c.read(roomControllerProvider.notifier).createRoom('りょう');
      await pump();
    });
    tearDown(() => c.dispose());

    test('1分より前の測位は送らない', () async {
      net.last.push(stateMsg('active'));
      final old = DateTime.now().millisecondsSinceEpoch - 10 * 60 * 1000;
      loc.c.add(PositionFix(lat: 35.6585, lng: 139.7016, accuracy: 5, timestampMs: old));
      await pump();
      expect(net.ofType('location'), isEmpty);
      loc.emit(35.6585, 139.7016);
      await pump();
      expect(net.ofType('location'), hasLength(1));
    });

    test('位置の監視がエラーで止まったら、最後の位置は送らない', () async {
      net.last.push(stateMsg('waiting_host_approval'));
      loc.emit(35.6585, 139.7016);
      await pump();
      loc.c.addError(Exception('permission denied'));
      await pump();
      net.last.push(stateMsg('active'));
      await pump();
      expect(net.ofType('location'), isEmpty);
    });
  });

  group('今いる階', () {
    test('場所モードで入った階は部屋に持ち込まず、サーバーの未選択に合わせる', () async {
      final net = Net();
      final c = makeContainer(MemorySessionStore(), net, FakeLocation());
      addTearDown(c.dispose);
      c.read(ownFloorProvider.notifier).setByUser('1F'); // /go で自動で入る 1F（部屋はまだ無い）
      await c.read(roomControllerProvider.notifier).createRoom('りょう');
      expect(c.read(ownFloorProvider), isNull);
      await pump();
      net.last.push(stateMsg('active'));
      await pump();
      expect(c.read(ownFloorProvider), isNull);
      expect(net.ofType('floor'), isEmpty);
    });

    test('サーバーの self.floor が null になったら反映する（ユーザーが選んだ直後の5秒は除く）', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final n = c.read(ownFloorProvider.notifier);
      n.syncFromServer('2F');
      expect(c.read(ownFloorProvider), '2F');
      n.syncFromServer(null);
      expect(c.read(ownFloorProvider), isNull);
      n.setByUser('B1');
      n.syncFromServer(null);
      expect(c.read(ownFloorProvider), 'B1');
    });

    test('つながり直したら、選んである階を送り直す', () async {
      final net = Net();
      final c = makeContainer(MemorySessionStore(), net, FakeLocation());
      addTearDown(c.dispose);
      await c.read(roomControllerProvider.notifier).createRoom('りょう');
      await pump();
      net.last.push(stateMsg('active'));
      await pump();
      net.last.serverClose(1006, '');
      await pump();
      c.read(ownFloorProvider.notifier).setByUser('B2'); // 切れている間に選んだ（届かない）
      expect(net.ofType('floor'), isEmpty);
      await pump(1200); // 1秒後に再接続
      expect(net.sockets, hasLength(2));
      expect(net.last.ofType('floor').single['floor'], 'B2');
    });
  });
}
