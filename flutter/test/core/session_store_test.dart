// 端末への保存（SecureSessionStore）: 読み書き・stop の保存・3時間の期限・いちばん新しい部屋。
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shibuya_machimachi/core/core.dart';
import 'package:shibuya_machimachi/core/router.dart';

RoomSession session(String c, {int? savedAt, bool stopPending = false}) =>
    RoomSession(roomId: c * 32, role: Role.host, secret: 'b' * 32, inviteUrl: 'https://x/r', savedAtMs: savedAt, stopPending: stopPending);

void main() {
  var now = 1000000000;
  late SecureSessionStore store;

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    now = 1000000000;
    store = SecureSessionStore(null, () => now);
  });

  test('保存して読み戻せる（保存時刻が入る・stop 未送信も残る）', () async {
    await store.save(session('a', stopPending: true));
    final s = await store.load('a' * 32);
    expect(s!.secret, 'b' * 32);
    expect(s.inviteUrl, 'https://x/r');
    expect(s.savedAtMs, now);
    expect(s.stopPending, isTrue);
    await store.clear('a' * 32);
    expect(await store.load('a' * 32), isNull);
  });

  test('3時間（部屋の寿命）を過ぎた保存は読むときに消える', () async {
    await store.save(session('a'));
    now += kRoomTtlMs - 1;
    expect(await store.load('a' * 32), isNotNull);
    now += 1;
    expect(await store.load('a' * 32), isNull);
    expect(await const FlutterSecureStorage().readAll(), isEmpty);
  });

  test('latest: いちばん新しい有効な保存を返し、期限切れ・壊れた値は消す', () async {
    await store.save(session('a', savedAt: now - kRoomTtlMs - 5));
    await store.save(session('c', savedAt: now - 1000));
    await store.save(session('d', savedAt: now - 10));
    await const FlutterSecureStorage().write(key: 'sm:${'e' * 32}', value: '{broken');
    await const FlutterSecureStorage().write(key: 'other', value: 'keep');
    final s = await store.latest();
    expect(s!.roomId, 'd' * 32);
    final left = await const FlutterSecureStorage().readAll();
    expect(left.keys.toSet(), {'sm:${'c' * 32}', 'sm:${'d' * 32}', 'other'});
  });

  test('起動時に開く場所: 保存があれば部屋、無ければホーム', () {
    expect(initialLocationFor(null), '/');
    expect(initialLocationFor(session('a', savedAt: now)), '/r/${'a' * 32}');
  });
}
