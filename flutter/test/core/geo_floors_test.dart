import 'package:flutter_test/flutter_test.dart';
import 'package:shibuya_machimachi/core/core.dart';

void main() {
  group('geo', () {
    test('渋谷駅→ハチ公像の距離と方位', () {
      final d = distanceMeters(kShibuyaStationLat, kShibuyaStationLng, 35.659060, 139.700628);
      expect(d, inInclusiveRange(140, 160));
      final b = bearingDegrees(kShibuyaStationLat, kShibuyaStationLng, 35.659060, 139.700628);
      expect(b, inInclusiveRange(300, 340)); // 北西
    });

    test('destinationPoint で進んだ点は距離・方位が戻る', () {
      final p = destinationPoint(35.65905, 139.70058, 300, 260);
      expect(distanceMeters(35.65905, 139.70058, p.lat, p.lng), closeTo(260, 0.01));
      expect(bearingDegrees(35.65905, 139.70058, p.lat, p.lng), closeTo(300, 0.01));
    });

    test('normalizeAngleDiff は −180〜180（正=右）', () {
      expect(normalizeAngleDiff(350, 10), 20);
      expect(normalizeAngleDiff(10, 350), -20);
      expect(normalizeAngleDiff(0, 180), 180);
    });

    test('渋谷1.5km判定', () {
      expect(isInShibuyaArea(kShibuyaStationLat, kShibuyaStationLng), isTrue);
      final edgeIn = destinationPoint(kShibuyaStationLat, kShibuyaStationLng, 90, 1499);
      final edgeOut = destinationPoint(kShibuyaStationLat, kShibuyaStationLng, 90, 1501);
      expect(isInShibuyaArea(edgeIn.lat, edgeIn.lng), isTrue);
      expect(isInShibuyaArea(edgeOut.lat, edgeOut.lng), isFalse);
      expect(isInShibuyaArea(double.nan, 139.7), isFalse);
    });

    test('jsRound は JS の Math.round と同じ（負の .5）', () {
      expect(jsRound(-0.5), 0);
      expect(jsRound(-1.5), -1);
      expect(jsRound(2.5), 3);
    });

    test('GeoPoint は座標を文字列に出さない', () {
      expect(const GeoPoint(35.1, 139.2).toString(), isNot(contains('35.1')));
    });
  });

  group('floors', () {
    test('floorLabelToInt', () {
      expect(floorLabelToInt('B5'), -5);
      expect(floorLabelToInt('1F'), 1);
      expect(floorLabelToInt('0F'), isNull);
    });
    test('floorLabelToLevel / levelToFloorLabel / levelLabel', () {
      expect(floorLabelToLevel('1F'), 0);
      expect(floorLabelToLevel('10F'), 9);
      expect(floorLabelToLevel('B3'), -3);
      expect(floorLabelToLevel('0F'), isNull);
      expect(floorLabelToLevel('x'), isNull);
      expect(levelToFloorLabel(0), '1F');
      expect(levelToFloorLabel(-2), 'B2');
      expect(levelLabel(0), '1階');
      expect(levelLabel(1), '2階');
      expect(levelLabel(-1), '地下1階');
    });
    test('app の階整数との変換', () {
      expect(appFloorIntToLevel(1), 0);
      expect(appFloorIntToLevel(-1), -1);
      expect(levelToAppFloorInt(null), 1);
      expect(levelToAppFloorInt(0), 1);
      expect(levelToAppFloorInt(-2), -2);
    });
    test('floorDiffLabel はサーバーと同じ文言', () {
      expect(floorDiffLabel('1F', '3F'), '相手は2つ上の階にいます');
      expect(floorDiffLabel('1F', 'B1'), '相手は1つ下の階にいます');
      expect(floorDiffLabel('2F', '2F'), '相手は同じ階にいます');
      expect(floorDiffLabel(null, '2F'), '相手のフロアは未設定です');
    });
  });
}
