// 同梱の道のデータ（assets/route/graph.json・places.json）の検査。worker/test/route-data.test.js の移植に、
// Web 版 route.js との突き合わせ（fixtures/route_js_expected.json。作り方は fixtures/gen_route_js_expected.mjs）を足したもの。
// 版の印・定番スポット13か所の全組み合わせ(156組)で道順が出ること・渋谷駅の地下↔地上で階の移動を案内することを確かめる。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shibuya_machimachi/core/core.dart';
import 'package:shibuya_machimachi/features/route/engine/route_engine.dart';

const _maxGraphBytes = 3 * 1024 * 1024;
const _maxPlaceSnapM = 25.0;

// 渋谷駅東側の地下3階の通路（OSM: level=-3 の歩道。E2E の「階の移動」画面と同じ地点）
const _b3 = RouteEndpoint(lat: 35.658588, lng: 139.702834, level: -3);

RouteEndpoint _ep(Place p) => RouteEndpoint(lat: p.lat, lng: p.lng, level: p.level, name: p.name);

void main() {
  // flutter test は flutter/ で動くので、アセットはファイルとして直接読む（rootBundle を通さない）。
  final graphText = File(kAssetGraph).readAsStringSync();
  final graphJson = jsonDecode(graphText) as Map<String, dynamic>;
  final placesJson = jsonDecode(File(kAssetPlaces).readAsStringSync()) as Map<String, dynamic>;
  final graph = decodeGraphText(graphText);
  final places = parsePlaces(placesJson);
  final byId = {for (final p in places) p.id: p};

  test('graph.json / places.json の版の印が定数と一致する', () {
    expect(graphJson['version'], kRouteGraphVersion);
    expect(graph.version, kRouteGraphVersion);
    expect(placesJson['version'], kPlacesVersion);
  });

  test('graph.json: 出典(OSM/ODbL)付き・3MB以内・規模', () {
    expect(graphJson['attribution'], contains('OpenStreetMap contributors'));
    expect(graphJson['attribution'], contains('ODbL'));
    expect(graphText.length, lessThan(_maxGraphBytes));
    expect(graph.nodeCount, greaterThan(1000));
    expect(graph.edgeCount, greaterThan(1000));
  });

  test('places.json: 13件・IDの重複なし・全部が歩ける道の近くにある', () {
    expect(places.length, 13);
    expect(places.map((p) => p.id).toSet().length, places.length);
    expect(places.length, (placesJson['places'] as List).length, reason: '形式の不正な場所が混ざっていない');
    for (final p in places) {
      final s = snapToGraph(graph, p.lat, p.lng, level: p.level);
      expect(s, isNotNull, reason: p.name);
      expect(s!.distanceM, lessThanOrEqualTo(_maxPlaceSnapM), reason: '${p.name} は道から${s.distanceM}m');
    }
  });

  test('定番スポットどうしは、どの組み合わせ(156組)でも道順が見つかる', () {
    var count = 0;
    for (final a in places) {
      for (final b in places) {
        if (identical(a, b)) continue;
        final r = findRoute(graph, _ep(a), _ep(b));
        expect(r.ok, isTrue, reason: '${a.name} → ${b.name}: ${r.reason?.wire}');
        count++;
      }
    }
    expect(count, 156);
  });

  test('ハチ公像 → モヤイ像: 歩ける道に沿った数百mの道順', () {
    final r = findRoute(graph, _ep(byId['hachiko']!), _ep(byId['moyai']!));
    expect(r.ok, isTrue);
    expect(r.route!.totalM, inExclusiveRange(150, 700));
    final h = byId['hachiko']!;
    final g = guide(r.route!, h.lat, h.lng, level: 0);
    expect(g.arrived, isFalse);
    expect(g.offRoute, isFalse);
    expect(g.instruction.text, matches(RegExp(r'm先|へ|到着')));
  });

  test('渋谷駅の地下3階 → ハチ公像: 階の移動(地下→地上)を「◯◯で◯階へ」と案内する', () {
    final r = findRoute(graph, _b3, _ep(byId['hachiko']!));
    expect(r.ok, isTrue);
    final floors = r.route!.maneuvers.where((m) => m.kind == ManeuverKind.floor).toList();
    expect(floors, isNotEmpty, reason: '階の移動の案内がある');
    expect(floors.any((m) => m.toLevel == 0), isTrue, reason: '最後は1階(地上)へ');
    final first = guide(r.route!, _b3.lat, _b3.lng, level: -3);
    expect(first.instruction.text, matches(RegExp(r'(エスカレーター|階段|エレベーター)で(地下\d+|\d+)階へ')));
  });

  group('Web 版 route.js と同じ結果になる（fixtures/route_js_expected.json）', () {
    final expected = jsonDecode(File('test/features/route/fixtures/route_js_expected.json').readAsStringSync()) as Map<String, dynamic>;

    test('期待値は同じ版の graph.json から作られている', () {
      expect(expected['graphVersion'], kRouteGraphVersion);
      expect((expected['pairs'] as List).length, 156);
    });

    void checkRoute(Map<String, dynamic> e, RouteEndpoint from, RouteEndpoint to) {
      final label = '${e['from']} → ${e['to']}';
      final r = findRoute(graph, from, to);
      expect(r.ok, e['ok'], reason: label);
      final route = r.route!;
      expect(route.totalM, closeTo((e['totalM'] as num).toDouble(), 0.01), reason: '$label totalM');
      expect(route.points.length, e['pointCount'], reason: '$label 点の数');
      expect(route.destination.level, e['destinationLevel'], reason: '$label 到着の階');
      final ms = e['maneuvers'] as List;
      expect(route.maneuvers.length, ms.length, reason: '$label 案内地点の数');
      for (var i = 0; i < ms.length; i++) {
        final em = ms[i] as Map<String, dynamic>;
        final m = route.maneuvers[i];
        final where = '$label maneuver[$i]';
        expect(m.kind.name, em['kind'], reason: where);
        expect(m.index, em['index'], reason: where);
        expect(m.alongM, closeTo((em['alongM'] as num).toDouble(), 0.01), reason: where);
        if (m.kind == ManeuverKind.floor) {
          expect(m.via, em['via'], reason: where);
          expect(m.toLevel, em['toLevel'], reason: where);
          expect(m.direction, em['direction'], reason: where);
        }
        if (m.kind == ManeuverKind.turn) {
          expect(m.label, em['label'], reason: where);
          expect(m.crossing, em['crossing'], reason: where);
        }
      }
      for (final p in (e['probes'] as List).cast<Map<String, dynamic>>()) {
        final g = guide(route, (p['lat'] as num).toDouble(), (p['lng'] as num).toDouble(), level: p['level'] as num);
        final where = '$label probe(${p['text']})';
        expect(g.instruction.text, p['text'], reason: where);
        expect(g.instruction.kind.name, p['kind'], reason: where);
        expect(g.arrived, p['arrived'], reason: where);
        expect(g.offRoute, p['offRoute'], reason: where);
        // 区間の境目（ノードの真上）では前後の区間が同じ距離になり、sin/cos の最下位ビットの差で
        // どちらを選ぶかが JS とずれうる（道のり・案内文は同じ）。1つ違いまでは許す。
        expect((g.progressIndex - (p['progressIndex'] as int)).abs(), lessThanOrEqualTo(1), reason: where);
        expect(g.remainingM, closeTo((p['remainingM'] as num).toDouble(), 0.01), reason: where);
        expect(remainingText(g.remainingM), p['remainingText'], reason: where);
        final fp = p['floorPrompt'] as Map<String, dynamic>?;
        if (fp == null) {
          expect(g.floorPrompt, isNull, reason: where);
        } else {
          expect(g.floorPrompt?.toLevel, fp['toLevel'], reason: where);
          expect(g.floorPrompt?.via, fp['via'], reason: where);
        }
        // 方位は 0/360 の境目を考えて比べる
        final db = (g.bearingDeg - (p['bearingDeg'] as num)).abs();
        expect(db < 0.01 || (db - 360).abs() < 0.01, isTrue, reason: '$where bearing ${g.bearingDeg} vs ${p['bearingDeg']}');
      }
    }

    test('156組の経路・案内地点・案内文・残り・矢印の向きが一致する', () {
      for (final e in (expected['pairs'] as List).cast<Map<String, dynamic>>()) {
        checkRoute(e, _ep(byId[e['from']]!), _ep(byId[e['to']]!));
      }
    });

    test('地下3階 → ハチ公像も一致する', () {
      final e = expected['b3'] as Map<String, dynamic>;
      checkRoute(e, _b3, _ep(byId['hachiko']!));
      final r = findRoute(graph, _b3, _ep(byId['hachiko']!));
      expect(guide(r.route!, _b3.lat, _b3.lng, level: -3).instruction.text, e['firstText']);
    });
  });
}
