// 待ち合わせスポット（places.json）と近くのお店（POI GeoJSON）。どちらも同梱アセットから読む。
import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../constants.dart';
import '../geo.dart';

class Place {
  const Place({required this.id, required this.name, required this.lat, required this.lng, this.level = 0, this.hint = ''});
  final String id;
  final String name;
  final double lat;
  final double lng;

  /// OSM の level（0=地上）。
  final num level;
  final String hint;

  GeoPoint get point => GeoPoint(lat, lng);
}

/// places.json を読む（route.js の parsePlaces と同じ規則）。places が配列でなければ例外。
List<Place> parsePlaces(Object? json) {
  final places = json is Map ? json['places'] : null;
  if (places is! List) throw const FormatException('places.json: places が配列ではありません');
  final out = <Place>[];
  for (final p in places) {
    if (p is! Map) continue;
    final id = p['id'];
    final name = p['name'];
    final lat = p['lat'];
    final lng = p['lng'];
    if (id is! String || !kSpotIdPattern.hasMatch(id)) continue;
    if (name is! String) continue;
    if (lat is! num || !lat.isFinite || lng is! num || !lng.isFinite) continue;
    final level = p['level'];
    final hint = p['hint'];
    out.add(Place(
      id: id,
      name: name,
      lat: lat.toDouble(),
      lng: lng.toDouble(),
      level: level is num && level.isFinite ? level : 0,
      hint: hint is String ? hint : '',
    ));
  }
  return List.unmodifiable(out);
}

/// 定番スポット一覧（同梱の places.json）。room（待ち合わせ場所）と route（場所モード）が使う。
final placesProvider = FutureProvider<List<Place>>((ref) async {
  final text = await rootBundle.loadString(kAssetPlaces);
  return parsePlaces(jsonDecode(text));
});

/// ID から場所を引く（一覧に無い ID も来うるので null を返す）。
Place? findPlace(List<Place> places, String? id) {
  if (id == null) return null;
  for (final p in places) {
    if (p.id == id) return p;
  }
  return null;
}

class Poi {
  const Poi({required this.name, required this.lat, required this.lng, this.level});
  final String name;
  final double lat;
  final double lng;

  /// OSM の書き方のまま（例 "0", "-1;0"）。変換せずに表示する。
  final String? level;
}

class NearbyShop {
  const NearbyShop({required this.name, required this.distanceM, this.level});
  final String name;
  final int distanceM;
  final String? level;
}

List<Poi> parsePois(Object? json) {
  final features = json is Map ? json['features'] : null;
  if (features is! List) throw const FormatException('POI GeoJSON: features が配列ではありません');
  final out = <Poi>[];
  for (final f in features) {
    if (f is! Map) continue;
    final geom = f['geometry'];
    final props = f['properties'];
    if (geom is! Map || geom['type'] != 'Point') continue;
    final c = geom['coordinates'];
    if (c is! List || c.length < 2 || c[0] is! num || c[1] is! num) continue;
    final name = props is Map ? props['name'] : null;
    if (name is! String) continue;
    final level = props is Map ? props['level'] : null;
    out.add(Poi(name: name, lng: (c[0] as num).toDouble(), lat: (c[1] as num).toDouble(), level: level?.toString()));
  }
  return List.unmodifiable(out);
}

/// 近い順に n 件（shibuya3d.mjs の nearestShops）。中心は相手の推定位置を渡す。
List<NearbyShop> nearestShops(List<Poi> pois, double lat, double lng, {int n = 3}) {
  final list = [
    for (final p in pois) NearbyShop(name: p.name, distanceM: jsRound(distanceMeters(lat, lng, p.lat, p.lng)), level: p.level),
  ]..sort((a, b) => a.distanceM.compareTo(b.distanceM));
  return list.take(n).toList();
}

/// POI 一覧（2,789件、1回だけ読む）。
final poisProvider = FutureProvider<List<Poi>>((ref) async {
  final text = await rootBundle.loadString(kAssetPois);
  return parsePois(jsonDecode(text));
});
