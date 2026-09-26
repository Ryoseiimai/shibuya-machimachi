// デモ（1台で体験）を画面から最後まで: 作成 → 3秒で参加 → 承認 → 相手が近づく → 1F 自動 → 会えた → 停止。
// 何も送信しない（API・WS・位置は core の模擬）。文字を200%にしても画面が崩れない（はみ出しの例外が出ない）ことも見る。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shibuya_machimachi/core/core.dart';

import 'room_harness.dart';

Future<void> tapText(WidgetTester tester, String text) async {
  await tester.tap(find.text(text));
  await settle(tester);
}

void main() {
  testWidgets('デモの一連（招待は外に出さずダイアログ）', (tester) async {
    final h = RoomHarness(demo: true);
    await h.start(tester, '/new?demo=1');
    await settle(tester);
    expect(find.text(DemoConfig.bannerText), findsOneWidget);
    expect(find.text('招待リンクを送ってください'), findsOneWidget);
    expect(find.text(DemoConfig.inviteText), findsOneWidget);

    await tapText(tester, 'LINEで送る');
    expect(find.text(DemoConfig.shareAlertText), findsOneWidget);
    await tapText(tester, 'OK');
    await tapText(tester, 'リンクをコピー');
    expect(find.text(DemoConfig.shareAlertText), findsOneWidget);
    expect(h.clipboard, isEmpty); // デモの架空リンクは外に出さない
    await tapText(tester, 'OK');

    await tester.pump(const Duration(seconds: 3));
    await settle(tester);
    expect(find.textContaining('さんが参加しました。', findRichText: true), findsOneWidget);
    await tapText(tester, 'この人と位置を共有する');
    await tester.pump(const Duration(milliseconds: 400));
    await settle(tester);
    expect(find.text('会えた！'), findsOneWidget);
    expect(h.container.read(ownFloorProvider), '1F'); // 承認の 0.3 秒後に 1F が自動で入る

    // 相手（5m/s）が近づききるまで進める。
    for (var i = 0; i < 60; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
    await settle(tester);
    expect(h.view.server!.distanceM, lessThanOrEqualTo(kMeetDistanceM));
    expect(find.text('相手は同じ階にいます'), findsOneWidget);

    await tapText(tester, '会えた！');
    expect(find.text('会えた!'), findsOneWidget);
    expect(find.text('距離による判定'), findsOneWidget);

    await tapText(tester, '共有をやめる');
    await tapText(tester, 'やめる');
    expect(find.text('あなたが共有をやめたため、位置の共有は停止しました。'), findsOneWidget);
    await tapText(tester, '新しく待ち合わせを作る');
    expect(find.text('ニックネーム(相手に表示されます)'), findsOneWidget);
    expect(h.container.read(demoModeProvider), isFalse);
    await h.finish(tester);
  });

  testWidgets('デモの「終了」で作成画面へ戻り、デモの部屋は開き直せない', (tester) async {
    final h = RoomHarness(demo: true);
    await h.start(tester, '/new?demo=1');
    await settle(tester);
    await tapText(tester, '終了');
    expect(find.text('ニックネーム(相手に表示されます)'), findsOneWidget);
    expect(h.container.read(demoModeProvider), isFalse);
    h.router.go('/r/${DemoConfig.roomId}');
    await settle(tester);
    expect(find.text('ニックネーム(相手に表示されます)'), findsOneWidget);
    await h.finish(tester);
  });

  testWidgets('文字200%でも meet 画面がはみ出さない', (tester) async {
    final h = RoomHarness(demo: true);
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await h.start(tester, '/new?demo=1');
    tester.view.physicalSize = const Size(390, 12000);
    await tester.pump(const Duration(seconds: 3));
    await settle(tester);
    await tapText(tester, 'この人と位置を共有する');
    await tester.pump(const Duration(seconds: 2));
    await settle(tester);
    expect(find.text('会えた！'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await h.finish(tester);
  });
}
