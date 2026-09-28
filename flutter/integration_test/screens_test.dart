// 主要画面を順に開いて撮る（デモと場所モード・ホームの「続きを開く」。何もサーバーへ送らない）。
// 実行: flutter drive --driver=test_driver/integration_test.dart --target=integration_test/screens_test.dart -d <UDID>
// 撮影はホスト側が「SHOT:<名前>」の行を見て simctl io screenshot で行う。
// 06 の前提: シミュレータの位置を `xcrun simctl location <UDID> set 35.658588,139.702834`（B2→B1 のエスカレーター手前）にし、
// 位置の許可を入れておく（インストールし直すと外れるので、テスト開始後に `xcrun simctl privacy <UDID> grant location <bundle id>`）。
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shibuya_machimachi/core/core.dart';
import 'package:shibuya_machimachi/core/router.dart';

import 'helpers.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets('主要画面（ホーム・デモの待ち合わせ・3D・高画質3D・AR・停止・場所モードの道順）', (tester) async {
    final c = await launchApp(tester);

    // 01 ホーム
    await waitFor(tester, find.text('デモで試す（1台で体験）'));
    await shot(tester, '01_home');

    // デモ: 作成 → 3秒で参加 → 承認
    await tapAndWait(tester, find.text('デモで試す（1台で体験）'), after: const Duration(seconds: 4));
    await waitFor(tester, find.text('この人と位置を共有する'), timeout: const Duration(seconds: 15));
    await tapAndWait(tester, find.text('この人と位置を共有する'), after: const Duration(seconds: 2));
    await waitFor(tester, find.text('会えた！'));
    // 相手が少し近づくまで待ってから距離と矢印を撮る
    await wait(tester, const Duration(seconds: 12));
    await scrollToStart(tester);
    await shot(tester, '02_demo_meet');

    // 03 3D渋谷（地図の読み込みを待つ）
    await scrollToTop(tester, find.text('3D渋谷').first);
    await wait(tester, const Duration(seconds: 8));
    await shot(tester, '03_map3d');

    // 04 高画質3D（読み込み後）
    await tapAndWait(tester, find.text('高画質で見る'), after: const Duration(seconds: 3));
    final loaded = await waitGone(tester, find.text('高画質モデルを読み込み中…'), timeout: const Duration(seconds: 150));
    // ignore: avoid_print
    print('HQ_LOADED:$loaded');
    await wait(tester, const Duration(seconds: 6));
    await shot(tester, '04_hq');
    await tester.tap(find.byTooltip('閉じる'));
    await wait(tester, const Duration(seconds: 3));

    // 05 AR（シミュレータはカメラ・向きセンサーが無いので中立表示）
    await tapAndWait(tester, find.text('ARで探す'), after: const Duration(seconds: 5));
    await shot(tester, '05_ar');
    // AR は全画面で戻るボタンが無いので、右上の「閉じる」で meet に戻る。
    await tester.tap(find.byTooltip('閉じる'));
    await wait(tester, const Duration(seconds: 2));

    // 07 停止
    await tapAndWait(tester, find.text('共有をやめる'));
    await tapAndWait(tester, find.text('やめる'), after: const Duration(seconds: 2));
    await waitFor(tester, find.text('あなたが共有をやめたため、位置の共有は停止しました。'));
    await shot(tester, '07_stopped');

    // 06 場所モードの道順（地下3階からハチ公像へ: 階の移動の案内が出る）
    await tapAndWait(tester, find.text('新しく待ち合わせを作る'), after: const Duration(seconds: 2));
    c.read(routerProvider).go('/go');
    await wait(tester, const Duration(seconds: 2));
    await tapAndWait(tester, find.text('ハチ公像'), after: const Duration(seconds: 3));
    c.read(ownFloorProvider.notifier).setByUser('B3');
    await wait(tester, const Duration(seconds: 4));
    await waitFor(tester, find.textContaining('地下1階へ'), timeout: const Duration(seconds: 20));
    await scrollToTop(tester, find.text('道順で案内').first);
    await wait(tester, const Duration(seconds: 3));
    await shot(tester, '06_route_floor');

    // 13 ホームの「続きを開く」（OS にアプリを終了させられたあと、保存した待ち合わせへ戻る入口）。
    // 撮影用の架空の部屋を端末に保存して見せ、撮ったら消す（サーバーには何も送らない）。
    final store = SecureSessionStore();
    final fake = RoomSession(roomId: 'f' * 32, role: Role.guest, secret: '0' * 32);
    await store.save(fake);
    c.read(routerProvider).go('/');
    await waitFor(tester, find.text('続きを開く'));
    await scrollToStart(tester);
    await shot(tester, '13_home_resume');
    await store.clear(fake.roomId);
  });
}
