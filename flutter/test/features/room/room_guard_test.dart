// 本物の待ち合わせの途中にデモのリンク（…://demo → /new?demo=1）が開かれても、部屋を捨てずに案内だけ出す。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shibuya_machimachi/core/core.dart';
import 'package:shibuya_machimachi/features/room/src/room_texts.dart';

import 'room_flow_test.dart' show openAsHost, tapText, toActive;
import 'room_harness.dart';

void main() {
  testWidgets('待ち合わせ中のデモリンクは始めず「今の待ち合わせに戻る」を出す', (tester) async {
    final h = await openAsHost(tester);
    await toActive(tester, h);
    h.router.go('/new?demo=1');
    await settle(tester);
    expect(find.text(kMsgRoomActive), findsOneWidget);
    expect(h.container.read(demoModeProvider), isFalse);
    expect(h.view.session?.roomId, kRoomId);
    expect(h.view.wsConnected, isTrue);
    expect(h.sockets, hasLength(1));

    await tapText(tester, '今の待ち合わせに戻る');
    expect(find.text('会えた！'), findsOneWidget);
    await h.finish(tester);
  });

  lifecycleTests();
}

/// 許可が無い間は watch() がすぐエラーで終わる（geolocator と同じ）。
class DeniableLocation extends FakeLocation {
  bool granted = false;
  int watchCalls = 0;

  @override
  Future<LocationAccess> currentAccess() async => granted ? LocationAccess.granted : LocationAccess.denied;

  @override
  Stream<PositionFix> watch() {
    watchCalls++;
    return granted ? c.stream : Stream<PositionFix>.error(Exception('denied'));
  }
}

void lifecycleTests() {
  testWidgets('位置の許可を後から設定で出して戻ったら、止まっていた位置の監視が動き出す', (tester) async {
    final loc = DeniableLocation();
    final h = RoomHarness(loc: loc);
    await h.start(tester, '/new');
    await tester.enterText(find.byType(TextField), 'りょう');
    await tapText(tester, '待ち合わせを作る');
    await toActive(tester, h);
    // 1分待つ（Riverpod の自動リトライは約40秒であきらめる）
    for (var i = 0; i < 60; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
    expect(find.text('設定を開く'), findsOneWidget);
    final calls = loc.watchCalls;
    loc.granted = true; // 設定アプリで許可した
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
    expect(loc.watchCalls, calls, reason: 'リトライはもう止まっている');

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await settle(tester);
    expect(loc.watchCalls, greaterThan(calls));
    loc.emit(35.6585, 139.7016);
    await settle(tester);
    expect(find.text('設定を開く'), findsNothing);
    expect(h.socket.ofType('location'), hasLength(1));
    await h.finish(tester);
  });
}
