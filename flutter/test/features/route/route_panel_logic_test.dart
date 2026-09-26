// 道順パネルの状態機械（route-panel.js の移植）の単体テスト: 表示の優先順・「◯階に着いた」の仮の位置・
// 到着の通知は1回だけ・再計算は3秒おき・行き先の名前が変わったら作り直す。
import 'package:flutter_test/flutter_test.dart';
import 'package:shibuya_machimachi/features/route/engine/route_engine.dart';
import 'package:shibuya_machimachi/features/route/route_panel_logic.dart';

import 'graph_helpers.dart';

PanelTarget target(RouteEndpoint p, {num? level, String name = 'ゴール'}) =>
    PanelTarget(lat: p.lat, lng: p.lng, level: level, name: name);

class Harness {
  Harness({String emptyText = '行き先を選んでください'}) {
    logic = RoutePanelLogic(
      emptyText: emptyText,
      nowMs: () => now,
      onLevelChange: levelChanges.add,
      onRoute: routes.add,
      onArrive: () => arrives++,
    );
  }
  late final RoutePanelLogic logic;
  int now = 0;
  final levelChanges = <int>[];
  final routes = <WalkRoute?>[];
  int arrives = 0;

  void self(RouteEndpoint p) => logic.setSelf(p.lat, p.lng);
  String get text => logic.view().instruction;
}

// 1階の道 → エスカレーター(東へ60→75m, 1階→2階) → 2階の道(〜140m)
RouteGraph escalatorGraph() => makeGraph([
      [0, 0],
      [0, 60],
      [0, 75],
      [0, 140],
    ], [
      [0, 1, EdgeType.walk, 0, 0],
      [1, 2, EdgeType.escalator, 0, 1],
      [2, 3, EdgeType.walk, 1, 1],
    ]);

void main() {
  test('表示の優先順: 読み込み中 → 失敗 → 現在地なし → 圏外 → 行き先なし → 経路が無い理由', () {
    final h = Harness();
    expect(h.text, '道のデータを読み込んでいます…');
    h.logic.setLoadError();
    expect(h.text, '道のデータを読み込めませんでした。通信を確かめて開き直してください');
    h.logic.setGraph(makeGraph([
      [0, 0],
      [0, 100],
    ], [
      [0, 1],
    ]));
    expect(h.text, '現在地を取得しています…(位置情報を許可してください)');
    h.self(at(3000, 0));
    expect(h.text, '渋谷エリア(駅から1.5km)の外なので、道順は出せません');
    h.self(at(0, 0));
    expect(h.text, '行き先を選んでください');
    h.logic.setTarget(target(at(1000, 0)));
    expect(h.text, '目的地の近くに歩ける道が見つかりません');
    expect(h.logic.view().bearingDeg, isNull, reason: '経路が無いときは矢印を薄くする');
    h.self(at(500, 500));
    expect(h.text, '近くに歩ける道が見つかりません(渋谷駅から1.5km以内で使えます)');
  });

  test('人モードの行き先なしは「相手の位置を待っています…」', () {
    final h = Harness(emptyText: '相手の位置を待っています…');
    h.logic.setGraph(escalatorGraph());
    h.self(at(0, 0));
    expect(h.text, '相手の位置を待っています…');
  });

  test('「◯階に着いた」: 階を1つ上げて通知し、GPSが15m動くまではエスカレーターの上端にいるものとして案内する', () {
    final h = Harness();
    h.logic.setGraph(escalatorGraph());
    h.self(at(0, 55));
    h.logic.setTarget(target(at(0, 140), level: 1));
    var v = h.logic.view();
    expect(v.destName, 'ゴール');
    expect(v.destFloor, ' 2階');
    expect(v.instruction, 'エスカレーターで2階へ');
    expect(v.floorChange, isTrue);
    expect(v.confirmLabel, '2階に着いた');
    expect(v.remaining, '残り85m・約1分');
    expect(v.bearingDeg, isNotNull);

    h.logic.confirmFloor();
    expect(h.levelChanges, [1]);
    expect(h.logic.level, 1);
    v = h.logic.view();
    expect(v.instruction, 'あと65mで到着', reason: 'エスカレーターの上端(75m)から');
    expect(v.floorChange, isFalse);
    expect(v.confirmLabel, isNull);

    // 館内でGPSが少しぶれただけ(5m)なら、仮の位置のまま
    h.self(at(0, 60));
    expect(h.text, 'あと65mで到着');
    // 15m以上動いたら本物のGPSに戻す
    h.self(at(0, 90));
    expect(h.text, 'あと50mで到着');
  });

  test('外から階が変わったら(チップ・部屋の同期)、その階から計算し直す', () {
    final h = Harness();
    h.logic.setGraph(escalatorGraph());
    h.self(at(0, 90));
    h.logic.setTarget(target(at(0, 140), level: 1));
    expect(h.routes, hasLength(1));
    h.logic.setLevel(1);
    expect(h.routes, hasLength(2), reason: '階が変わったら3秒待たずに計算し直す');
    expect(h.levelChanges, isEmpty, reason: '外からの変更は onLevelChange に返さない');
    h.logic.setLevel(1);
    expect(h.routes, hasLength(2), reason: '同じ階なら何もしない');
  });

  test('到着の通知は到着した瞬間に1回だけ(離れてまた着いたらもう1回)', () {
    final h = Harness();
    h.logic.setGraph(makeGraph([
      [0, 0],
      [0, 100],
    ], [
      [0, 1, EdgeType.walk, 0, 0],
    ]));
    h.self(at(0, 0));
    h.logic.setTarget(target(at(0, 100), level: 0));
    expect(h.arrives, 0);
    h.self(at(0, 95));
    expect(h.arrives, 1);
    final v = h.logic.view();
    expect(v.arrived, isTrue);
    expect(v.instruction, '到着しました！');
    expect(v.remaining, '');
    expect(v.bearingDeg, isNull);
    h.self(at(0, 96));
    expect(h.arrives, 1);
    h.self(at(0, 50));
    expect(h.logic.view().arrived, isFalse);
    h.self(at(0, 95));
    expect(h.arrives, 2);
  });

  test('経路から外れても、再計算は3秒おき', () {
    final h = Harness();
    h.logic.setGraph(makeGraph([
      [0, 0],
      [0, 200],
      [60, 100],
      [0, 100],
    ], [
      [0, 3],
      [3, 1],
      [3, 2],
    ]));
    h.self(at(0, 0));
    h.logic.setTarget(target(at(0, 200)));
    expect(h.routes, hasLength(1));
    h.now = 1000;
    h.self(at(55, 100));
    expect(h.routes, hasLength(1), reason: '前の計算から1秒なので計算し直さない');
    expect(h.logic.guidance!.offRoute, isTrue);
    h.now = 3500;
    h.self(at(55, 100));
    expect(h.routes, hasLength(2));
    expect(h.logic.guidance!.offRoute, isFalse, reason: '外れた位置から計算し直すと、また経路の上');
  });

  test('行き先: 同じ名前で20m未満の移動は計算し直さず、20m超・名前の変更・取り消しで作り直す', () {
    final h = Harness();
    h.logic.setGraph(makeGraph([
      [0, 0],
      [0, 200],
    ], [
      [0, 1],
    ]));
    h.self(at(0, 0));
    h.logic.setTarget(target(at(0, 200), name: 'A'));
    expect(h.routes, hasLength(1));
    h.now = 5000;
    h.logic.setTarget(target(at(0, 190), name: 'A'));
    expect(h.routes, hasLength(1), reason: '10mの移動');
    h.logic.setTarget(target(at(0, 170), name: 'A'));
    expect(h.routes, hasLength(2), reason: '30mの移動');
    h.now = 5100;
    h.logic.setTarget(target(at(0, 170), name: 'B'));
    expect(h.routes, hasLength(3), reason: '名前が変われば別の目的地(3秒待たない)');
    h.logic.setTarget(target(at(0, 170), level: 1, name: 'B'));
    expect(h.routes, hasLength(3), reason: '階が変わっても3秒以内は待つ');
    h.now = 9000;
    h.self(at(0, 1));
    expect(h.routes, hasLength(4), reason: '3秒たてば階の変化で計算し直す');
    h.logic.setTarget(null);
    expect(h.routes.last, isNull, reason: '行き先を外したら線も消す');
    expect(h.text, '行き先を選んでください');
  });

  test('levelToValidFloorLabel: チップに無い階は null', () {
    expect(levelToValidFloorLabel(0), '1F');
    expect(levelToValidFloorLabel(-5), 'B5');
    expect(levelToValidFloorLabel(9), '10F');
    expect(levelToValidFloorLabel(10), isNull);
    expect(levelToValidFloorLabel(-6), isNull);
  });
}
