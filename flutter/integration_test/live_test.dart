// 本番サーバーとの実通信の確認（このアプリ＝作成側、ブラウザの Web 版＝参加側）。
// 実行: flutter drive --driver=test_driver/integration_test.dart --target=integration_test/live_test.dart -d <UDID>
// 流れ: 作成 → 「リンクをコピー」（ホストが simctl pbpaste で招待リンクを受け取り、参加側のブラウザで開く）
//       → 参加側が「承認して参加」 → ここで「この人と位置を共有する」 → 双方に距離 → ここで停止。
// ログに出すのは合図と距離（m）だけ。招待リンク・秘密値・座標は出さない（撮影も招待画面は撮らない）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shibuya_machimachi/core/core.dart';
import 'package:shibuya_machimachi/core/router.dart';

import 'helpers.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets('本番: 招待 → 参加 → 相互承認 → 双方で距離 → 停止', (tester) async {
    final c = await launchApp(tester);
    c.read(routerProvider).go('/new');
    // ホームにも同じ文言のボタンがあるので、作成画面の入力欄が出るのを待つ。
    await waitFor(tester, find.byType(TextField));
    await tester.enterText(find.byType(TextField).first, 'りょう');
    await tapAndWait(tester, find.text('待ち合わせを作る'), after: const Duration(seconds: 3));

    await waitFor(tester, find.text('リンクをコピー'), timeout: const Duration(seconds: 30));
    await tapAndWait(tester, find.text('リンクをコピー'));
    // ignore: avoid_print
    print('INVITE_READY');

    // 参加側が「承認して参加」するまで待つ（ここではまだ位置を送らない）。
    await waitFor(tester, find.text('この人と位置を共有する'), timeout: const Duration(minutes: 3));
    await shot(tester, '08_live_host_approve');
    await tapAndWait(tester, find.text('この人と位置を共有する'), after: const Duration(seconds: 2));

    // 双方の位置が届き、距離が出るまで待つ。
    final sw = Stopwatch()..start();
    int? d;
    while ((d = c.read(roomControllerProvider).server?.distanceM) == null) {
      if (sw.elapsed > const Duration(seconds: 90)) fail('距離が出ません');
      await wait(tester, const Duration(seconds: 1));
    }
    // ignore: avoid_print
    print('HOST_ACTIVE distance_m=$d');
    await wait(tester, const Duration(seconds: 4));
    await scrollToStart(tester);
    await shot(tester, '09_live_host_meet');

    // 参加側が距離を撮り終えるまで少し待ってから停止する。
    await wait(tester, const Duration(seconds: 25));
    await tapAndWait(tester, find.text('共有をやめる'));
    await tapAndWait(tester, find.text('やめる'), after: const Duration(seconds: 2));
    await waitFor(tester, find.text('あなたが共有をやめたため、位置の共有は停止しました。'));
    // ignore: avoid_print
    print('HOST_STOPPED');
    await shot(tester, '11_live_host_stopped');
    // 参加側が停止を撮り終えるまで待つ。
    await wait(tester, const Duration(seconds: 20));
  });
}
