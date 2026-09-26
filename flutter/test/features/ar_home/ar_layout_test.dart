// AR の配置計算（ar.js の render() と同じ値になること）・階の差バッジ・道順の次の点。
import 'dart:ui' show Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:shibuya_machimachi/core/core.dart';
import 'package:shibuya_machimachi/features/ar_home/ar_layout.dart';

const me = GeoPoint(35.6590, 139.7005);
const size = Size(400, 800);

ArTarget targetAt(double bearing, double dist, {String name = 'たかし', String? floor}) =>
    ArTarget(point: destinationPoint(me.lat, me.lng, bearing, dist), name: name, floorLabel: floor);

void main() {
  group('定数は ar.js と同じ', () {
    test('値', () {
      expect(kDefaultFovDegrees, 60);
      expect(kArHorizontalMarginRatio, 0.42);
      expect(kArBaseYRatio, 0.56);
      expect(kArVerticalPxPerDeg, 4);
      expect(kArVerticalOffsetClamp, 160);
      expect(kArSizeScaleConst, 2600);
      expect(kArSizeMinPx, 26);
      expect(kArSizeMaxPx, 200);
    });
  });

  group('computeArOverlay', () {
    test('正面・傾き90°: 画面の中央、足元は高さ×0.56', () {
      final o = computeArOverlay(size: size, me: me, target: targetAt(40, 100), headingDeg: 40, betaDeg: 90);
      expect(o, isA<ArPerson>());
      final p = o as ArPerson;
      expect(p.x, closeTo(200, 0.5));
      expect(p.y, closeTo(800 * 0.56, 1e-9));
      expect(p.widthPx, closeTo(26, 0.5)); // 2600/100 = 26
      expect(p.heightPx, closeTo(52, 1));
      expect(p.name, 'たかし');
      expect(p.distanceText, 'あと100m');
    });

    test('右へ30°（視野の端）: x = W/2 + W×0.42', () {
      final p =
          computeArOverlay(size: size, me: me, target: targetAt(30, 50), headingDeg: 0.2, betaDeg: 90) as ArPerson;
      expect(p.relativeDeg, closeTo(29.8, 0.1));
      expect(p.x, closeTo(200 + 400 * 0.42 * (29.8 / 30), 1));
    });

    test('左へ15°: x = W/2 − W×0.42×0.5', () {
      final p = computeArOverlay(size: size, me: me, target: targetAt(345, 50), headingDeg: 0, betaDeg: 90) as ArPerson;
      expect(p.x, closeTo(200 - 400 * 0.42 * 0.5, 1));
    });

    test('傾き: 1°あたり4px、±160 で止まる', () {
      double yFor(double beta) =>
          (computeArOverlay(size: size, me: me, target: targetAt(0, 50), headingDeg: 0, betaDeg: beta) as ArPerson).y;
      expect(yFor(100), closeTo(448 + 40, 1e-9));
      expect(yFor(80), closeTo(448 - 40, 1e-9));
      expect(yFor(200), closeTo(448 + 160, 1e-9));
      expect(yFor(-30), closeTo(448 - 160, 1e-9));
    });

    test('傾きが取れないときは 90°（中立）とみなす', () {
      final p = computeArOverlay(size: size, me: me, target: targetAt(0, 50), headingDeg: 0) as ArPerson;
      expect(p.y, closeTo(448, 1e-9));
    });

    test('大きさ: 2600/距離 を 26〜200 に収める', () {
      double w(double dist) => (computeArOverlay(
        size: size,
        me: me,
        target: targetAt(0, dist),
        headingDeg: 0,
        betaDeg: 90,
      ) as ArPerson).widthPx;
      expect(w(5), 200);
      expect(w(0.5), 200);
      expect(w(26), closeTo(100, 0.5));
      expect(w(1000), 26);
    });

    test('視野の外（右）: 「→ 右に振り向いて（あと◯m・名前）」', () {
      final o = computeArOverlay(size: size, me: me, target: targetAt(90, 120), headingDeg: 0, betaDeg: 90);
      expect(o, isA<ArEdgeArrow>());
      expect((o as ArEdgeArrow).toRight, isTrue);
      expect(o.text, '→ 右に振り向いて（あと120m・たかし）');
    });

    test('視野の外（左）と km 表記', () {
      final o = computeArOverlay(size: size, me: me, target: targetAt(200, 1234), headingDeg: 10, betaDeg: 90);
      expect((o as ArEdgeArrow).toRight, isFalse);
      expect(o.text, '← 左に振り向いて（あと1.2km・たかし）');
    });

    test('名前が空なら「相手」', () {
      final o = computeArOverlay(
        size: size,
        me: me,
        target: targetAt(90, 120, name: ''),
        headingDeg: 0,
      );
      expect((o as ArEdgeArrow).text, contains('・相手）'));
    });

    test('向きが無い: 人影も矢印も出さず、距離だけの中立表示', () {
      final o = computeArOverlay(size: size, me: me, target: targetAt(90, 120), headingDeg: null, betaDeg: 90);
      expect(o, isA<ArNeutral>());
      expect((o as ArNeutral).message, 'コンパスが使えないので方向は出せません。距離: 120m');
    });

    test('向きを確かめている間は文言だけ違う', () {
      final o = computeArOverlay(size: size, me: me, target: targetAt(90, 120), headingDeg: null, headingPending: true);
      expect((o as ArNeutral).message, '向きを確かめています…　距離: 120m');
    });

    test('向きが NaN でも中立表示', () {
      final o = computeArOverlay(size: size, me: me, target: targetAt(90, 120), headingDeg: double.nan);
      expect(o, isA<ArNeutral>());
    });

    test('階の差バッジは人影に付く', () {
      final p = computeArOverlay(
        size: size,
        me: me,
        target: targetAt(0, 30, floor: '3F'),
        headingDeg: 0,
        betaDeg: 90,
        myFloor: '1F',
      ) as ArPerson;
      expect(p.floorBadge, '↑2階上');
    });
  });

  group('arFloorBadge', () {
    test('上なら ↑差階上、下なら ↓相手の階、同じ・未設定なら出さない', () {
      expect(arFloorBadge('1F', '3F'), '↑2階上');
      expect(arFloorBadge('3F', '1F'), '↓1F');
      expect(arFloorBadge('1F', 'B2'), '↓B2');
      expect(arFloorBadge('B1', '1F'), '↑1階上'); // 0 階は無い（kFloors の並びで数える）
      expect(arFloorBadge('2F', '2F'), isNull);
      expect(arFloorBadge(null, '3F'), isNull);
      expect(arFloorBadge('1F', null), isNull);
      expect(arFloorBadge('1F', '0F'), isNull);
    });
  });

  group('pickNextWaypoint', () {
    // 北へ 0→50m→（東へ）50m の L 字
    final a = me;
    final b = destinationPoint(me.lat, me.lng, 0, 50);
    final c = destinationPoint(b.lat, b.lng, 90, 50);
    final route = [a, b, c];

    test('出発点にいれば曲がり角', () {
      final r = pickNextWaypoint(route, me)!;
      expect(r.point, b);
      expect(r.isLast, isFalse);
    });

    test('曲がり角の手前 5m（8m 未満）なら、その次の点', () {
      final near = destinationPoint(me.lat, me.lng, 0, 45);
      final r = pickNextWaypoint(route, near)!;
      expect(r.point, c);
      expect(r.isLast, isTrue);
    });

    test('曲がった後は終点', () {
      final after = destinationPoint(b.lat, b.lng, 90, 20);
      final r = pickNextWaypoint(route, after)!;
      expect(r.point, c);
      expect(r.isLast, isTrue);
    });

    test('終点のすぐ近くでも終点を返す', () {
      final r = pickNextWaypoint(route, destinationPoint(c.lat, c.lng, 270, 2))!;
      expect(r.point, c);
      expect(r.isLast, isTrue);
    });

    test('空・1点', () {
      expect(pickNextWaypoint(const [], me), isNull);
      final one = pickNextWaypoint([b], me)!;
      expect(one.point, b);
      expect(one.isLast, isTrue);
    });

    test('ArTarget の toString は座標を出さない', () {
      expect(targetAt(0, 10).toString(), isNot(contains('35.')));
    });
  });
}
