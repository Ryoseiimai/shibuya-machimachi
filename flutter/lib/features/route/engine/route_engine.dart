// 渋谷マチマチ 歩行ルート案内のエンジン（worker/public/assets/js/route.js の1対1移植）。
// Flutter に依存しない純 Dart だけを置く（dart test でそのまま単体テストするため。画面部品は route_screen.dart）。
// 道のデータは scripts/build_route_graph.mjs が OpenStreetMap から作った assets/route/graph.json
// （© OpenStreetMap contributors, ODbL）。
//
// 位置情報の扱い: この経路計算は端末の中だけで完結する（自分の位置も目的地もサーバーへ送らない）。
// toString で座標を出す型は作らない（ログに座標を出さないため）。
//
// 使い方:
//   final graph = decodeGraph(json);                          // graph.json → 計算用の配列
//   final r = findRoute(graph, from, to);                     // from/to = RouteEndpoint(lat, lng, level)
//   final g = guide(r.route!, lat, lng, level: level);        // 次の経由点・案内文・残りの道のり・到着/逸脱
//
// 階(level)は OSM の数え方: 0=地上の階(1階), 1=2階, -1=地下1階。画面の "1F"/"B1" とは
// core/floors.dart の floorLabelToLevel / levelToFloorLabel で相互に変換する。
//
// JS とずれる所（SPEC §6.2）: 丸めは全部 jsRound（Dart の round は負の .5 で違う）/ `Number(x)||0` は
// `x.isFinite ? x : 0` / toFixed(1) は toStringAsFixed(1) / JS の Array.sort は安定ソートなので、
// こちらでは元の並び順を第3キーにして同じ結果にする。
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import '../../../core/floors.dart' show levelLabel;
import '../../../core/geo.dart' show GeoPoint, bearingDegrees, distanceMeters, jsRound;

abstract final class EdgeType {
  static const int walk = 0;
  static const int steps = 1;
  static const int escalator = 2;
  static const int elevator = 3;
  static const int crossing = 4;
}

const int kEdgeFlagOneway = 1;

/// 階段等の両端の階が推測（上り/下りを言わない）。
const int kEdgeFlagLevelGuessed = 2;

/// 経路からこれ以上離れたら再計算。
const double kOffRouteM = 25;

/// 同じ階でこれ以内なら到着。
const double kArrivalM = 15;

/// 所要時間の目安（分速80m）。
const double kWalkMPerMin = 80;

/// 階の移動がこれ以内に迫ったら「◯階に着いた」ボタンを出す。
const double kFloorPromptM = 20;

const double _earthRadiusM = 6371000;
const double _deg = math.pi / 180;
const double _levelMatchTolerance = 0.5;
const double _levelMismatchPenaltyM = 30; // 違う階の道に吸着しにくくする重み（地下と地上が真上に重なる駅のため）
const double _snapMaxM = 150; // これより遠い道には吸着しない（エリア外・データの無い場所）
const double _waypointMinAheadM = 6; // 矢印が指す「次の経由点」は、今の位置からこれ以上先の点
const double _turnSmoothM = 8; // 曲がり角の角度は前後この距離の点で測る（細かいジグザグを無視する）
const double _turnMinDeg = 35;
const double _turnSlightMaxDeg = 60;
const double _turnSharpMinDeg = 150;
const double _maneuverMergeM = 6; // これより近い曲がり角は1つにまとめる
const double _nearManeuverM = 8; // これより近ければ「◯m先」を付けずに言う
const double _backtrackPenaltyM = 3; // 前回より手前の区間に戻りにくくする重み

// 移動のしにくさ（A*のコスト）。直線距離の推定が過大にならないよう、係数は1以上・加算は0以上にする。
const double _stepsCostFactor = 1.5;
const double _stepsCostExtraM = 5;
const double _escalatorCostFactor = 1.2;
const double _escalatorCostExtraM = 5;
const double _elevatorCostBaseM = 40; // 待ち時間の目安
const double _elevatorCostPerLevelM = 5;
const double _crossingCostExtraM = 10; // 信号待ちの目安

// ---------- 地理計算（渋谷付近の平面近似。1.5km圏では誤差は無視できる） ----------
// distanceMeters・bearingDegrees は core/geo.dart（route.js と同じ式）を使う。

double _normalizeDeg(double d) {
  var x = d.remainder(360); // JS の % と同じ（被除数の符号を残す）
  if (x > 180) x -= 360;
  if (x <= -180) x += 360;
  return x;
}

/// 渋谷付近の平面近似（lat0,lng0 を原点に、東 x・北 y のメートル）。isolate 間で渡せるよう関数を持たない。
class Projection {
  Projection(this.lat0, this.lng0)
      : kx = math.cos(lat0 * _deg) * _deg * _earthRadiusM,
        ky = _deg * _earthRadiusM;
  final double lat0;
  final double lng0;
  final double kx;
  final double ky;

  (double, double) toXY(double lat, double lng) => ((lng - lng0) * kx, (lat - lat0) * ky);
  (double, double) toLatLng(double x, double y) => (lat0 + y / ky, lng0 + x / kx);
}

class _Closest {
  const _Closest(this.t, this.qx, this.qy, this.d);
  final double t;
  final double qx;
  final double qy;
  final double d;
}

_Closest _closestOnSegment(double px, double py, double ax, double ay, double bx, double by) {
  final dx = bx - ax;
  final dy = by - ay;
  final len2 = dx * dx + dy * dy;
  final t = len2 == 0 ? 0.0 : math.max(0.0, math.min(1.0, ((px - ax) * dx + (py - ay) * dy) / len2));
  final qx = ax + t * dx;
  final qy = ay + t * dy;
  return _Closest(t, qx, qy, _hypot(px - qx, py - qy));
}

double _hypot(double a, double b) => math.sqrt(a * a + b * b);

bool _levelMatches(num? level, num la, num lb) {
  if (level == null) return true;
  final lo = math.min(la, lb) - _levelMatchTolerance;
  final hi = math.max(la, lb) + _levelMatchTolerance;
  return level >= lo && level <= hi;
}

// ---------- グラフ ----------

double edgeCost(int type, double lengthM, double la, double lb) {
  switch (type) {
    case EdgeType.steps:
      return lengthM * _stepsCostFactor + _stepsCostExtraM;
    case EdgeType.escalator:
      return lengthM * _escalatorCostFactor + _escalatorCostExtraM;
    case EdgeType.elevator:
      return lengthM + _elevatorCostBaseM + _elevatorCostPerLevelM * (lb - la).abs();
    case EdgeType.crossing:
      return lengthM + _crossingCostExtraM;
    default:
      return lengthM;
  }
}

/// 計算用のグラフ（decodeGraph の結果）。型付き配列だけを持つので compute() で isolate から返せる。
class RouteGraph {
  RouteGraph._({
    required this.version,
    required this.nodeCount,
    required this.edgeCount,
    required this.proj,
    required this.lat,
    required this.lng,
    required this.x,
    required this.y,
    required this.ea,
    required this.eb,
    required this.etype,
    required this.ela,
    required this.elb,
    required this.eflags,
    required this.elen,
    required this.ecost,
    required this.adjStart,
    required this.adjArc,
  });

  final String? version;
  final int nodeCount;
  final int edgeCount;
  final Projection proj;
  final Float64List lat;
  final Float64List lng;
  final Float64List x;
  final Float64List y;
  final Int32List ea;
  final Int32List eb;
  final Uint8List etype;
  final Float64List ela;
  final Float64List elb;
  final Uint8List eflags;
  final Float64List elen;
  final Float64List ecost;
  final Int32List adjStart;

  /// 有向の「弧」: 弧番号 = エッジ番号*2 + 向き（0: a→b, 1: b→a）。一方通行は a→b のみ。
  final Int32List adjArc;

  @override
  String toString() => 'RouteGraph($nodeCount nodes, $edgeCount edges)';
}

double _num(Object? v) {
  if (v is num) return v.toDouble();
  throw const FormatException('route: グラフデータの形式が正しくありません');
}

/// graph.json（scripts/build_route_graph.mjs の出力）を計算用の型付き配列にする。
RouteGraph decodeGraph(Object? json) {
  if (json is! Map || json['nodes'] is! List || json['edges'] is! List) {
    throw const FormatException('route: グラフデータの形式が正しくありません');
  }
  final nodes = json['nodes'] as List;
  final edges = json['edges'] as List;
  final strideRaw = json['edgeStride'];
  final stride = strideRaw is num && strideRaw != 0 ? strideRaw.toInt() : 6;
  if (nodes.length % 2 != 0 || edges.length % stride != 0) {
    throw const FormatException('route: グラフデータの長さが正しくありません');
  }
  final nodeCount = nodes.length ~/ 2;
  final edgeCount = edges.length ~/ stride;
  final centerRaw = json['center'];
  final double c0;
  final double c1;
  if (centerRaw is List) {
    c0 = _num(centerRaw[0]);
    c1 = _num(centerRaw[1]);
  } else {
    c0 = _num(nodes[0]);
    c1 = _num(nodes[1]);
  }
  final proj = Projection(c0, c1);
  final lat = Float64List(nodeCount);
  final lng = Float64List(nodeCount);
  final x = Float64List(nodeCount);
  final y = Float64List(nodeCount);
  for (var i = 0; i < nodeCount; i += 1) {
    lat[i] = _num(nodes[i * 2]);
    lng[i] = _num(nodes[i * 2 + 1]);
    final (px, py) = proj.toXY(lat[i], lng[i]);
    x[i] = px;
    y[i] = py;
  }
  final ea = Int32List(edgeCount);
  final eb = Int32List(edgeCount);
  final etype = Uint8List(edgeCount);
  final ela = Float64List(edgeCount);
  final elb = Float64List(edgeCount);
  final eflags = Uint8List(edgeCount);
  final elen = Float64List(edgeCount);
  final ecost = Float64List(edgeCount);
  final degree = Int32List(nodeCount + 1);
  for (var e = 0; e < edgeCount; e += 1) {
    final o = e * stride;
    final a = _num(edges[o]);
    final b = _num(edges[o + 1]);
    if (!(a >= 0 && a < nodeCount && b >= 0 && b < nodeCount)) {
      throw const FormatException('route: エッジのノード番号が範囲外です');
    }
    final ai = a.toInt();
    final bi = b.toInt();
    ea[e] = ai;
    eb[e] = bi;
    etype[e] = _num(edges[o + 2]).toInt();
    ela[e] = _num(edges[o + 3]);
    elb[e] = _num(edges[o + 4]);
    eflags[e] = _num(edges[o + 5]).toInt();
    elen[e] = _hypot(x[bi] - x[ai], y[bi] - y[ai]);
    ecost[e] = edgeCost(etype[e], elen[e], ela[e], elb[e]);
    degree[ai] += 1;
    if (eflags[e] & kEdgeFlagOneway == 0) degree[bi] += 1;
  }
  final adjStart = Int32List(nodeCount + 1);
  for (var i = 0; i < nodeCount; i += 1) {
    adjStart[i + 1] = adjStart[i] + degree[i];
  }
  final fill = Int32List.fromList(adjStart.sublist(0, nodeCount));
  final adjArc = Int32List(adjStart[nodeCount]);
  for (var e = 0; e < edgeCount; e += 1) {
    adjArc[fill[ea[e]]++] = e * 2;
    if (eflags[e] & kEdgeFlagOneway == 0) adjArc[fill[eb[e]]++] = e * 2 + 1;
  }
  final version = json['version'];
  return RouteGraph._(
    version: version is String && version.isNotEmpty ? version : null,
    nodeCount: nodeCount,
    edgeCount: edgeCount,
    proj: proj,
    lat: lat,
    lng: lng,
    x: x,
    y: y,
    ea: ea,
    eb: eb,
    etype: etype,
    ela: ela,
    elb: elb,
    eflags: eflags,
    elen: elen,
    ecost: ecost,
    adjStart: adjStart,
    adjArc: adjArc,
  );
}

/// graph.json の文字列から decode まで（compute() に渡すためのトップレベル関数）。
RouteGraph decodeGraphText(String text) => decodeGraph(jsonDecode(text));

/// 吸着した点。
class GraphSnap {
  const GraphSnap({required this.edge, required this.t, required this.lat, required this.lng, required this.level, required this.distanceM});
  final int edge;
  final double t;
  final double lat;
  final double lng;
  final double level;
  final double distanceM;

  @override
  String toString() => 'GraphSnap(edge: $edge, <redacted>)';
}

/// いちばん近い「歩ける道」(エッジ)に吸着する。階が分かっていれば同じ階の道を優先する。
GraphSnap? snapToGraph(RouteGraph graph, double lat, double lng, {num? level, double? maxDistanceM}) {
  final maxD = maxDistanceM ?? _snapMaxM;
  if (!lat.isFinite || !lng.isFinite) return null;
  final (px, py) = graph.proj.toXY(lat, lng);
  int? bestEdge;
  _Closest? best;
  var bestScore = double.infinity;
  for (var e = 0; e < graph.edgeCount; e += 1) {
    if (graph.etype[e] == EdgeType.elevator) continue; // エレベーターのかごの中には吸着しない
    final a = graph.ea[e];
    final b = graph.eb[e];
    final c = _closestOnSegment(px, py, graph.x[a], graph.y[a], graph.x[b], graph.y[b]);
    if (c.d > maxD) continue;
    // 階段・エスカレーターは「吸着する点での階」で比べる（地下3階→地下1階のエスカレーターの下端に、
    // 地下1階にいる人を吸着させない）
    final hereLevel = graph.ela[e] + (graph.elb[e] - graph.ela[e]) * c.t;
    final score = c.d + (_levelMatches(level, hereLevel, hereLevel) ? 0 : _levelMismatchPenaltyM);
    if (score < bestScore) {
      bestScore = score;
      best = c;
      bestEdge = e;
    }
  }
  if (best == null || bestEdge == null) return null;
  final (sLat, sLng) = graph.proj.toLatLng(best.qx, best.qy);
  final e = bestEdge;
  return GraphSnap(
    edge: e,
    t: best.t,
    lat: sLat,
    lng: sLng,
    level: graph.ela[e] + (graph.elb[e] - graph.ela[e]) * best.t,
    distanceM: best.d,
  );
}

// 最小ヒープ（値の小さい順）。同じノードが何度入ってもよい（取り出し時に確定済みなら読み飛ばす）。
class _MinHeap {
  final List<double> _keys = [];
  final List<int> _vals = [];
  int get size => _keys.length;

  void push(int val, double key) {
    final k = _keys;
    final v = _vals;
    var i = k.length;
    k.add(key);
    v.add(val);
    while (i > 0) {
      final p = (i - 1) >> 1;
      if (k[p] <= key) break;
      k[i] = k[p];
      v[i] = v[p];
      i = p;
    }
    k[i] = key;
    v[i] = val;
  }

  int pop() {
    final k = _keys;
    final v = _vals;
    final top = v[0];
    final lastK = k.removeLast();
    final lastV = v.removeLast();
    if (k.isNotEmpty) {
      var i = 0;
      final n = k.length;
      for (;;) {
        final l = i * 2 + 1;
        if (l >= n) break;
        final r = l + 1;
        final c = r < n && k[r] < k[l] ? r : l;
        if (k[c] >= lastK) break;
        k[i] = k[c];
        v[i] = v[c];
        i = c;
      }
      k[i] = lastK;
      v[i] = lastV;
    }
    return top;
  }
}

int _arcTarget(RouteGraph graph, int arc) {
  final e = arc >> 1;
  return arc & 1 != 0 ? graph.ea[e] : graph.eb[e];
}

/// 出発点・目的地。level は OSM の階（不明なら null）。name は目的地の名前（出発点では使わない）。
class RouteEndpoint {
  const RouteEndpoint({required this.lat, required this.lng, this.level, this.name = ''});
  final double lat;
  final double lng;
  final num? level;
  final String name;

  @override
  String toString() => 'RouteEndpoint(<redacted>)';
}

enum RouteFailure {
  noStart('no_start'),
  noGoal('no_goal'),
  unreachable('unreachable');

  const RouteFailure(this.wire);

  /// route.js の reason の文字列。
  final String wire;
}

class RouteResult {
  const RouteResult.ok(WalkRoute this.route) : reason = null;
  const RouteResult.fail(RouteFailure this.reason) : route = null;
  final WalkRoute? route;
  final RouteFailure? reason;
  bool get ok => route != null;
}

/// from から to までの歩行ルート（A*）。
/// from.level は自分で選んだ階（不明なら null）。
RouteResult findRoute(RouteGraph graph, RouteEndpoint from, RouteEndpoint to, {double? maxSnapM}) {
  final start = snapToGraph(graph, from.lat, from.lng, level: from.level, maxDistanceM: maxSnapM);
  if (start == null) return const RouteResult.fail(RouteFailure.noStart);
  final goal = snapToGraph(graph, to.lat, to.lng, level: to.level, maxDistanceM: maxSnapM);
  if (goal == null) return const RouteResult.fail(RouteFailure.noGoal);

  final n = graph.nodeCount;
  final goalNode = n; // 目的地（道の途中の点）を仮のノード番号 N として扱う
  final gScore = Float64List(n + 1)..fillRange(0, n + 1, double.infinity);
  final via = Int32List(n + 1)..fillRange(0, n + 1, -1); // そのノードに来た弧（-2/-3=出発点から直接）
  final closed = Uint8List(n + 1);
  final heap = _MinHeap();
  final (gx, gy) = graph.proj.toXY(goal.lat, goal.lng);
  double h(int v) => v == goalNode ? 0 : _hypot(graph.x[v] - gx, graph.y[v] - gy);
  final se = start.edge;
  final fe = goal.edge;
  bool oneway(int e) => (graph.eflags[e] & kEdgeFlagOneway) != 0;
  var goalFrom = -1; // 目的地に入った元のノード（-2=出発点から同じ道の上を直接）

  void relaxGoal(int u, double cost) {
    if (cost < gScore[goalNode]) {
      gScore[goalNode] = cost;
      goalFrom = u;
      heap.push(goalNode, cost);
    }
  }

  void relax(int v, double cost, int arc) {
    if (cost < gScore[v]) {
      gScore[v] = cost;
      via[v] = arc;
      heap.push(v, cost + h(v));
    }
  }

  if (se == fe) {
    if (goal.t >= start.t) {
      relaxGoal(-2, (goal.t - start.t) * graph.ecost[se]);
    } else if (!oneway(se)) {
      relaxGoal(-2, (start.t - goal.t) * graph.ecost[se]);
    }
  }
  relax(graph.eb[se], (1 - start.t) * graph.ecost[se], -2);
  if (!oneway(se)) relax(graph.ea[se], start.t * graph.ecost[se], -3);

  while (heap.size > 0) {
    final u = heap.pop();
    if (closed[u] != 0) continue;
    closed[u] = 1;
    if (u == goalNode) break;
    final gu = gScore[u];
    if (u == graph.ea[fe]) relaxGoal(u, gu + goal.t * graph.ecost[fe]);
    if (u == graph.eb[fe] && !oneway(fe)) relaxGoal(u, gu + (1 - goal.t) * graph.ecost[fe]);
    for (var i = graph.adjStart[u]; i < graph.adjStart[u + 1]; i += 1) {
      final arc = graph.adjArc[i];
      final v = _arcTarget(graph, arc);
      if (closed[v] != 0) continue;
      relax(v, gu + graph.ecost[arc >> 1], arc);
    }
  }
  if (!gScore[goalNode].isFinite) return const RouteResult.fail(RouteFailure.unreachable);

  // 経路の復元: 出発点 → ノード列 → 目的地
  final nodePath = <int>[];
  final arcPath = <int>[];
  if (goalFrom != -2) {
    var v = goalFrom;
    for (;;) {
      nodePath.add(v);
      final arc = via[v];
      if (arc < 0) {
        arcPath.add(arc);
        break;
      }
      arcPath.add(arc);
      v = arc & 1 != 0 ? graph.eb[arc >> 1] : graph.ea[arc >> 1];
    }
  }
  return RouteResult.ok(_assembleRoute(
    graph,
    start,
    goal,
    nodePath.reversed.toList(),
    arcPath.reversed.toList(),
    goalFrom,
    to,
    from,
  ));
}

/// 経路上の点。level は OSM の生の値、floor は案内用に推定した階（assignFloors）。
class RoutePoint {
  RoutePoint(this.lat, this.lng, this.level);
  final double lat;
  final double lng;
  final double level;
  double floor = 0;

  @override
  String toString() => 'RoutePoint(<redacted>)';
}

class RouteSegment {
  RouteSegment({required this.type, required this.fromLevel, required this.toLevel, required this.guessed, required this.lengthM});
  final int type;
  final double fromLevel;
  final double toLevel;
  final bool guessed;
  final double lengthM;
  double fromFloor = 0;
  double toFloor = 0;
}

class RouteDestination {
  const RouteDestination({required this.lat, required this.lng, required this.level, required this.placeLevel, required this.name});
  final double lat;
  final double lng;

  /// 案内に沿って階を直していった場合に、着いた時点で画面の階が指しているはずの階（到着判定用）。
  final double level;
  final num? placeLevel;
  final String name;

  @override
  String toString() => 'RouteDestination(<redacted>)';
}

enum ManeuverKind { floor, turn, crossing, arrive } // index が route.js の KIND_ORDER と同じ

/// 案内すべき地点。
class Maneuver {
  const Maneuver._({
    required this.kind,
    required this.index,
    required this.alongM,
    this.endAlongM,
    this.via,
    this.fromLevel,
    this.toLevel,
    this.direction,
    this.label,
    this.crossing = false,
  });

  final ManeuverKind kind;
  final int index;
  final double alongM;

  /// floor: 階の移動が終わる地点までの道のり。
  final double? endAlongM;

  /// floor: "escalator" / "steps" / "elevator" / "walk"。
  final String? via;
  final double? fromLevel;

  /// floor: 行き先の階（推定できないときは null）。
  final double? toLevel;

  /// floor: "up" / "down"（向きも怪しいときは null）。
  final String? direction;

  /// turn: 「右」「斜め左」「大きく右」など。
  final String? label;

  /// turn: 曲がった先が横断歩道か。
  final bool crossing;
}

class WalkRoute {
  WalkRoute._({
    required this.points,
    required this.segments,
    required this.cum,
    required this.totalM,
    required this.destination,
    required this.startSnapM,
    required this.goalSnapM,
  });

  final List<RoutePoint> points;
  final List<RouteSegment> segments;
  final List<double> cum;
  final double totalM;
  final RouteDestination destination;
  final double startSnapM;
  final double goalSnapM;
  late final List<Maneuver> maneuvers;
}

WalkRoute _assembleRoute(RouteGraph graph, GraphSnap start, GraphSnap goal, List<int> nodePath, List<int> arcPath, int goalFrom,
    RouteEndpoint destination, RouteEndpoint from) {
  final points = <RoutePoint>[RoutePoint(start.lat, start.lng, start.level)];
  final segments = <RouteSegment>[];
  void pushPoint(double lat, double lng, double level, int e, double fromLevel) {
    final prev = points.last;
    segments.add(RouteSegment(
      type: graph.etype[e],
      fromLevel: fromLevel,
      toLevel: level,
      guessed: (graph.eflags[e] & kEdgeFlagLevelGuessed) != 0,
      lengthM: distanceMeters(prev.lat, prev.lng, lat, lng),
    ));
    points.add(RoutePoint(lat, lng, level));
  }

  if (goalFrom == -2) {
    pushPoint(goal.lat, goal.lng, goal.level, start.edge, start.level);
  } else {
    final se = start.edge;
    final first = nodePath[0];
    final firstLevel = first == graph.ea[se] ? graph.ela[se] : graph.elb[se];
    pushPoint(graph.lat[first], graph.lng[first], firstLevel, se, start.level);
    for (var i = 1; i < nodePath.length; i += 1) {
      final arc = arcPath[i];
      final e = arc >> 1;
      final forward = (arc & 1) == 0;
      final fromLevel = forward ? graph.ela[e] : graph.elb[e];
      final toLevel = forward ? graph.elb[e] : graph.ela[e];
      final v = nodePath[i];
      pushPoint(graph.lat[v], graph.lng[v], toLevel, e, fromLevel);
    }
    final fe = goal.edge;
    final last = nodePath.last;
    final lastLevel = last == graph.ea[fe] ? graph.ela[fe] : graph.elb[fe];
    pushPoint(goal.lat, goal.lng, goal.level, fe, lastLevel);
  }
  _assignFloors(segments, points, _startFloorFor(start.level, from.level));
  final cum = <double>[0];
  for (final s in segments) {
    cum.add(cum.last + s.lengthM);
  }
  final route = WalkRoute._(
    points: points,
    segments: segments,
    cum: cum,
    totalM: cum.last,
    destination: RouteDestination(
      lat: destination.lat,
      lng: destination.lng,
      level: segments.last.toFloor,
      placeLevel: destination.level,
      name: destination.name,
    ),
    startSnapM: start.distanceM,
    goalSnapM: goal.distanceM,
  );
  route.maneuvers = buildManeuvers(route);
  return route;
}

// ---------- 「実際の階」の推定 ----------
// OSMの level は建物ごとの相対値で、渋谷では描いた人によって 0始まり/1始まり が混ざり、
// 谷地形のため「坂の上の道路=別の建物の4階」も普通にある(2026-09-26 実データで確認)。
// そのまま使うと「3階へ進む→1階へ進む」のような嘘の案内が出るため、次の方針で推定する:
//   - 地下(level<0)は数え方がそろっている(B1=-1)ので、そのまま信じる
//   - 地上どうし(level>=0)の階の変化は、階段・エスカレーター・エレベーターの「両端の差」だけを
//     数える(両端の階が推測のもの=kEdgeFlagLevelGuessedは数えない)。道と建物の境目で数字が
//     飛ぶだけのもの・坂の通路(描き方の違いで向きも怪しい)は無視する
//   - 地上の推定が0(1階)を下回ったら0に止める(地下に入るのは level<0 のデータがあるときだけ)
// 意図的な簡略化: 絶対値が怪しいときは floorChangeText の「上の階へ/下の階へ」で言う
// (本格対応はビル単位の階の対応表、または国交省の歩行空間ネットワークデータで補正する)。

double _startFloorFor(double rawLevel, num? userLevel) {
  if (rawLevel < 0) return rawLevel;
  return math.max(0, userLevel != null && userLevel.isFinite ? userLevel.toDouble() : 0);
}

double _nextFloor(double floor, double rawFrom, double rawTo, bool isChange) {
  if (rawTo < 0 || rawFrom < 0) return rawTo;
  if (!isChange) return floor;
  return math.max(0, floor + (rawTo - rawFrom));
}

void _assignFloors(List<RouteSegment> segments, List<RoutePoint> points, double startFloor) {
  var floor = startFloor;
  var rawPrev = segments.isNotEmpty ? segments[0].fromLevel : 0.0;
  points[0].floor = floor;
  for (var i = 0; i < segments.length; i += 1) {
    final seg = segments[i];
    if ((seg.fromLevel - rawPrev).abs() > 0.01) floor = _nextFloor(floor, rawPrev, seg.fromLevel, false);
    seg.fromFloor = floor;
    if ((seg.toLevel - seg.fromLevel).abs() > 0.01) {
      floor = _nextFloor(floor, seg.fromLevel, seg.toLevel, _isVerticalType(seg.type) && !seg.guessed);
    }
    seg.toFloor = floor;
    points[i + 1].floor = floor;
    rawPrev = seg.toLevel;
  }
}

// ---------- 案内（曲がり角・階の移動・横断歩道） ----------

const Map<String, String> _viaLabel = {'escalator': 'エスカレーター', 'steps': '階段', 'elevator': 'エレベーター'};

const Map<String, String> _viaNeutralText = {'escalator': 'エスカレーターに乗る', 'steps': '階段を通る', 'elevator': 'エレベーターに乗る'};

/// 「エスカレーターで2階へ」「階段で地下1階へ」「エレベーターで3階へ」（手段が分からない坂・通路は「2階へ進む」）。
/// 行き先の階が推定できないとき（toLevel=null）は向きだけ言う:「階段で下の階へ」「エスカレーターで上の階へ」。
/// 向きも怪しいとき（direction=null）は「階段を通る」「エスカレーターに乗る」だけ言う（嘘の上下を言わない）。
String floorChangeText(String? via, num? toLevel, [String? direction]) {
  final label = _viaLabel[via];
  if (toLevel == null) {
    if (direction != 'up' && direction != 'down') return _viaNeutralText[via] ?? '';
    final where = direction == 'up' ? '上の階へ' : '下の階へ';
    return label != null ? '$labelで$where' : where;
  }
  return label != null ? '$labelで${levelLabel(toLevel)}へ' : '${levelLabel(toLevel)}へ進む';
}

/// 距離の言い方: 100m未満は5m単位、それ以上は10m単位、1km以上はkm。
String formatDistance(num m) {
  final v = math.max(0, m.isNaN ? 0 : m);
  if (v >= 1000) return '${(v / 1000).toStringAsFixed(1)}km';
  if (v >= 100) return '${jsRound(v / 10) * 10}m';
  return '${math.max(5, jsRound(v / 5) * 5)}m';
}

/// 経路の始点から along(m) 進んだ点。
({double lat, double lng}) _pointAtAlong(WalkRoute route, double along) {
  final points = route.points;
  final cum = route.cum;
  final d = math.max(0.0, math.min(route.totalM, along));
  var i = 0;
  while (i < cum.length - 2 && cum[i + 1] < d) {
    i += 1;
  }
  final segLen = cum[i + 1] - cum[i];
  final t = segLen > 0 ? (d - cum[i]) / segLen : 0.0;
  final a = points[i];
  final b = i + 1 < points.length ? points[i + 1] : a;
  return (lat: a.lat + (b.lat - a.lat) * t, lng: a.lng + (b.lng - a.lng) * t);
}

bool _isVerticalType(int type) => type == EdgeType.steps || type == EdgeType.escalator || type == EdgeType.elevator;

String _chainVia(List<RouteSegment> segments, int from, int to) {
  String? via;
  for (var s = from; s <= to; s += 1) {
    final t = segments[s].type;
    if (t == EdgeType.elevator) return 'elevator';
    if (t == EdgeType.escalator) {
      via = 'escalator';
    } else if (t == EdgeType.steps && via != 'escalator') {
      via = 'steps';
    }
  }
  return via ?? 'walk';
}

String _turnLabel(double delta) {
  final side = delta > 0 ? '右' : '左';
  final a = delta.abs();
  if (a < _turnSlightMaxDeg) return '斜め$side';
  if (a >= _turnSharpMinDeg) return '大きく$side';
  return side;
}

const double _levelEps = 0.01;

// 階の移動に関わる区間か（階段等で実際に上下する/推定の階が変わる/区間の入口で推定の階が変わる）
bool _isFloorSegment(List<RouteSegment> segments, int i) {
  final seg = segments[i];
  final prevFloor = i > 0 ? segments[i - 1].toFloor : seg.fromFloor;
  final rawChange = _isVerticalType(seg.type) && (seg.toLevel - seg.fromLevel).abs() > _levelEps;
  return rawChange || (seg.toFloor - seg.fromFloor).abs() > _levelEps || (seg.fromFloor - prevFloor).abs() > _levelEps;
}

/// 経路上の「案内すべき地点」を順に並べる。
///   floor:    階の移動（連続する階段・エスカレーター・エレベーターは1つにまとめ、行き先の階を言う。
///             行き先の階が推定できないときは direction(up/down) だけ持つ）
///   turn:     曲がり角（前後8mの向きの差が35度以上）
///   crossing: 横断歩道
///   arrive:   到着
List<Maneuver> buildManeuvers(WalkRoute route) {
  final segments = route.segments;
  final points = route.points;
  final cum = route.cum;
  final out = <Maneuver>[];
  final inChain = Uint8List(points.length);
  var s = 0;
  while (s < segments.length) {
    if (!_isFloorSegment(segments, s)) {
      s += 1;
      continue;
    }
    var end = s;
    while (end + 1 < segments.length && (_isFloorSegment(segments, end + 1) || _isVerticalType(segments[end + 1].type))) {
      end += 1;
    }
    final before = s > 0 ? segments[s - 1].toFloor : segments[s].fromFloor;
    final after = segments[end].toFloor;
    final via = _chainVia(segments, s, end);
    var sureDelta = 0.0;
    var guessedMove = false;
    for (var k = s; k <= end; k += 1) {
      final x = segments[k];
      if (!_isVerticalType(x.type)) continue;
      if (x.guessed) {
        guessedMove = guessedMove || (x.toLevel - x.fromLevel).abs() > _levelEps;
      } else {
        sureDelta += x.toLevel - x.fromLevel;
      }
    }
    ({double? toLevel, String? direction})? maneuver;
    if (jsRound(after) != jsRound(before)) {
      maneuver = (toLevel: after, direction: after > before ? 'up' : 'down');
    } else if (via != 'walk' && sureDelta.abs() >= 0.5) {
      maneuver = (toLevel: null, direction: sureDelta > 0 ? 'up' : 'down');
    } else if (via != 'walk' && guessedMove) {
      maneuver = (toLevel: null, direction: null);
    }
    if (maneuver != null) {
      out.add(Maneuver._(
        kind: ManeuverKind.floor,
        index: s,
        alongM: cum[s],
        endAlongM: cum[end + 1],
        via: via,
        fromLevel: before,
        toLevel: maneuver.toLevel,
        direction: maneuver.direction,
      ));
      for (var p = s; p <= end + 1; p += 1) {
        inChain[p] = 1;
      }
    }
    s = end + 1;
  }

  var lastTurnAlong = double.negativeInfinity;
  for (var i = 1; i < points.length - 1; i += 1) {
    if (inChain[i] != 0) continue;
    final isCrossingStart = segments[i].type == EdgeType.crossing && segments[i - 1].type != EdgeType.crossing;
    double? turn;
    if (segments[i - 1].lengthM > 0.5 && segments[i].lengthM > 0.5) {
      final back = _pointAtAlong(route, cum[i] - _turnSmoothM);
      final ahead = _pointAtAlong(route, cum[i] + _turnSmoothM);
      final p = points[i];
      final delta = _normalizeDeg(
          bearingDegrees(p.lat, p.lng, ahead.lat, ahead.lng) - bearingDegrees(back.lat, back.lng, p.lat, p.lng));
      if (delta.abs() >= _turnMinDeg && cum[i] - lastTurnAlong >= _maneuverMergeM) turn = delta;
    }
    if (turn != null) {
      out.add(Maneuver._(kind: ManeuverKind.turn, index: i, alongM: cum[i], label: _turnLabel(turn), crossing: isCrossingStart));
      lastTurnAlong = cum[i];
    } else if (isCrossingStart) {
      out.add(Maneuver._(kind: ManeuverKind.crossing, index: i, alongM: cum[i]));
    }
  }
  out.add(Maneuver._(kind: ManeuverKind.arrive, index: points.length - 1, alongM: route.totalM));
  // JS の Array.sort は安定ソート。Dart の sort は安定とは限らないので、元の順番を最後のキーにする。
  final order = {for (var i = 0; i < out.length; i += 1) out[i]: i};
  out.sort((a, b) {
    final c = a.alongM.compareTo(b.alongM);
    if (c != 0) return c;
    final k = a.kind.index - b.kind.index;
    if (k != 0) return k;
    return order[a]! - order[b]!;
  });
  return List.unmodifiable(out);
}

/// 案内地点までの距離つきの案内文（「20m先を右」「エスカレーターで2階へ」「あと80mで到着」）。
String maneuverText(Maneuver m, double distanceM) {
  final near = distanceM < _nearManeuverM;
  final ahead = '${formatDistance(distanceM)}先';
  switch (m.kind) {
    case ManeuverKind.floor:
      final text = floorChangeText(m.via, m.toLevel, m.direction);
      return near ? text : '$ahead、$text';
    case ManeuverKind.turn:
      final cross = m.crossing ? '、横断歩道を渡る' : '';
      return near ? '${m.label}へ$cross' : '$aheadを${m.label}$cross';
    case ManeuverKind.crossing:
      return near ? '横断歩道を渡る' : '$aheadで横断歩道を渡る';
    case ManeuverKind.arrive:
      return distanceM < kArrivalM ? 'もうすぐ到着' : 'あと${formatDistance(distanceM)}で到着';
  }
}

String remainingText(double remainingM) {
  final minutes = math.max(1, jsRound(remainingM / kWalkMPerMin));
  return '残り${formatDistance(remainingM)}・約$minutes分';
}

class GuideInstruction {
  const GuideInstruction({required this.kind, required this.text, required this.distanceM});
  final ManeuverKind kind;
  final String text;
  final double distanceM;
}

class FloorPrompt {
  const FloorPrompt({required this.toLevel, required this.via, required this.endLat, required this.endLng});
  final double toLevel;
  final String? via;

  /// 階の移動が終わる地点（着いたボタンを押したら、GPSが動くまでここにいるものとして案内を続ける）。
  final double endLat;
  final double endLng;

  @override
  String toString() => 'FloorPrompt(toLevel: $toLevel, via: $via, <redacted>)';
}

/// guide() の結果。
class Guidance {
  const Guidance({
    required this.arrived,
    required this.offRoute,
    required this.distanceToRouteM,
    required this.alongM,
    required this.remainingM,
    required this.progressIndex,
    required this.routeLevel,
    required this.waypointLat,
    required this.waypointLng,
    required this.bearingDeg,
    required this.instruction,
    required this.floorPrompt,
  });
  final bool arrived;
  final bool offRoute;
  final double distanceToRouteM;
  final double alongM;
  final double remainingM;
  final int progressIndex;
  final double routeLevel;
  final double waypointLat;
  final double waypointLng;
  final double bearingDeg;
  final GuideInstruction instruction;
  final FloorPrompt? floorPrompt;

  @override
  String toString() => 'Guidance(arrived: $arrived, offRoute: $offRoute, text: ${instruction.text}, <redacted>)';
}

/// 今の位置（と自分で選んだ階）から、案内に必要なものを全部まとめて返す。
/// lat/lng は自分の今の位置（端末の中だけで使う）。level は自分で選んだ階（不明なら null）。
/// progressIndex は前回の返り値の progressIndex。
Guidance guide(WalkRoute route, double lat, double lng, {num? level, int progressIndex = 0}) {
  final points = route.points;
  final segments = route.segments;
  final cum = route.cum;
  final proj = Projection(lat, lng);
  var bestI = 0;
  var bestT = 0.0;
  var bestD = double.infinity;
  var bestScore = double.infinity;
  for (var i = 0; i < segments.length; i += 1) {
    final a = points[i];
    final b = points[i + 1];
    final (ax, ay) = proj.toXY(a.lat, a.lng);
    final (bx, by) = proj.toXY(b.lat, b.lng);
    final c = _closestOnSegment(0, 0, ax, ay, bx, by);
    final seg = segments[i];
    var score = c.d;
    if (!_levelMatches(level, seg.fromFloor, seg.toFloor)) score += _levelMismatchPenaltyM;
    if (i < progressIndex - 1) score += _backtrackPenaltyM;
    if (score < bestScore) {
      bestI = i;
      bestT = c.t;
      bestD = c.d;
      bestScore = score;
    }
  }
  final along = cum[bestI] + bestT * (cum[bestI + 1] - cum[bestI]);
  final remainingM = math.max(0.0, route.totalM - along);
  final dest = route.destination;
  final end = points.last;
  // 目的地の点そのもの、または経路の終点（目的地に一番近い歩ける道の上）のどちらかに15m以内
  final toDest = math.min(
    distanceMeters(lat, lng, dest.lat, dest.lng),
    distanceMeters(lat, lng, end.lat, end.lng),
  );
  final sameFloorAsDest = level == null || (level - dest.level).abs() < _levelMatchTolerance;
  final arrived = toDest <= kArrivalM && sameFloorAsDest;

  double? wpLat;
  double? wpLng;
  for (var j = bestI + 1; j < points.length; j += 1) {
    if (cum[j] - along >= _waypointMinAheadM) {
      wpLat = points[j].lat;
      wpLng = points[j].lng;
      break;
    }
  }
  wpLat ??= dest.lat;
  wpLng ??= dest.lng;

  Maneuver? next;
  for (final m in route.maneuvers) {
    final hit = m.kind == ManeuverKind.floor ? m.endAlongM! > along + 0.5 : m.alongM > along + 0.5 || m.kind == ManeuverKind.arrive;
    if (hit) {
      next = m;
      break;
    }
  }
  final distanceM = next != null ? math.max(0.0, next.alongM - along) : remainingM;
  final seg = segments[bestI];
  FloorPrompt? floorPrompt;
  if (next != null && next.kind == ManeuverKind.floor && next.toLevel != null && distanceM <= kFloorPromptM) {
    final p = _pointAtAlong(route, next.endAlongM!);
    floorPrompt = FloorPrompt(toLevel: next.toLevel!, via: next.via, endLat: p.lat, endLng: p.lng);
  }
  return Guidance(
    arrived: arrived,
    offRoute: bestD >= kOffRouteM,
    distanceToRouteM: bestD,
    alongM: along,
    remainingM: remainingM,
    progressIndex: bestI,
    routeLevel: seg.fromFloor + (seg.toFloor - seg.fromFloor) * bestT,
    waypointLat: wpLat,
    waypointLng: wpLng,
    bearingDeg: bearingDegrees(lat, lng, wpLat, wpLng),
    instruction: next != null
        ? GuideInstruction(kind: next.kind, text: arrived ? '到着しました' : maneuverText(next, distanceM), distanceM: distanceM)
        : const GuideInstruction(kind: ManeuverKind.arrive, text: '到着しました', distanceM: 0),
    // 階の移動が近い（行き先の階が分かっている）ときだけ「◯階に着いた」ボタンを出す。
    floorPrompt: floorPrompt,
  );
}

/// 3D渋谷に線を描くための点列（route.js は [lng, lat] の配列。Dart では GeoPoint で返す）。
List<GeoPoint> routeLineCoordinates(WalkRoute route) => [for (final p in route.points) GeoPoint(p.lat, p.lng)];
