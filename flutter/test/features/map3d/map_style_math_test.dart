// 軽量3D の style JSON・ピン・カメラの計算（shibuya3d.mjs と同じ値・同じ閾値か）。
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shibuya_machimachi/core/core.dart';
import 'package:shibuya_machimachi/features/map3d/src/map_math.dart';
import 'package:shibuya_machimachi/features/map3d/src/map_style.dart';

// テスト用: Web Mercator で画面位置を出す（cameraForBounds の検算。ピッチは無視）。
Offset screenOf(GeoPoint p, CameraState cam, Size size) {
  Offset proj(GeoPoint g) {
    final x = (g.lng + 180) / 360 * 512;
    final r = g.lat * math.pi / 180;
    final y = (1 - math.log(math.tan(math.pi / 4 + r / 2)) / math.pi) / 2 * 512;
    return Offset(x, y);
  }

  final s = math.pow(2, cam.zoom).toDouble();
  final d = (proj(p) - proj(cam.center)) * s;
  final rad = -cam.bearing * math.pi / 180;
  final rot = Offset(d.dx * math.cos(rad) - d.dy * math.sin(rad), d.dx * math.sin(rad) + d.dy * math.cos(rad));
  return Offset(size.width / 2, size.height / 2) + rot;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('style JSON', () {
    test('建物の GeoJSON を丸ごと埋め込み、sky を外し、Web 版と同じレイヤーを持つ', () {
      const buildings = '{"type":"FeatureCollection","features":[{"type":"Feature","properties":{"name":"渋谷ヒカリエ","height":173.6},"geometry":{"type":"Polygon","coordinates":[[[139.70,35.65],[139.71,35.65],[139.71,35.66],[139.70,35.65]]]}}]}';
      final style = jsonDecode(buildStyleJson(buildings)) as Map<String, dynamic>;
      expect(style.containsKey('sky'), isFalse);
      expect(style['light'], {
        'anchor': 'viewport',
        'color': '#ffffff',
        'intensity': 0.38,
        'position': [1.4, 210, 42],
      });
      final sources = style['sources'] as Map;
      expect((sources['buildings'] as Map)['data'], jsonDecode(buildings));
      expect((sources['gsi-pale'] as Map)['tiles'], ['https://cyberjapandata.gsi.go.jp/xyz/pale/{z}/{x}/{y}.png']);
      final layers = (style['layers'] as List).cast<Map>();
      expect(layers.map((l) => l['id']), [
        'bg',
        'gsi-pale-layer',
        'buildings-3d',
        'pins-glow-outer',
        'pins-glow-inner',
        'pins-line',
        'route-line-casing',
        'route-line',
        'pins-3d',
      ]);
      final b = layers[2]['paint'] as Map;
      expect(b['fill-extrusion-opacity'], 0.6);
      expect(b['fill-extrusion-vertical-gradient'], true);
      expect(jsonEncode(b['fill-extrusion-color']), contains('"#c8431f"'));
      expect(jsonEncode(b['fill-extrusion-color']), contains('220,"#a6aeb7"'));
      expect((layers[5]['paint'] as Map)['line-dasharray'], [1.4, 1.6]);
      expect((layers[6]['paint'] as Map)['line-width'], 8);
      expect((layers[7]['paint'] as Map)['line-width'], 5);
    });

    test('同梱の建物データ（本物）でも JSON として読める', () async {
      final text = await rootBundle.loadString(kAssetBuildings);
      final style = jsonDecode(buildStyleJson(text)) as Map;
      final data = ((style['sources'] as Map)['buildings'] as Map)['data'] as Map;
      expect((data['features'] as List).length, greaterThan(1000));
    });
  });

  group('ピン', () {
    test('階の高さ: 地上は 階×3.5m（0 は 1F）、地下は 5m で B 表記', () {
      expect(pinLook(1).heightM, 3.5);
      expect(pinLook(0).label, '1F');
      expect(pinLook(0).heightM, 3.5);
      expect(pinLook(10).heightM, 35);
      expect(pinLook(-3).label, 'B3');
      expect(pinLook(-3).heightM, 5);
      expect(pinLook(-3).basement, isTrue);
    });

    test('色は AppColors（Web 版と同じ値）・ラベルは「名前 ・ 階」', () {
      expect(colorHex(pinColor(PinRole.me, false)), '#1e88e5');
      expect(colorHex(pinColor(PinRole.me, true)), '#37474f');
      expect(colorHex(pinColor(PinRole.partner, false)), '#fb8c00');
      expect(colorHex(pinColor(PinRole.partner, true)), '#6a1b9a');
      expect(colorHex(AppColors.brandOrange), kAccentHex);
      expect(pinLabelText(PinRole.me, 'だれか', 3), '自分 ・ 3F');
      expect(pinLabelText(PinRole.partner, 'すず', -1), 'すず ・ B1');
      expect(pinLabelText(PinRole.partner, null, 2), '相手 ・ 2F');
      expect(pinLabelText(PinRole.partner, '', 2), '相手 ・ 2F');
    });

    test('柱は約 8m 角・点線は2人そろったときだけ', () {
      const me = PlacedPin(role: PinRole.me, point: GeoPoint(35.659, 139.7005), floor: 2);
      const partner = PlacedPin(role: PinRole.partner, point: GeoPoint(35.6595, 139.701), floor: -1, name: 'すず');
      final ring = squarePolygon(35.659, 139.7005, kPillarHalfSizeM);
      expect(ring.length, 5);
      expect(ring.first, ring.last);
      final side = distanceMeters(ring[0][1], ring[0][0], ring[1][1], ring[1][0]);
      expect(side, closeTo(8, 0.1));

      final one = pinSources(me, null);
      expect((one.pins['features'] as List).length, 1);
      expect((one.line['features'] as List), isEmpty);
      final both = pinSources(me, partner);
      final feats = (both.pins['features'] as List).cast<Map>();
      expect(feats.map((f) => (f['properties'] as Map)['heightM']), [7.0, 5.0]);
      expect(feats.map((f) => (f['properties'] as Map)['color']), ['#1e88e5', '#6a1b9a']);
      expect((both.line['features'] as List).length, 1);
      expect((both.glow['features'] as List).length, 2);
    });

    test('道順の線は2点以上だけ', () {
      expect((routeSource(null)['features'] as List), isEmpty);
      expect((routeSource(const [GeoPoint(35.6, 139.7)])['features'] as List), isEmpty);
      final r = routeSource(const [GeoPoint(35.6, 139.7), GeoPoint(35.61, 139.71)]);
      expect(((r['features'] as List).single as Map)['geometry'], {
        'type': 'LineString',
        'coordinates': [
          [139.7, 35.6],
          [139.71, 35.61],
        ],
      });
    });

    test('ランドマークは6件（Web 版の座標・高さ）', () {
      expect(kLandmarks.map((l) => l.name), ['渋谷スクランブルスクエア', '渋谷ヒカリエ', 'SHIBUYA109', '渋谷ストリーム', '渋谷フクラス', 'ハチ公像']);
      expect(kLandmarks.first.heightM, 230);
      for (final l in kLandmarks) {
        expect(isInShibuyaArea(l.lat, l.lng), isTrue, reason: l.name);
      }
    });
  });

  group('カメラ・余白', () {
    test('余白は 12〜40px、幅/高さの半分−12 を超えない（小さい枠でも NaN を出さない）', () {
      expect(clampPx(5), 12);
      expect(clampPx(100), 40);
      expect(safeSidePadding(40, 30), 12); // 半分−12=3 より下限 12 が勝つ
      expect(safeSidePadding(40, 200), 40);
      final p = focusPadding(const Size(343, 280), ['自分 ・ 1F', 'とても長いニックネームの人 ・ 10F']);
      expect(p.top, closeTo(280 * 0.12, 1e-9));
      expect(p.left, greaterThanOrEqualTo(343 * 0.12));
      expect(p.left, lessThanOrEqualTo(90));
      final tiny = focusPadding(const Size(20, 20), ['自分 ・ 1F']);
      expect(tiny.left.isFinite && tiny.top.isFinite, isTrue);
      final r = routeFitPadding(const Size(343, 280));
      expect(r.top - r.bottom, closeTo(kLabelStackOffsetPx, 1e-9));
    });

    test('focusBoth: 0人→駅 15.6、1人→z17、2人→余白の内側に2人とも入る', () {
      const size = Size(343, 280);
      final none = focusCamera(const [], size: size, labelTexts: const [], bearing: -17);
      expect(none.zoom, kDefaultZoom);
      expect(none.center, kMapCenter);
      expect(none.pitch, 50);
      final one = focusCamera(const [GeoPoint(35.66, 139.70)], size: size, labelTexts: const ['自分 ・ 1F'], bearing: 10);
      expect(one.zoom, 17);
      expect(one.bearing, 10);

      const a = GeoPoint(35.6570, 139.6990);
      const b = GeoPoint(35.6605, 139.7035);
      for (final bearing in [0.0, -17.0, 75.0]) {
        final cam = focusCamera(const [a, b], size: size, labelTexts: const ['自分 ・ 1F', '相手 ・ 1F'], bearing: bearing);
        expect(cam.zoom, lessThanOrEqualTo(17));
        expect(cam.pitch, 50);
        expect(cam.bearing, bearing);
        final pad = focusPadding(size, const ['自分 ・ 1F', '相手 ・ 1F']);
        for (final p in [a, b]) {
          final s = screenOf(p, cam, size);
          expect(s.dx, inInclusiveRange(pad.left - 1, size.width - pad.right + 1), reason: 'bearing $bearing');
          expect(s.dy, inInclusiveRange(pad.top - 1, size.height - pad.bottom + 1), reason: 'bearing $bearing');
        }
      }
    });

    test('2人がとても近いと z17 で止まる', () {
      final cam = focusCamera(const [GeoPoint(35.659, 139.7005), GeoPoint(35.65901, 139.70051)],
          size: const Size(343, 280), labelTexts: const [], bearing: 0);
      expect(cam.zoom, 17);
    });

    test('道順に寄せる: 上に +34px の余白・z≤17.5・2点未満は null', () {
      expect(routeFitCamera(null, size: const Size(343, 280), bearing: 0), isNull);
      const route = [GeoPoint(35.6590, 139.7005), GeoPoint(35.6600, 139.7010), GeoPoint(35.6610, 139.7000)];
      final cam = routeFitCamera(route, size: const Size(343, 280), bearing: -17)!;
      expect(cam.zoom, lessThanOrEqualTo(17.5));
      final pad = routeFitPadding(const Size(343, 280));
      for (final p in route) {
        final s = screenOf(p, cam, const Size(343, 280));
        expect(s.dy, greaterThanOrEqualTo(pad.top - 1));
        expect(s.dy, lessThanOrEqualTo(280 - pad.bottom + 1));
      }
    });

    test('動かせる範囲は駅から ±1700m', () {
      final b = computeMaxBounds();
      expect(distanceMeters(kMapCenterLat, kMapCenterLng, b.north, kMapCenterLng), closeTo(1700, 5));
      expect(distanceMeters(kMapCenterLat, kMapCenterLng, kMapCenterLat, b.east), closeTo(1700, 5));
    });

    test('ラベルの持ち上げ: 高さ/mpp × sin(pitch)、重なりそうなら奥側を +34px', () {
      const cam = CameraState(center: kMapCenter, zoom: 17, bearing: 0, pitch: 50);
      final mpp = 156543.03392 * math.cos(35.659 * math.pi / 180) / math.pow(2, 17);
      expect(labelLiftPx(35, 35.659, cam), closeTo(35 / mpp * math.sin(50 * math.pi / 180), 1e-9));
      expect(labelStackLift(const Offset(100, 100), const Offset(300, 100)), (me: 0.0, partner: 0.0));
      expect(labelStackLift(const Offset(100, 90), const Offset(110, 100)), (me: 34.0, partner: 0.0));
      expect(labelStackLift(const Offset(100, 120), const Offset(110, 100)), (me: 0.0, partner: 34.0));
      expect(labelStackLift(null, const Offset(1, 1)), (me: 0.0, partner: 0.0));
    });

    test('傾けたときの手前の拡大分だけズームを下げる（ピッチ50で約0.4段）', () {
      expect(pitchZoomCorrection(0), 0);
      expect(pitchZoomCorrection(50), closeTo(0.4, 0.05));
      final flat = cameraForBounds(const GeoBounds(south: 35.657, west: 139.699, north: 35.660, east: 139.703),
          size: const Size(343, 280), padding: const EdgePad(left: 20, top: 20, right: 20, bottom: 20), bearing: 0, pitch: 0, maxZoom: 19);
      final tilted = cameraForBounds(const GeoBounds(south: 35.657, west: 139.699, north: 35.660, east: 139.703),
          size: const Size(343, 280), padding: const EdgePad(left: 20, top: 20, right: 20, bottom: 20), bearing: 0, pitch: 50, maxZoom: 19);
      expect(flat.zoom - tilted.zoom, closeTo(pitchZoomCorrection(50), 1e-9));
    });

    test('回り込みは 3°/秒', () {
      expect(introBearing(-17, 2), -11);
    });
  });
}
