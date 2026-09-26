import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shibuya_machimachi/core/core.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('文字と地のコントラストが 4.5:1 以上', () {
    const pairs = <(Color, Color, String)>[
      (Colors.white, AppColors.brandOrange, '主ボタン'),
      (AppColors.brandOrange, AppColors.card, 'オレンジの文字'),
      (AppColors.brandOrangeOnSoft, AppColors.brandOrangeSoftBg, 'バッジ'),
      (AppColors.mutedText, AppColors.card, 'hint(白地)'),
      (AppColors.mutedText, AppColors.background, 'hint(背景)'),
      (Colors.white, AppColors.lineGreen, 'LINE'),
      (Colors.white, AppColors.offlineRed, '通信切れ'),
      (AppColors.warnText, AppColors.warnBg, '警告'),
      (AppColors.secondaryText, AppColors.secondaryBg, '副ボタン'),
      (AppColors.ink, AppColors.background, '本文'),
      (AppColors.readonlyText, AppColors.readonlyFill, '読み取り専用'),
      (Colors.white, AppColors.demoBanner, 'デモバナー'),
    ];
    for (final (fg, bg, name) in pairs) {
      expect(contrastRatio(fg, bg), greaterThanOrEqualTo(4.5), reason: name);
    }
  });

  test('同梱の道データ・スポットの版の印が定数と一致', () async {
    final graph = jsonDecode(await rootBundle.loadString(kAssetGraph)) as Map;
    expect(graph['version'], kRouteGraphVersion);
    expect(graph['format'], 'shibuya-machimachi-route-graph/1');
    expect(graph['attribution'], contains('OpenStreetMap'));
    final placesJson = jsonDecode(await rootBundle.loadString(kAssetPlaces)) as Map;
    expect(placesJson['version'], kPlacesVersion);
    final places = parsePlaces(placesJson);
    expect(places.length, 13);
    expect(places.map((p) => p.id).toSet().length, places.length);
    for (final p in places) {
      expect(isInShibuyaArea(p.lat, p.lng), isTrue, reason: p.id);
    }
  });

  test('parsePlaces は不正を除外し、level が無ければ 0', () {
    final ps = parsePlaces({
      'places': [
        {'id': 'ok-1', 'name': 'A', 'lat': 35.6, 'lng': 139.7},
        {'id': 'NG', 'name': 'B', 'lat': 35.6, 'lng': 139.7},
        {'id': 'ng2', 'name': 'C', 'lat': '35.6', 'lng': 139.7},
      ]
    });
    expect(ps.map((p) => p.id), ['ok-1']);
    expect(ps.single.level, 0);
    expect(() => parsePlaces({}), throwsFormatException);
  });

  test('近くのお店: 同梱 POI から近い順に3件', () async {
    final pois = parsePois(jsonDecode(await rootBundle.loadString(kAssetPois)));
    expect(pois.length, greaterThan(2000));
    final shops = nearestShops(pois, 35.659060, 139.700628);
    expect(shops.length, 3);
    expect(shops[0].distanceM, lessThanOrEqualTo(shops[1].distanceM));
    expect(shops[1].distanceM, lessThanOrEqualTo(shops[2].distanceM));
  });
}
