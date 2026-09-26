// AR の配置計算（worker/public/assets/js/ar.js の render() の移植）。純関数なのでテストで値を固定する。
// 人影は「相手（または道順の次の曲がり角）がいる方向」を示す図形で、映っている人の検出・識別は一切しない。
import 'dart:math' as math;
import 'dart:ui' show Size;

import '../../core/core.dart';

// --- 描画の定数（ar.js と同じ値）---
/// 縦に構えて正面を向いたときの beta。
const double kArBetaNeutralDeg = 90;

/// beta のずれ 1° あたりの縦オフセット(px)。
const double kArVerticalPxPerDeg = 4;

/// 縦オフセットの上限(px)。
const double kArVerticalOffsetClamp = 160;

/// 画面の高さに対する足元の基準位置。
const double kArBaseYRatio = 0.56;

/// 画面の幅に対する左右の振れ幅（端に張り付かないよう余白を残す）。
const double kArHorizontalMarginRatio = 0.42;

/// 人影の幅 = この値 / 距離(m)（透視投影ではない概算）。高さは幅の2倍。
const double kArSizeScaleConst = 2600;
const double kArSizeMinPx = 26;
const double kArSizeMaxPx = 200;

// --- 文言（ar.js と同じ）---
const String kArOrientationUnavailableMessage = 'この端末・ブラウザは向き(コンパス)に対応していないため、方向は表示できません。距離だけ表示します。';
const String kArCameraDeniedMessage = 'カメラの利用が許可されませんでした。設定からカメラへのアクセスを許可してください。';
const String kArCameraUnavailableMessage = 'この端末・ブラウザではカメラが利用できません。';

/// Flutter 版で足した文言（位置が取れないとき）。
const String kArLocationUnavailableMessage = '現在地が取れないため、方向と距離を表示できません。設定から位置情報の利用を許可してください。';

/// 何を指しているか。
enum ArTargetKind {
  /// 待ち合わせ相手（partnerEstimateProvider の推定位置）。
  partner,

  /// 道順の途中の曲がり角。
  waypoint,

  /// 道順の最後（行き先そのもの）。
  destination,
}

/// AR が指す先。座標は端末の中だけで使い、どこにも送らない。
class ArTarget {
  const ArTarget({required this.point, required this.name, this.floorLabel, this.kind = ArTargetKind.partner});
  final GeoPoint point;

  /// 人影の下に出す名前（相手のニックネーム・「次の曲がり角」・行き先名）。
  final String name;

  /// 画面ラベルの階（"3F" "B1"）。分からなければ null（階の差バッジを出さない）。
  final String? floorLabel;
  final ArTargetKind kind;

  @override
  String toString() => 'ArTarget(<redacted>)';
}

/// 画面に何を出すか。
sealed class ArOverlay {
  const ArOverlay();
}

/// 向きが分からない（または確かめ中）ので、方向は出さずに距離だけを出す。
class ArNeutral extends ArOverlay {
  const ArNeutral({required this.distanceM, required this.message});
  final double distanceM;
  final String message;
}

/// 視野の中: 人影を (x, y) に足元基準で描く。
class ArPerson extends ArOverlay {
  const ArPerson({
    required this.x,
    required this.y,
    required this.widthPx,
    required this.name,
    required this.distanceText,
    required this.floorBadge,
    required this.relativeDeg,
  });

  /// 人影の足元の中心（画面座標）。
  final double x;
  final double y;

  /// シルエットの幅（高さはこの2倍）。
  final double widthPx;
  final String name;
  final String distanceText;

  /// 「↑2階上」「↓B1」。同じ階・不明なら null。
  final String? floorBadge;

  /// 正面からの角度（正=右）。
  final double relativeDeg;

  double get heightPx => widthPx * 2;
}

/// 視野の外: 画面の端に「振り向いて」の矢印。
class ArEdgeArrow extends ArOverlay {
  const ArEdgeArrow({required this.toRight, required this.text});
  final bool toRight;
  final String text;
}

/// 相手の階の差（ar.js の floorIndicatorText）。上なら「↑{差}階上」、下なら「↓{相手の階}」、同じ・不明なら null。
/// 意図的な変更: Web 版は階の整数の差（1F=1, B1=-1）で数えるので B1→1F が「2階上」になり、未設定を 1F とみなしていた。
/// ここでは kFloors の並び（サーバーの floorDiffLabel と同じ）で数え、どちらかが未設定ならバッジを出さない。
String? arFloorBadge(String? myFloor, String? targetFloor) {
  if (!isValidFloor(myFloor) || !isValidFloor(targetFloor)) return null;
  final diff = kFloors.indexOf(targetFloor!) - kFloors.indexOf(myFloor!);
  if (diff == 0) return null;
  if (diff > 0) return '↑$diff階上';
  return '↓$targetFloor';
}

/// ar.js の render() と同じ配置。[headingDeg] が null なら中立表示。
/// [headingPending] は「センサーの最初の値を待っている」間（中立表示の文言だけ変える）。
ArOverlay computeArOverlay({
  required Size size,
  required GeoPoint me,
  required ArTarget target,
  required double? headingDeg,
  double? betaDeg,
  String? myFloor,
  bool headingPending = false,
  double fovDeg = kDefaultFovDegrees,
}) {
  final width = size.width > 0 ? size.width : 390.0;
  final height = size.height > 0 ? size.height : 640.0;
  final dist = distanceMeters(me.lat, me.lng, target.point.lat, target.point.lng);

  // 向きが無い: 誤った方向を示すより何も示さない方が安全（2026-09-24 UXレビュー item3）。
  if (headingDeg == null || !headingDeg.isFinite) {
    return ArNeutral(
      distanceM: dist,
      message: headingPending ? '向きを確かめています…　距離: ${jsRound(dist)}m' : 'コンパスが使えないので方向は出せません。距離: ${jsRound(dist)}m',
    );
  }

  final brng = bearingDegrees(me.lat, me.lng, target.point.lat, target.point.lng);
  final rel = normalizeAngleDiff(headingDeg, brng); // 正=右、負=左
  final halfFov = fovDeg / 2;
  final label = target.name.isEmpty ? '相手' : target.name;

  if (rel.abs() <= halfFov) {
    final xRatio = clampDouble(rel / halfFov, -1, 1);
    final x = width / 2 + xRatio * width * kArHorizontalMarginRatio;
    final beta = (betaDeg != null && betaDeg.isFinite) ? betaDeg : kArBetaNeutralDeg;
    final vOffset = clampDouble(
      (beta - kArBetaNeutralDeg) * kArVerticalPxPerDeg,
      -kArVerticalOffsetClamp,
      kArVerticalOffsetClamp,
    );
    final y = height * kArBaseYRatio + vOffset;
    final w = clampDouble(kArSizeScaleConst / math.max(dist, 1), kArSizeMinPx, kArSizeMaxPx);
    return ArPerson(
      x: x,
      y: y,
      widthPx: w,
      name: label,
      distanceText: formatDistanceAr(dist),
      floorBadge: arFloorBadge(myFloor, target.floorLabel),
      relativeDeg: rel,
    );
  }

  final text = '${formatDistanceAr(dist)}・$label';
  return rel > 0
      ? ArEdgeArrow(toRight: true, text: '→ 右に振り向いて（$text）')
      : ArEdgeArrow(toRight: false, text: '← 左に振り向いて（$text）');
}

/// 道順の線から「次に向かう点」を選ぶ。
/// 自分に一番近い区間を探し、その先の頂点のうち [aheadM] 以上離れた最初の点を返す（無ければ終点）。
/// 意図的な簡略化: 平面近似（数km以内なので誤差は無視できる）・道順の階は見ない。
/// 本格対応の入口: route エンジンの手順（曲がる・階を変える）単位で次の案内点を出す。
({GeoPoint point, bool isLast})? pickNextWaypoint(List<GeoPoint> route, GeoPoint me, {double aheadM = 8}) {
  final pts = route.where((p) => p.isFinite).toList(growable: false);
  if (pts.isEmpty || !me.isFinite) return null;
  if (pts.length == 1) return (point: pts.first, isLast: true);

  final cosLat = math.cos(toRad(me.lat));
  (double, double) xy(GeoPoint p) =>
      (toRad(p.lng - me.lng) * cosLat * kEarthRadiusM, toRad(p.lat - me.lat) * kEarthRadiusM);

  var bestSeg = 0;
  var bestD2 = double.infinity;
  for (var i = 0; i < pts.length - 1; i++) {
    final (ax, ay) = xy(pts[i]);
    final (bx, by) = xy(pts[i + 1]);
    final dx = bx - ax;
    final dy = by - ay;
    final len2 = dx * dx + dy * dy;
    final t = len2 == 0 ? 0.0 : clampDouble(-(ax * dx + ay * dy) / len2, 0, 1);
    final px = ax + t * dx;
    final py = ay + t * dy;
    final d2 = px * px + py * py;
    if (d2 < bestD2) {
      bestD2 = d2;
      bestSeg = i;
    }
  }

  for (var j = bestSeg + 1; j < pts.length; j++) {
    if (distanceMeters(me.lat, me.lng, pts[j].lat, pts[j].lng) >= aheadM) {
      return (point: pts[j], isLast: j == pts.length - 1);
    }
  }
  return (point: pts.last, isLast: true);
}
