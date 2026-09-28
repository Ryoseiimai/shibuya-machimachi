// 統合: 人モードの道順が出たら AR に「次の曲がり角」を渡し、道順を消す・部屋を出ると AR の道順も消える。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shibuya_machimachi/core/core.dart';
import 'package:shibuya_machimachi/features/room/src/meet_slots.dart';

import 'room_harness.dart';

const _line = [GeoPoint(35.65905, 139.70058), GeoPoint(35.65950, 139.70100)];

void main() {
  testWidgets('道順 ON で AR に道順を渡し、OFF と退室で消す', (tester) async {
    final base = fakeSlots();
    final h = RoomHarness(
      slots: MeetSlots(
        map3d: base.map3d,
        routePanel: (context, target, onRoute, onArrive) => TextButton(
          onPressed: () => onRoute(_line),
          child: Text('emit-route:${target?.name ?? '-'}'),
        ),
      ),
    );
    await h.start(tester, '/new');
    await tester.enterText(find.byType(TextField), 'りょう');
    await tester.tap(find.text('待ち合わせを作る'));
    await settle(tester);
    h.loc.emit(35.65905, 139.70058);
    h.socket.push(stateMsg('active',
        otherNick: 'すず', distance: 123, bearing: 90, lastUpdatedAt: DateTime.now().millisecondsSinceEpoch));
    await settle(tester);

    expect(h.container.read(arGuideProvider), isNull);
    await tester.tap(find.text('道順で案内（歩ける道に沿った矢印）'));
    await settle(tester);
    await tester.tap(find.text('emit-route:すず'));
    await settle(tester);
    final g = h.container.read(arGuideProvider);
    expect(g, isNotNull);
    expect(g!.route, _line);
    expect(g.destinationName, 'すず');

    await tester.tap(find.text('まっすぐの矢印に戻す'));
    await settle(tester);
    expect(h.container.read(arGuideProvider), isNull);

    // もう一度出してから部屋を出ると消える。
    await tester.tap(find.text('道順で案内（歩ける道に沿った矢印）'));
    await settle(tester);
    await tester.tap(find.text('emit-route:すず'));
    await settle(tester);
    expect(h.container.read(arGuideProvider), isNotNull);
    await h.ctrl.leave();
    expect(h.container.read(arGuideProvider), isNull);
    await h.finish(tester);
  });
}
