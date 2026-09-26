// room の画面の流れ: 作成 → 招待 → 承認 → meet → 停止、参加プレビュー、行き止まり、二重接続、状態バナー、判定の注記。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shibuya_machimachi/core/core.dart';

import 'room_harness.dart';

Future<void> tapText(WidgetTester tester, String text) async {
  await tester.tap(find.text(text));
  await settle(tester);
}

/// 作成 → 招待画面まで進めて、FakeSocket に waiting_guest を流す。
Future<RoomHarness> openAsHost(WidgetTester tester) async {
  final h = RoomHarness();
  await h.start(tester, '/new');
  await tester.enterText(find.byType(TextField), 'りょう');
  await tapText(tester, '待ち合わせを作る');
  h.socket.push(stateMsg('waiting_guest'));
  await settle(tester);
  return h;
}

Future<void> toActive(WidgetTester tester, RoomHarness h, {int? distance = 123, int? bearing = 90}) async {
  h.socket.push(stateMsg('active',
      otherNick: 'すず', distance: distance, bearing: bearing, lastUpdatedAt: DateTime.now().millisecondsSinceEpoch));
  await settle(tester);
}

void main() {
  testWidgets('作成: 空のニックネームはその場で注意し、API を呼ばない', (tester) async {
    final h = RoomHarness();
    await h.start(tester, '/new');
    await tapText(tester, '待ち合わせを作る');
    expect(find.text('ニックネームを入力してください'), findsOneWidget);
    expect(h.api.calls, isEmpty);
    expect(h.loc.permissionAsks, 0);
    expect(find.text('ニックネーム(相手に表示されます)'), findsOneWidget); // 画面は移らない
    await h.finish(tester);
  });

  testWidgets('作成: 429 はサーバーの文言、通信エラーは「通信エラーが発生しました」をその場で出す', (tester) async {
    final h = RoomHarness();
    await h.start(tester, '/new');
    h.api.createError = const ApiException('rate_limited', status: 429, message: '作りすぎです');
    await tester.enterText(find.byType(TextField), 'りょう');
    await tapText(tester, '待ち合わせを作る');
    expect(find.text('作りすぎです'), findsOneWidget);
    h.api.createError = const ApiException('network');
    await tapText(tester, '待ち合わせを作る');
    expect(find.text('通信エラーが発生しました'), findsOneWidget);
    h.api.createError = const ApiException('boom', status: 500);
    await tapText(tester, '待ち合わせを作る');
    expect(find.text('作成に失敗しました(boom)'), findsOneWidget);
    await h.finish(tester);
  });

  testWidgets('host の一連: 招待（コピー）→ 承認 → meet → 共有をやめる → 停止 → 新しく作る', (tester) async {
    final h = await openAsHost(tester);
    expect(h.loc.permissionAsks, 1); // 「待ち合わせを作る」のタップの中で許可を求めた
    expect(find.text('招待リンクを送ってください'), findsOneWidget);
    expect(find.text('$kProdBaseUrl/r/$kRoomId?invite=$kInvite'), findsOneWidget);
    expect(find.text('LINEで送る'), findsOneWidget);
    expect(find.text('共有する'), findsOneWidget);

    await tapText(tester, 'リンクをコピー');
    expect(h.clipboard, ['$kProdBaseUrl/r/$kRoomId?invite=$kInvite']);
    expect(find.text('コピーしました'), findsOneWidget);

    h.socket.push(stateMsg('waiting_host_approval', otherNick: 'すず'));
    await settle(tester);
    expect(find.textContaining('さんが参加しました。', findRichText: true), findsOneWidget);
    expect(h.socket.ofType('location'), isEmpty);
    h.loc.emit(35.6585, 139.7016);
    await settle(tester);
    expect(h.socket.ofType('location'), isEmpty); // 承認前は送らない

    await tapText(tester, 'この人と位置を共有する');
    expect(h.socket.ofType('approve'), hasLength(1));

    await toActive(tester, h);
    expect(find.text('会えた！'), findsOneWidget);
    expect(find.textContaining('123', findRichText: true), findsWidgets);
    expect(find.textContaining('相手の最終更新: '), findsOneWidget);
    expect(find.text('未確認'), findsOneWidget);
    expect(find.text('相手の位置を待っています…'), findsNothing);

    await tapText(tester, '共有をやめる');
    expect(find.text('位置の共有をやめますか？'), findsOneWidget);
    await tapText(tester, 'やめる');
    expect(h.socket.ofType('stop'), hasLength(1));

    h.socket.push(stateMsg('stopped', otherNick: 'すず', stopped: {'by': 'host', 'at': 1}));
    await settle(tester);
    expect(find.text('あなたが共有をやめたため、位置の共有は停止しました。'), findsOneWidget);
    await tapText(tester, '新しく待ち合わせを作る');
    expect(find.text('ニックネーム(相手に表示されます)'), findsOneWidget);
    expect(h.view.session, isNull);
    await h.finish(tester);
  });

  testWidgets('meet: 相手の位置が来たら 3D に2人を立て、1回だけ寄せる。お店を3件まで出す', (tester) async {
    final h = await openAsHost(tester);
    h.loc.emit(35.65905, 139.70058);
    await toActive(tester, h, distance: 40, bearing: 0);
    await settle(tester);
    expect(find.text('map3d me=true partner=すず route=null focus=1'), findsOneWidget);
    expect(find.text('カフェA'), findsOneWidget);
    expect(find.text('1階'), findsOneWidget);
    await toActive(tester, h, distance: 30, bearing: 10);
    expect(find.text('map3d me=true partner=すず route=null focus=1'), findsOneWidget);
    // 位置は active になってから送る（座標は core の location だけ）。room の操作に座標は入らない。
    for (final m in h.socket.sent.where((m) => m['type'] != 'location')) {
      expect(m.keys, isNot(contains('lat')));
    }
    await h.finish(tester);
  });

  testWidgets('状態バナー: 通信切れ（自動で再接続）> 自分が圏外 > 相手が古い', (tester) async {
    final h = await openAsHost(tester);
    final old = DateTime.now().millisecondsSinceEpoch - kLocationStaleMs - 1000;
    h.socket.push(stateMsg('active', otherNick: 'すず', distance: 50, bearing: 0, lastUpdatedAt: old));
    await settle(tester);
    expect(find.text('相手の位置が古くなっています'), findsOneWidget);

    h.loc.emit(35.6812, 139.7671); // 東京駅
    await settle(tester);
    expect(find.text('渋谷エリアの外なので共有を止めています'), findsOneWidget);
    expect(find.text('相手の位置が古くなっています'), findsNothing);

    final first = h.socket;
    first.serverClose(1006);
    await settle(tester);
    expect(find.textContaining('通信が切れました。位置が更新されていません(最終更新 '), findsOneWidget);
    await tester.pump(const Duration(seconds: 1)); // 1秒後に自動で再接続
    await settle(tester);
    expect(h.sockets, hasLength(2));
    expect(h.view.wsConnected, isTrue);
    await tester.pump(const Duration(seconds: 5)); // 5秒ごとの見直し
    expect(find.textContaining('通信が切れました'), findsNothing);
    await h.finish(tester);
  });

  testWidgets('会えた: 失敗の理由と残り回数を出し、found で「会えた! 87%」「Jev判定」', (tester) async {
    final h = await openAsHost(tester);
    await toActive(tester, h);
    await tapText(tester, '会えた！');
    expect(h.socket.ofType('judge'), hasLength(1));
    h.socket.push({'type': 'judgeResult', 'ok': false, 'reason': 'too_far', 'distance_m': 35});
    await settle(tester);
    expect(find.text('まだ20m以内に近づいていません(現在約35m)'), findsOneWidget);

    await tapText(tester, '会えた！');
    h.socket.push({'type': 'judgeResult', 'ok': false, 'reason': 'not_found', 'remainingJevCalls': 9});
    await settle(tester);
    expect(find.text('まだ判定できませんでした。相手の姿が見えたらもう一度押してください(残り9回)'), findsOneWidget);

    final hapticsBefore = h.haptics;
    h.socket.push(stateMsg('active', otherNick: 'すず', distance: 5, bearing: 0, judge: {
      'found': true,
      'probability': 0.87,
      'source': 'jev',
      'callsUsed': 2,
      'maxCalls': 10,
      'limitReached': false,
    }));
    await settle(tester);
    expect(find.text('会えた! 87%'), findsOneWidget);
    expect(find.text('Jev判定'), findsOneWidget);
    expect(h.haptics, greaterThan(hapticsBefore));
    await h.finish(tester);
  });

  testWidgets('待ち合わせ場所: ID だけ送り、決まったら道順の行き先にでき、消えたら相手に戻る', (tester) async {
    final h = await openAsHost(tester);
    h.loc.emit(35.65905, 139.70058);
    await toActive(tester, h);
    expect(find.text('まだ決めていません'), findsOneWidget);

    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await settle(tester);
    await tester.tap(find.text('モヤイ像').hitTestable().last);
    await settle(tester);
    await tapText(tester, 'ここで待ち合わせる');
    expect(h.socket.ofType('spot').single, {'type': 'spot', 'spotId': 'moyai'});

    h.socket.push(stateMsg('active',
        otherNick: 'すず', distance: 123, bearing: 90, meetSpot: {'id': 'moyai', 'byMe': true}));
    await settle(tester);
    expect(find.bySemanticsLabel('待ち合わせ場所：モヤイ像(あなたが決めました)'), findsOneWidget);

    await tapText(tester, '待ち合わせ場所へ道順で案内');
    expect(find.text('route-panel:モヤイ像'), findsOneWidget);
    expect(find.text('まっすぐの矢印に戻す'), findsOneWidget);

    h.socket.push(stateMsg('active', otherNick: 'すず', distance: 123, bearing: 90));
    await settle(tester);
    expect(find.text('route-panel:すず'), findsOneWidget);

    await tapText(tester, 'まっすぐの矢印に戻す');
    expect(find.textContaining('route-panel'), findsNothing);
    await h.finish(tester);
  });

  testWidgets('guest: 招待プレビュー → 空欄はその場で注意 → 参加 → 承認待ち', (tester) async {
    final h = RoomHarness();
    await h.start(tester, '/r/$kRoomId?invite=$kInvite');
    await settle(tester);
    expect(find.textContaining('さんから招待されました。', findRichText: true), findsOneWidget);
    await tapText(tester, '承認して参加');
    expect(find.text('ニックネームを入力してください'), findsOneWidget);
    expect(h.api.calls, ['preview']);

    await tester.enterText(find.byType(TextField), 'すず');
    await tapText(tester, '承認して参加');
    expect(h.api.calls, ['preview', 'join:すず']);
    expect(h.loc.permissionAsks, 1);
    h.socket.push(stateMsg('waiting_host_approval', role: 'guest', selfNick: 'すず', otherNick: 'りょう'));
    await settle(tester);
    expect(find.textContaining('さんの承認をお待ちください。', findRichText: true), findsOneWidget);
    expect(h.router.routeInformationProvider.value.uri.toString(), '/r/$kRoomId'); // 招待トークンを URL から外した
    await h.finish(tester);
  });

  testWidgets('guest: 参加の失敗（使用済みの招待）は行き止まり、それ以外はその場で', (tester) async {
    final h = RoomHarness();
    await h.start(tester, '/r/$kRoomId?invite=$kInvite');
    await settle(tester);
    h.api.joinError = const ApiException('boom', status: 500);
    await tester.enterText(find.byType(TextField), 'すず');
    await tapText(tester, '承認して参加');
    expect(find.text('参加に失敗しました(boom)'), findsOneWidget);
    h.api.joinError = const ApiException('full', status: 409);
    await tapText(tester, '承認して参加');
    expect(find.text('この待ち合わせはすでに満員です。'), findsOneWidget);
    expect(find.text('新しく待ち合わせを作る'), findsOneWidget);
    await h.finish(tester);
  });

  for (final (reason, text) in [
    ('full', 'この待ち合わせはすでに満員です。'),
    ('expired', 'この待ち合わせは終了しました(3時間経過)。位置情報のデータは削除されています。'),
    ('not_found', '待ち合わせが見つかりません。URLを確認してください。'),
    ('invalid_invite', 'この招待リンクは使えません。'),
    ('network', '通信エラーが発生しました'),
  ]) {
    testWidgets('プレビューの失敗 $reason は行き止まり', (tester) async {
      final h = RoomHarness();
      h.api.previewError = ApiException(reason);
      await h.start(tester, '/r/$kRoomId?invite=$kInvite');
      await settle(tester);
      expect(find.text(text), findsOneWidget);
      expect(find.text('新しく待ち合わせを作る'), findsOneWidget);
      expect(find.text('もう一度試す'), reason == 'network' ? findsOneWidget : findsNothing);
      await h.finish(tester);
    });
  }

  testWidgets('招待なしで開くと「招待リンクを開いてください」', (tester) async {
    final h = RoomHarness();
    await h.start(tester, '/r/$kRoomId');
    await settle(tester);
    expect(find.text('このリンクだけでは参加できません。招待リンクを開いてください。'), findsOneWidget);
    expect(h.api.calls, isEmpty);
    await h.finish(tester);
  });

  testWidgets('二重接続（4001）で閉じられたら案内し、「もう一度つなぐ」で接続し直す', (tester) async {
    final h = await openAsHost(tester);
    h.socket.serverClose(4001, 'duplicate_connection');
    await settle(tester);
    expect(find.text('別の画面でこの待ち合わせが開かれたため、こちらの接続を閉じました。'), findsOneWidget);
    await tapText(tester, 'もう一度つなぐ');
    await settle(tester);
    expect(h.sockets, hasLength(2));
    h.socket.push(stateMsg('waiting_guest'));
    await settle(tester);
    expect(find.text('招待リンクを送ってください'), findsOneWidget);
    expect(find.text('$kProdBaseUrl/r/$kRoomId?invite=$kInvite'), findsOneWidget); // 招待 URL も残る
    await h.finish(tester);
  });

  testWidgets('期限切れ（close 1000 expired）は期限切れの画面', (tester) async {
    final h = await openAsHost(tester);
    h.socket.serverClose(1000, 'expired');
    await settle(tester);
    expect(find.text('この待ち合わせは終了しました(3時間経過)。位置情報のデータは削除されています。'), findsOneWidget);
    await h.finish(tester);
  });
}
