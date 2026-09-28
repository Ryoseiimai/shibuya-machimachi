// 道順案内エンジン（lib/features/route/engine/route_engine.dart）の単体テスト。
// worker/test/route.test.js の15件の移植。渋谷駅付近に「北へ◯m・東へ◯m」で置いた小さな合成グラフで、
// 最短経路・階をまたぐ経路・到達不能・次の経由点（矢印の向き）・案内文・再計算（経路から外れた判定）・
// 到着判定を確かめる。
import 'package:flutter_test/flutter_test.dart';
import 'package:shibuya_machimachi/core/core.dart';
import 'package:shibuya_machimachi/features/route/engine/route_engine.dart';

import 'graph_helpers.dart';

void main() {
  test('階の表記: OSMの階(0=1階) ⇔ 画面の階(1F/B1) ⇔ 日本語', () {
    expect(levelLabel(0), '1階');
    expect(levelLabel(1), '2階');
    expect(levelLabel(-1), '地下1階');
    expect(floorLabelToLevel('1F'), 0);
    expect(floorLabelToLevel('10F'), 9);
    expect(floorLabelToLevel('B3'), -3);
    expect(floorLabelToLevel('0F'), isNull);
    expect(floorLabelToLevel('x'), isNull);
    expect(levelToFloorLabel(0), '1F');
    expect(levelToFloorLabel(-2), 'B2');
  });

  test('案内文: 階の移動は手段と行き先の階を言う(分からないときは上下だけ/手段だけ)', () {
    expect(floorChangeText('escalator', 1), 'エスカレーターで2階へ');
    expect(floorChangeText('steps', -1), '階段で地下1階へ');
    expect(floorChangeText('elevator', 2), 'エレベーターで3階へ');
    expect(floorChangeText('walk', 0), '1階へ進む');
    expect(floorChangeText('steps', null, 'down'), '階段で下の階へ');
    expect(floorChangeText('escalator', null, null), 'エスカレーターに乗る');
    expect(formatDistance(23), '25m');
    expect(formatDistance(3), '5m');
    expect(formatDistance(247), '250m');
    expect(formatDistance(1234), '1.2km');
    expect(remainingText(240), '残り240m・約3分');
  });

  test('decodeGraph: 長さを計算し、一方通行は逆向きの弧を作らない', () {
    final g = makeGraph([
      [0, 0],
      [0, 100],
      [100, 100],
    ], [
      [0, 1],
      [1, 2, EdgeType.escalator, 0, 1, kEdgeFlagOneway],
    ]);
    expect(g.nodeCount, 3);
    expect(g.edgeCount, 2);
    expect((g.elen[0] - 100).abs() < 0.5, isTrue, reason: '約100m(${g.elen[0]})');
    // ノード2から出る弧は無い(1→2の一方通行だけ)
    expect(g.adjStart[3] - g.adjStart[2], 0);
    expect(() => decodeGraph({'nodes': [1], 'edges': []}), throwsFormatException);
  });

  test('snapToGraph: いちばん近い道に吸着し、階が分かれば同じ階の道を優先する', () {
    // 同じ場所に1階の道(0-1)と地下1階の道(2-3)が重なっている駅のような状況
    final g = makeGraph([
      [0, 0],
      [0, 100],
      [2, 0],
      [2, 100],
    ], [
      [0, 1, EdgeType.walk, 0, 0],
      [2, 3, EdgeType.walk, -1, -1],
    ]);
    final p = at(1, 50);
    final onGround = snapToGraph(g, p.lat, p.lng, level: 0)!;
    final underground = snapToGraph(g, p.lat, p.lng, level: -1)!;
    expect(onGround.edge, 0);
    expect(underground.edge, 1);
    expect((onGround.t - 0.5).abs() < 0.01, isTrue);
    final far = at(2000, 0);
    expect(snapToGraph(g, far.lat, far.lng), isNull, reason: '遠すぎる点は吸着しない');
  });

  test('findRoute: 2本の道のうち短い方を選ぶ(A*)', () {
    // 0→1→3 は約141m(斜め2本)、0→2→3 は遠回り(北に200m上がってから戻る)
    final g = makeGraph([
      [0, 0],
      [50, 50],
      [200, 0],
      [0, 100],
    ], [
      [0, 1],
      [1, 3],
      [0, 2],
      [2, 3],
    ]);
    final route = mustRoute(g, at(0, 0), at(0, 100));
    expect(route.totalM < 150, isTrue, reason: '短い方(約141m): ${route.totalM}');
    expect(route.points.length, 3);
    expect(routeLineCoordinates(route).length, 3);
  });

  test('findRoute: 一方通行のエスカレーターは逆向きに使わない(遠回りの階段を選ぶ)', () {
    // 1階(0)の道 0-1、上り専用エスカレーター 1→2(0→1)、2階の道 2-3、遠回りの階段 3-4-0
    final g = makeGraph([
      [0, 0],
      [0, 50],
      [0, 60],
      [0, 110],
      [80, 60],
    ], [
      [0, 1, EdgeType.walk, 0, 0],
      [1, 2, EdgeType.escalator, 0, 1, kEdgeFlagOneway],
      [2, 3, EdgeType.walk, 1, 1],
      [3, 4, EdgeType.steps, 1, 0],
      [4, 0, EdgeType.walk, 0, 0],
    ]);
    final up = mustRoute(g, at(0, 0, 0), at(0, 110, 1));
    expect(up.segments.any((s) => s.type == EdgeType.escalator), isTrue, reason: '上りはエスカレーター');
    final down = mustRoute(g, at(0, 110, 1), at(0, 0, 0));
    expect(down.segments.any((s) => s.type == EdgeType.escalator), isFalse, reason: '下りでは上り専用エスカレーターを使わない');
    expect(down.segments.any((s) => s.type == EdgeType.steps), isTrue, reason: '下りは階段');
  });

  test('findRoute: つながっていない道・遠すぎる出発点は到達不能として理由を返す', () {
    final g = makeGraph([
      [0, 0],
      [0, 100],
      [300, 0],
      [300, 100],
    ], [
      [0, 1],
      [2, 3],
    ]);
    final unreachable = findRoute(g, at(0, 10), at(300, 90));
    expect(unreachable.ok, isFalse);
    expect(unreachable.reason, RouteFailure.unreachable);
    expect(unreachable.reason!.wire, 'unreachable');
    expect(findRoute(g, at(3000, 0), at(0, 90)).reason, RouteFailure.noStart);
    expect(findRoute(g, at(0, 10), at(3000, 0)).reason, RouteFailure.noGoal);
  });

  test('階をまたぐ経路: エスカレーターで上がる区間を「エスカレーターで2階へ」と案内し、近づくと着いたボタンを出す', () {
    final g = makeGraph([
      [0, 0],
      [0, 60],
      [0, 75],
      [0, 140],
    ], [
      [0, 1, EdgeType.walk, 0, 0],
      [1, 2, EdgeType.escalator, 0, 1],
      [2, 3, EdgeType.walk, 1, 1],
    ]);
    final route = mustRoute(g, at(0, 0, 0), at(0, 140, 1));
    final floor = route.maneuvers.firstWhere((m) => m.kind == ManeuverKind.floor);
    expect(floor.via, 'escalator');
    expect(floor.toLevel, 1);
    expect(route.destination.level, 1);

    final far = guideAt(route, at(0, 0), level: 0);
    expect(far.instruction.text, matches(RegExp(r'^60m先、エスカレーターで2階へ$')));
    expect(far.floorPrompt, isNull);

    final near = guideAt(route, at(0, 55), level: 0);
    expect(near.instruction.text, 'エスカレーターで2階へ');
    expect(near.floorPrompt!.toLevel, 1);
    expect(near.floorPrompt!.via, 'escalator');
    // 着いたボタンを押した後に案内を続ける地点 = エスカレーターの上端(東へ75m)
    final top = at(0, 75);
    expect((near.floorPrompt!.endLat - top.lat).abs() < 1e-6, isTrue);
    expect((near.floorPrompt!.endLng - top.lng).abs() < 1e-6, isTrue);

    // 2階に着いた(階を直した)ら、その先の案内=到着までの案内になる
    final upstairs = guideAt(route, at(0, 90), level: 1);
    expect(upstairs.instruction.kind, ManeuverKind.arrive);
    expect(upstairs.instruction.text, contains('到着'));
  });

  test('階をまたぐ経路: 地上から階段で地下へ下りる区間を「階段で地下1階へ」と案内する', () {
    final g = makeGraph([
      [0, 0],
      [0, 40],
      [0, 50],
      [0, 120],
    ], [
      [0, 1, EdgeType.walk, 0, 0],
      [1, 2, EdgeType.steps, 0, -1],
      [2, 3, EdgeType.walk, -1, -1],
    ]);
    final route = mustRoute(g, at(0, 0, 0), at(0, 120, -1));
    final floor = route.maneuvers.firstWhere((m) => m.kind == ManeuverKind.floor);
    expect(floor.via, 'steps');
    expect(floor.toLevel, -1);
    expect(guideAt(route, at(0, 38), level: 0).instruction.text, '階段で地下1階へ');
  });

  test('地上どうしで数字が飛ぶだけ(建物ごとの階の数え方の違い)では、嘘の階移動を案内しない', () {
    // 道(0) → 建物の通路(level 3。描いた人の数え方で3になっているだけ) → 道(0)
    final g = makeGraph([
      [0, 0],
      [0, 50],
      [0, 100],
      [0, 150],
    ], [
      [0, 1, EdgeType.walk, 0, 0],
      [1, 2, EdgeType.walk, 3, 3],
      [2, 3, EdgeType.walk, 0, 0],
    ]);
    final route = mustRoute(g, at(0, 0, 0), at(0, 150, 0));
    expect(route.maneuvers.where((m) => m.kind == ManeuverKind.floor), isEmpty);
    expect(route.destination.level, 0);
  });

  test('両端の階が推測の階段は、上り/下りを言わず「階段を通る」とだけ案内する', () {
    final g = makeGraph([
      [0, 0],
      [0, 40],
      [0, 50],
      [0, 120],
    ], [
      [0, 1, EdgeType.walk, 0, 0],
      [1, 2, EdgeType.steps, 0, 1, kEdgeFlagLevelGuessed],
      [2, 3, EdgeType.walk, 1, 1],
    ]);
    final route = mustRoute(g, at(0, 0, 0), at(0, 120, 0));
    final floor = route.maneuvers.firstWhere((m) => m.kind == ManeuverKind.floor);
    expect(floor.toLevel, isNull);
    expect(floor.direction, isNull);
    expect(guideAt(route, at(0, 38), level: 0).instruction.text, '階段を通る');
  });

  test('矢印は目的地への直線ではなく、歩ける道に沿った次の経由点を指す', () {
    // 東へ100m進んでから北へ100m(目的地は北東。直線の方角は約45度だが、まず東(90度)へ進む道)
    final g = makeGraph([
      [0, 0],
      [0, 100],
      [100, 100],
    ], [
      [0, 1],
      [1, 2],
    ]);
    final route = mustRoute(g, at(0, 0), at(100, 100));
    final g0 = guideAt(route, at(0, 0), level: 0);
    expect((g0.bearingDeg - 90).abs() < 2, isTrue, reason: '東を指す: ${g0.bearingDeg}');
    expect(g0.instruction.kind, ManeuverKind.turn);
    expect(g0.instruction.text, '100m先を左');
    expect((g0.remainingM - 200).abs() < 2, isTrue, reason: '残り約200m: ${g0.remainingM}');
    // 角を曲がった後は北を指す
    final g1 = guideAt(route, at(30, 100), level: 0);
    expect(g1.bearingDeg.abs() < 2 || (g1.bearingDeg - 360).abs() < 2, isTrue, reason: '北を指す: ${g1.bearingDeg}');
  });

  test('経路から25m以上外れたら再計算の合図(offRoute)を出す', () {
    final g = makeGraph([
      [0, 0],
      [0, 200],
    ], [
      [0, 1],
    ]);
    final route = mustRoute(g, at(0, 0), at(0, 200));
    expect(guideAt(route, at(10, 100), level: 0).offRoute, isFalse);
    expect(guideAt(route, at(kOffRouteM + 5, 100), level: 0).offRoute, isTrue);
    // 外れた位置から計算し直すと、また経路の上(offRoute=false)になる
    final g2 = makeGraph([
      [0, 0],
      [0, 200],
      [60, 100],
      [0, 100],
    ], [
      [0, 3],
      [3, 1],
      [3, 2],
    ]);
    final rerouted = mustRoute(g2, at(55, 100), at(0, 200));
    expect(guideAt(rerouted, at(55, 100), level: 0).offRoute, isFalse);
  });

  test('到着判定: 同じ階で15m以内なら到着、階が違えば到着にしない', () {
    final g = makeGraph([
      [0, 0],
      [0, 100],
    ], [
      [0, 1, EdgeType.walk, 0, 0],
    ]);
    final route = mustRoute(g, at(0, 0, 0), at(0, 100, 0));
    expect(guideAt(route, at(0, 100 - kArrivalM + 3), level: 0).arrived, isTrue);
    expect(guideAt(route, at(0, 100 - kArrivalM - 10), level: 0).arrived, isFalse);
    expect(guideAt(route, at(0, 95), level: 2).arrived, isFalse, reason: '真上の別の階にいるときは到着ではない');
    expect(guideAt(route, at(0, 95), level: 0).instruction.text, '到着しました');
  });

  test('parsePlaces: 形式の正しい場所だけを残す(idは英小文字・数字・ハイフン)', () {
    final places = parsePlaces({
      'places': [
        {'id': 'hachiko', 'name': 'ハチ公像', 'lat': 35.659, 'lng': 139.7006, 'level': 0, 'hint': '広場'},
        {'id': 'Bad ID', 'name': 'x', 'lat': 1, 'lng': 2},
        {'id': 'nolevel', 'name': 'x', 'lat': 35.6, 'lng': 139.7},
        {'id': 'nan', 'name': 'x', 'lat': '35', 'lng': 139.7},
      ],
    });
    expect(places.map((p) => p.id).toList(), ['hachiko', 'nolevel']);
    expect(places[1].level, 0, reason: '階が無ければ地上(0)');
    expect(() => parsePlaces(<String, Object>{}), throwsFormatException);
  });

  // ---- ここから Dart 移植で足したもの（JS と丸め・並びがずれないこと） ----

  test('formatDistance / remainingText は JS の Math.round と同じ丸め（.5 は切り上げ）', () {
    expect(formatDistance(2.5), '5m');
    expect(formatDistance(12.5), '15m'); // 12.5/5 = 2.5 → 3
    expect(formatDistance(105), '110m'); // 10.5 → 11
    expect(formatDistance(-3), '5m');
    expect(formatDistance(999), '1000m');
    expect(formatDistance(1000), '1.0km');
    expect(remainingText(0), '残り5m・約1分');
    expect(remainingText(200), '残り200m・約3分'); // 2.5 → 3
  });

  test('横断歩道と曲がり角の案内文', () {
    // 東へ50m → 横断歩道で東へ20m → 北へ曲がって50m
    final g = makeGraph([
      [0, 0],
      [0, 50],
      [0, 70],
      [50, 70],
    ], [
      [0, 1],
      [1, 2, EdgeType.crossing],
      [2, 3],
    ]);
    final route = mustRoute(g, at(0, 0), at(50, 70));
    final kinds = route.maneuvers.map((m) => m.kind).toList();
    expect(kinds, [ManeuverKind.crossing, ManeuverKind.turn, ManeuverKind.arrive]);
    expect(guideAt(route, at(0, 0), level: 0).instruction.text, '50m先で横断歩道を渡る');
    expect(guideAt(route, at(0, 45), level: 0).instruction.text, '横断歩道を渡る');
    expect(guideAt(route, at(0, 60), level: 0).instruction.text, '10m先を左');
    expect(guideAt(route, at(20, 70), level: 0).instruction.text, 'あと30mで到着');
  });
}
