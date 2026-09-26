// 軽量3D（MapLibre Native）の style JSON とピン・線の GeoJSON を組み立てる純関数。
// 正本は worker/public/assets/js/shibuya3d.mjs（buildStyle / floorInfo / squarePolygon / refreshPinsSource）。
// 値（色・高さ・太さ・透明度・光）は Web 版と同じにしている。変えるときは Web 版と両方を直す。
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/painting.dart' show Color;

import '../../../core/core.dart';

/// 地理院タイル（淡色）。
const String kGsiPaleTilesUrl = 'https://cyberjapandata.gsi.go.jp/xyz/pale/{z}/{x}/{y}.png';

/// このアプリ唯一のアクセント色（html.js の --brand-orange と同じ）。
const String kAccentHex = '#c8431f';

/// 建物の名前が一致したら、ポリゴンをアクセント色で塗るランドマーク（データに基づく強調）。
const List<String> kLandmarkAccentNames = ['渋谷ヒカリエ', '渋谷ストリーム'];

/// 1階あたりの高さ(m)・地下のピンの高さ(m)・柱の半辺(m)。
const double kFloorHeightM = 3.5;
const double kBasementPillarHeightM = 5;
const double kPillarHalfSizeM = 4;

/// 建物の不透明度（ピンが建物に埋もれないよう半透明）。
const double kBuildingOpacity = 0.6;
const double kRouteLineWidthPx = 5;

/// レイヤー・ソースの ID（Web 版と同じ名前）。
abstract final class MapIds {
  static const buildingsSource = 'buildings';
  static const pinsSource = 'pins';
  static const pinsGlowSource = 'pins-glow';
  static const pinsLineSource = 'pins-line';
  static const routeLineSource = 'route-line';
  static const pinsLineLayer = 'pins-line';
}

/// ランドマークのラベル（位置と高さは shibuya3d.mjs の LANDMARKS と同じ概算値）。
class Landmark {
  const Landmark(this.name, this.lat, this.lng, this.heightM);
  final String name;
  final double lat;
  final double lng;
  final double heightM;
  GeoPoint get point => GeoPoint(lat, lng);
}

const List<Landmark> kLandmarks = [
  Landmark('渋谷スクランブルスクエア', 35.6585, 139.7016, 230),
  Landmark('渋谷ヒカリエ', 35.659213, 139.703826, 173.6),
  Landmark('SHIBUYA109', 35.659, 139.6983, 45),
  Landmark('渋谷ストリーム', 35.657282, 139.703035, 171.3),
  Landmark('渋谷フクラス', 35.6595, 139.698, 130),
  Landmark('ハチ公像', 35.659, 139.7004, 2),
];

/// ピンの見た目（shibuya3d.mjs の floorInfo）。floor は app の階整数（1F=1・B1=-1・0 は 1F 扱い）。
class PinLook {
  const PinLook({required this.heightM, required this.label, required this.basement});
  final double heightM;
  final String label;
  final bool basement;
}

PinLook pinLook(int floor) {
  if (floor <= -1) return PinLook(heightM: kBasementPillarHeightM, label: 'B${floor.abs()}', basement: true);
  final n = floor == 0 ? 1 : floor;
  return PinLook(heightM: n * kFloorHeightM, label: '${n}F', basement: false);
}

enum PinRole { me, partner }

Color pinColor(PinRole role, bool basement) => switch (role) {
      PinRole.me => basement ? AppColors.pinMeUnderground : AppColors.pinMe,
      PinRole.partner => basement ? AppColors.pinPartnerUnderground : AppColors.pinPartner,
    };

/// ラベルの文字「{名前} ・ {階}」。名前が無ければ 自分/相手。
String pinLabelText(PinRole role, String? name, int floor) {
  final display = role == PinRole.me ? '自分' : ((name == null || name.isEmpty) ? '相手' : name);
  return '$display ・ ${pinLook(floor).label}';
}

String colorHex(Color c) {
  String two(double v) => (v * 255).round().clamp(0, 255).toRadixString(16).padLeft(2, '0');
  return '#${two(c.r)}${two(c.g)}${two(c.b)}';
}

/// 8m 角の柱の足元（閉じた輪）。[lng, lat] の並び。
List<List<double>> squarePolygon(double lat, double lng, double halfSizeM) {
  const dLat = 1 / 111320;
  final dLng = 1 / (111320 * math.cos(lat * math.pi / 180));
  const corners = [
    [-1, -1],
    [1, -1],
    [1, 1],
    [-1, 1],
    [-1, -1],
  ];
  return [
    for (final c in corners) [lng + c[0] * halfSizeM * dLng, lat + c[1] * halfSizeM * dLat],
  ];
}

Map<String, dynamic> featureCollection(List<Map<String, dynamic>> features) => {'type': 'FeatureCollection', 'features': features};

/// 地図に描くピン1本分（座標は端末の中だけで使う）。
class PlacedPin {
  const PlacedPin({required this.role, required this.point, required this.floor, this.name});
  final PinRole role;
  final GeoPoint point;
  final int floor;
  final String? name;

  PinLook get look => pinLook(floor);
  Color get color => pinColor(role, look.basement);
  String get labelText => pinLabelText(role, name, floor);

  @override
  bool operator ==(Object other) =>
      other is PlacedPin && other.role == role && other.point == point && other.floor == floor && other.name == name;

  @override
  int get hashCode => Object.hash(role, point, floor, name);
}

/// pins（柱）・pins-glow（足元の光）・pins-line（2人を結ぶ点線）の3つのソースの中身。
({Map<String, dynamic> pins, Map<String, dynamic> glow, Map<String, dynamic> line}) pinSources(PlacedPin? me, PlacedPin? partner) {
  final pins = <Map<String, dynamic>>[];
  final glow = <Map<String, dynamic>>[];
  for (final p in [me, partner]) {
    if (p == null) continue;
    final role = p.role.name;
    final color = colorHex(p.color);
    pins.add({
      'type': 'Feature',
      'properties': {'role': role, 'heightM': p.look.heightM, 'color': color},
      'geometry': {
        'type': 'Polygon',
        'coordinates': [squarePolygon(p.point.lat, p.point.lng, kPillarHalfSizeM)],
      },
    });
    glow.add({
      'type': 'Feature',
      'properties': {'role': role, 'color': color},
      'geometry': {
        'type': 'Point',
        'coordinates': [p.point.lng, p.point.lat],
      },
    });
  }
  final line = <Map<String, dynamic>>[
    if (me != null && partner != null)
      {
        'type': 'Feature',
        'properties': <String, dynamic>{},
        'geometry': {
          'type': 'LineString',
          'coordinates': [
            [me.point.lng, me.point.lat],
            [partner.point.lng, partner.point.lat],
          ],
        },
      },
  ];
  return (pins: featureCollection(pins), glow: featureCollection(glow), line: featureCollection(line));
}

/// 道順の線（2点未満なら空）。
Map<String, dynamic> routeSource(List<GeoPoint>? coords) {
  if (coords == null || coords.length < 2) return featureCollection(const []);
  return featureCollection([
    {
      'type': 'Feature',
      'properties': <String, dynamic>{},
      'geometry': {
        'type': 'LineString',
        'coordinates': [
          for (final p in coords) [p.lng, p.lat],
        ],
      },
    },
  ]);
}

const String _buildingsPlaceholder = '__MACHIMACHI_BUILDINGS_GEOJSON__';

/// style JSON を丸ごと作る。建物の GeoJSON（約4MB）は読み込んだ文字列をそのまま埋め込む
/// （Dart で decode→encode し直さないため）。
/// Native は `sky` に対応していないので外した（空は Flutter 側で上端に薄いグラデーションを重ねる）。
String buildStyleJson(String buildingsGeoJson) {
  final empty = featureCollection(const []);
  final style = <String, dynamic>{
    'version': 8,
    'light': {
      'anchor': 'viewport',
      'color': '#ffffff',
      'intensity': 0.38,
      'position': [1.4, 210, 42],
    },
    'sources': {
      'gsi-pale': {
        'type': 'raster',
        'tiles': [kGsiPaleTilesUrl],
        'tileSize': 256,
        'maxzoom': 18,
        'attribution': '地理院タイル',
      },
      MapIds.buildingsSource: {'type': 'geojson', 'data': _buildingsPlaceholder},
      MapIds.pinsSource: {'type': 'geojson', 'data': empty},
      MapIds.pinsGlowSource: {'type': 'geojson', 'data': empty},
      MapIds.pinsLineSource: {'type': 'geojson', 'data': empty},
      MapIds.routeLineSource: {'type': 'geojson', 'data': empty},
    },
    'layers': [
      {
        'id': 'bg',
        'type': 'background',
        'paint': {'background-color': '#eef1f3'},
      },
      {'id': 'gsi-pale-layer', 'type': 'raster', 'source': 'gsi-pale'},
      {
        'id': 'buildings-3d',
        'type': 'fill-extrusion',
        'source': MapIds.buildingsSource,
        'paint': {
          'fill-extrusion-color': [
            'case',
            [
              'in',
              ['get', 'name'],
              ['literal', kLandmarkAccentNames],
            ],
            kAccentHex,
            [
              'interpolate',
              ['linear'],
              ['get', 'height'],
              0, '#f7f8fa', //
              20, '#eef0f3',
              60, '#dee2e6',
              120, '#c7cdd3',
              220, '#a6aeb7',
            ],
          ],
          'fill-extrusion-height': ['get', 'height'],
          'fill-extrusion-base': 0,
          'fill-extrusion-opacity': kBuildingOpacity,
          'fill-extrusion-vertical-gradient': true,
        },
      },
      {
        'id': 'pins-glow-outer',
        'type': 'circle',
        'source': MapIds.pinsGlowSource,
        'paint': {
          'circle-color': ['get', 'color'],
          'circle-radius': ['interpolate', ['linear'], ['zoom'], 14, 12, 19, 48],
          'circle-blur': 1,
          'circle-opacity': 0.32,
        },
      },
      {
        'id': 'pins-glow-inner',
        'type': 'circle',
        'source': MapIds.pinsGlowSource,
        'paint': {
          'circle-color': ['get', 'color'],
          'circle-radius': ['interpolate', ['linear'], ['zoom'], 14, 4, 19, 16],
          'circle-blur': 0.5,
          'circle-opacity': 0.55,
        },
      },
      {
        'id': MapIds.pinsLineLayer,
        'type': 'line',
        'source': MapIds.pinsLineSource,
        'layout': {'line-cap': 'round', 'line-join': 'round'},
        'paint': {
          'line-color': kAccentHex,
          'line-width': 2.4,
          'line-dasharray': [1.4, 1.6],
          'line-opacity': 0.85,
        },
      },
      {
        'id': 'route-line-casing',
        'type': 'line',
        'source': MapIds.routeLineSource,
        'layout': {'line-cap': 'round', 'line-join': 'round'},
        'paint': {'line-color': '#ffffff', 'line-width': kRouteLineWidthPx + 3, 'line-opacity': 0.9},
      },
      {
        'id': 'route-line',
        'type': 'line',
        'source': MapIds.routeLineSource,
        'layout': {'line-cap': 'round', 'line-join': 'round'},
        'paint': {'line-color': kAccentHex, 'line-width': kRouteLineWidthPx, 'line-opacity': 0.95},
      },
      {
        'id': 'pins-3d',
        'type': 'fill-extrusion',
        'source': MapIds.pinsSource,
        'paint': {
          'fill-extrusion-color': ['get', 'color'],
          'fill-extrusion-height': ['get', 'heightM'],
          'fill-extrusion-base': 0,
          'fill-extrusion-opacity': 0.96,
          'fill-extrusion-vertical-gradient': true,
        },
      },
    ],
  };
  return jsonEncode(style).replaceFirst('"$_buildingsPlaceholder"', buildingsGeoJson.trim());
}
