// route のテストで使う小さな合成グラフ（渋谷駅から「北へ◯m・東へ◯m」で点を置く）。worker/test/route.test.js と同じ作り方。
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:shibuya_machimachi/features/route/engine/route_engine.dart';

const centerLat = 35.658;
const centerLng = 139.7016;
final mPerDegLat = 6371000 * (math.pi / 180);
final mPerDegLng = mPerDegLat * math.cos((centerLat * math.pi) / 180);

/// 渋谷駅から北へ northM・東へ eastM の点。
RouteEndpoint at(double northM, double eastM, [num? level = 0]) =>
    RouteEndpoint(lat: centerLat + northM / mPerDegLat, lng: centerLng + eastM / mPerDegLng, level: level);

/// points: [[north, east], ...] / edges: [[a, b, type?, la?, lb?, flags?], ...]
RouteGraph makeGraph(List<List<double>> points, List<List<num>> edges) {
  final nodes = <double>[];
  for (final p in points) {
    final e = at(p[0], p[1]);
    nodes
      ..add(e.lat)
      ..add(e.lng);
  }
  final flat = <num>[];
  for (final e in edges) {
    final type = e.length > 2 ? e[2] : EdgeType.walk;
    final la = e.length > 3 ? e[3] : 0;
    final lb = e.length > 4 ? e[4] : la;
    final flags = e.length > 5 ? e[5] : 0;
    flat.addAll([e[0], e[1], type, la, lb, flags]);
  }
  return decodeGraph({
    'version': 'test',
    'center': [centerLat, centerLng],
    'edgeStride': 6,
    'nodes': nodes,
    'edges': flat,
  });
}

WalkRoute mustRoute(RouteGraph graph, RouteEndpoint from, RouteEndpoint to) {
  final r = findRoute(graph, from, to);
  expect(r.ok, isTrue, reason: '経路が見つかる(reason=${r.reason?.wire})');
  return r.route!;
}

Guidance guideAt(WalkRoute route, RouteEndpoint p, {num? level}) => guide(route, p.lat, p.lng, level: level);
