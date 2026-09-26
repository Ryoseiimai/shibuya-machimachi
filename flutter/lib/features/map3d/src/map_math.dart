// カメラ・余白・ラベル位置の純関数（shibuya3d.mjs の computeMaxBounds / metersPerPixelAt / clampPx /
// safeSidePadding / focusBoth / setRoute / updateMarkerOffsets を移したもの）。閾値は Web 版と同じ。
import 'dart:math' as math;

import 'package:flutter/painting.dart';

import '../../../core/core.dart';

const double kDefaultZoom = 15.6;
const double kMinZoom = 14;
const double kMaxZoom = 19;

/// 既定・寄せたときのピッチ（ピンが建物に埋もれにくいよう 50）。
const double kDefaultPitch = 50;

/// 最初だけゆっくり回り込む演出のピッチと速さ（度/秒）。
const double kIntroPitch = 60;
const double kIntroBearingDegPerSec = 3;
const double kInitialBearing = -17;

/// 駅から ±1700m（データの半径 1500m より少し外まで動かせる）。
const double kPanMarginM = 1700;

const double kFocusPaddingRatio = 0.12;
const double kFocusPaddingMinPx = 12;
const double kFocusPaddingMaxPx = 40;
const double kFocusLabelPaddingMaxPx = 90;
const double kLabelStackDistancePx = 56;
const double kLabelStackOffsetPx = 34;
const double kFocusMaxZoom = 17;
const double kRouteFitMaxZoom = 17.5;
const double kSinglePinZoom = 17;

/// Web Mercator の 0 ズーム・赤道での m/px（Web 版と同じ定数。ラベルの持ち上げにだけ使う）。
const double kEarthCircumferenceConst = 156543.03392;

/// ラベルの文字（buildLabelEl の card と同じ 12px 太字・左右 9px の余白）。
const TextStyle kPinLabelTextStyle = TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: Color(0xFFFFFFFF), height: 1.2);
const double kPinLabelHorizontalPaddingPx = 9 * 2;

class CameraState {
  const CameraState({required this.center, required this.zoom, required this.bearing, required this.pitch});
  final GeoPoint center;
  final double zoom;
  final double bearing;
  final double pitch;

  CameraState copyWith({GeoPoint? center, double? zoom, double? bearing, double? pitch}) =>
      CameraState(center: center ?? this.center, zoom: zoom ?? this.zoom, bearing: bearing ?? this.bearing, pitch: pitch ?? this.pitch);

  @override
  String toString() => 'CameraState(zoom: $zoom, bearing: $bearing, pitch: $pitch)'; // 座標は出さない
}

const GeoPoint kMapCenter = GeoPoint(kMapCenterLat, kMapCenterLng);

const CameraState kInitialCamera = CameraState(center: kMapCenter, zoom: kDefaultZoom, bearing: kInitialBearing, pitch: kDefaultPitch);

class GeoBounds {
  const GeoBounds({required this.south, required this.west, required this.north, required this.east});
  final double south;
  final double west;
  final double north;
  final double east;

  static GeoBounds? of(Iterable<GeoPoint> points) {
    GeoBounds? b;
    for (final p in points) {
      if (!p.isFinite) continue;
      b = b == null
          ? GeoBounds(south: p.lat, west: p.lng, north: p.lat, east: p.lng)
          : GeoBounds(
              south: math.min(b.south, p.lat),
              west: math.min(b.west, p.lng),
              north: math.max(b.north, p.lat),
              east: math.max(b.east, p.lng),
            );
    }
    return b;
  }
}

/// 動かせる範囲（駅から ±1700m の四角）。
GeoBounds computeMaxBounds() {
  const dLat = 1 / 111320;
  final dLng = 1 / (111320 * math.cos(kMapCenterLat * math.pi / 180));
  return GeoBounds(
    south: kMapCenterLat - kPanMarginM * dLat,
    west: kMapCenterLng - kPanMarginM * dLng,
    north: kMapCenterLat + kPanMarginM * dLat,
    east: kMapCenterLng + kPanMarginM * dLng,
  );
}

double metersPerPixelAt(double lat, double zoom) => kEarthCircumferenceConst * math.cos(lat * math.pi / 180) / math.pow(2, zoom);

double clampPx(double px, [double max = kFocusPaddingMaxPx]) => math.min(max, math.max(kFocusPaddingMinPx, px));

/// 片側の余白を「幅（高さ）の半分 − 12」以下に収める（超えると寄せ先が計算できなくなる）。
double safeSidePadding(double px, double containerSizePx) {
  final maxAllowed = math.max(kFocusPaddingMinPx, containerSizePx / 2 - kFocusPaddingMinPx);
  return math.min(math.max(px, kFocusPaddingMinPx), maxAllowed);
}

/// ラベルの横幅の半分（buildLabelEl の card の大きさの見積もり）。
double measureLabelHalfWidthPx(String text) {
  if (text.isEmpty) return 0;
  final tp = TextPainter(text: TextSpan(text: text, style: kPinLabelTextStyle), textDirection: TextDirection.ltr)..layout();
  final w = tp.width;
  tp.dispose();
  return (w + kPinLabelHorizontalPaddingPx) / 2;
}

class EdgePad {
  const EdgePad({required this.left, required this.top, required this.right, required this.bottom});
  final double left;
  final double top;
  final double right;
  final double bottom;
}

/// focusBoth（2人）の余白。縦は高さの 12%（12〜40）、横は max(幅の 12%, ラベル幅/2)（12〜90）。
EdgePad focusPadding(Size size, List<String> labelTexts) {
  final vPad = safeSidePadding(clampPx(size.height * kFocusPaddingRatio), size.height);
  final halves = labelTexts.where((t) => t.isNotEmpty).map(measureLabelHalfWidthPx).toList();
  final labelPad = halves.isEmpty ? 0.0 : clampPx(halves.reduce(math.max), kFocusLabelPaddingMaxPx);
  final hPad = safeSidePadding(math.max(clampPx(size.width * kFocusPaddingRatio), labelPad), size.width);
  return EdgePad(left: hPad, top: vPad, right: hPad, bottom: vPad);
}

/// setRoute(fit) の余白。上はラベルの分 +34px。
EdgePad routeFitPadding(Size size) {
  final vPad = safeSidePadding(clampPx(size.height * kFocusPaddingRatio, kFocusLabelPaddingMaxPx), size.height);
  final hPad = safeSidePadding(clampPx(size.width * kFocusPaddingRatio, kFocusLabelPaddingMaxPx), size.width);
  return EdgePad(left: hPad, top: vPad + kLabelStackOffsetPx, right: hPad, bottom: vPad);
}

// ---- Web Mercator（512px タイル = MapLibre のズームと同じ尺度） ----
const double _worldSize0 = 512;

Offset _project(GeoPoint p) {
  final x = (p.lng + 180) / 360 * _worldSize0;
  final latRad = clampDouble(p.lat, -85.051129, 85.051129) * math.pi / 180;
  final y = (1 - math.log(math.tan(math.pi / 4 + latRad / 2)) / math.pi) / 2 * _worldSize0;
  return Offset(x, y);
}

GeoPoint _unproject(Offset o) {
  final lng = o.dx / _worldSize0 * 360 - 180;
  final n = math.pi - 2 * math.pi * o.dy / _worldSize0;
  final lat = 180 / math.pi * math.atan(0.5 * (math.exp(n) - math.exp(-n)));
  return GeoPoint(lat, lng);
}

Offset _rotate(Offset v, double rad) =>
    Offset(v.dx * math.cos(rad) - v.dy * math.sin(rad), v.dx * math.sin(rad) + v.dy * math.cos(rad));

/// MapLibre の既定の縦の画角（36.87°）の半分。
const double _halfFovRad = 0.6435011087932844 / 2;

/// 傾けると手前（画面の下端）が拡大されて端のピンがはみ出すので、その分だけズームを下げる量。
/// 下端の拡大率 = cos(pitch − 画角/2) / cos(pitch)（ピッチ 50 で約 1.32 倍 → 約 0.4 段）。
double pitchZoomCorrection(double pitchDeg) {
  if (pitchDeg <= 0) return 0;
  final p = pitchDeg * math.pi / 180;
  final ratio = math.cos(p - _halfFovRad) / math.cos(p);
  return ratio > 1 ? math.log(ratio) / math.ln2 : 0;
}

/// 範囲が余白の内側に収まるカメラ（fitBounds 相当）。向き（bearing）は今のまま、ピッチは指定値。
/// 意図的な簡略化: ズームは真上から見た大きさに、傾けたときの手前の拡大分（pitchZoomCorrection）を
/// 足しただけの近似（奥が縮む分は無視するので、奥側は少し余る）。シミュレータで、補正なしでは
/// ピッチ 50 の手前のピンが枠の外へ出たため入れた。厳密にするならネイティブの
/// cameraForLatLngBounds(bearing, tilt) を呼ぶのが入口。
CameraState cameraForBounds(
  GeoBounds bounds, {
  required Size size,
  required EdgePad padding,
  required double bearing,
  required double pitch,
  required double maxZoom,
}) {
  final rad = bearing * math.pi / 180;
  final corners = [
    GeoPoint(bounds.north, bounds.west),
    GeoPoint(bounds.north, bounds.east),
    GeoPoint(bounds.south, bounds.east),
    GeoPoint(bounds.south, bounds.west),
  ].map(_project).map((o) => _rotate(o, -rad)).toList();
  var minX = double.infinity, minY = double.infinity, maxX = -double.infinity, maxY = -double.infinity;
  for (final c in corners) {
    minX = math.min(minX, c.dx);
    maxX = math.max(maxX, c.dx);
    minY = math.min(minY, c.dy);
    maxY = math.max(maxY, c.dy);
  }
  final availW = math.max(1.0, size.width - padding.left - padding.right);
  final availH = math.max(1.0, size.height - padding.top - padding.bottom);
  final w = maxX - minX;
  final h = maxY - minY;
  double zoom;
  if (w <= 0 && h <= 0) {
    zoom = maxZoom;
  } else {
    final scale = math.min(w > 0 ? availW / w : double.infinity, h > 0 ? availH / h : double.infinity);
    zoom = math.log(scale) / math.ln2 - pitchZoomCorrection(pitch);
  }
  zoom = clampDouble(zoom, kMinZoom, maxZoom);
  final scaleAt = math.pow(2, zoom).toDouble();
  // 範囲の中心を「余白の内側の中心」に置くため、地図の中心を余白の偏りの分だけずらす。
  final centerRot = Offset((minX + maxX) / 2, (minY + maxY) / 2);
  final offset = Offset((padding.left - padding.right) / 2, (padding.top - padding.bottom) / 2) / scaleAt;
  final center = _unproject(_rotate(centerRot - offset, rad));
  return CameraState(center: center, zoom: zoom, bearing: bearing, pitch: pitch);
}

/// focusBoth（0人→駅、1人→そのピン z17、2人→両方が収まる z≤17）。すべてピッチ 50・向きは今のまま。
CameraState focusCamera(List<GeoPoint> pins, {required Size size, required List<String> labelTexts, required double bearing}) {
  final pts = pins.where((p) => p.isFinite).toList();
  if (pts.isEmpty) return CameraState(center: kMapCenter, zoom: kDefaultZoom, bearing: bearing, pitch: kDefaultPitch);
  if (pts.length == 1) return CameraState(center: pts.first, zoom: kSinglePinZoom, bearing: bearing, pitch: kDefaultPitch);
  return cameraForBounds(
    GeoBounds.of(pts)!,
    size: size,
    padding: focusPadding(size, labelTexts),
    bearing: bearing,
    pitch: kDefaultPitch,
    maxZoom: kFocusMaxZoom,
  );
}

/// setRoute(fit) のカメラ。2点未満なら null。
CameraState? routeFitCamera(List<GeoPoint>? coords, {required Size size, required double bearing}) {
  if (coords == null || coords.length < 2) return null;
  final b = GeoBounds.of(coords);
  if (b == null) return null;
  return cameraForBounds(b, size: size, padding: routeFitPadding(size), bearing: bearing, pitch: kDefaultPitch, maxZoom: kRouteFitMaxZoom);
}

/// 柱の高さの分だけラベルを画面の上へ持ち上げる量(px)。
double labelLiftPx(double heightM, double lat, CameraState cam) =>
    heightM / metersPerPixelAt(lat, cam.zoom) * math.sin(cam.pitch * math.pi / 180);

/// 2人のラベルが近すぎる（56px 未満）とき、画面の奥側（y が小さい方）を +34px 持ち上げる。
/// 戻り値は (自分の追加分, 相手の追加分)。
({double me, double partner}) labelStackLift(Offset? me, Offset? partner) {
  if (me == null || partner == null) return (me: 0, partner: 0);
  if ((me - partner).distance >= kLabelStackDistancePx) return (me: 0, partner: 0);
  return me.dy <= partner.dy ? (me: kLabelStackOffsetPx, partner: 0) : (me: 0, partner: kLabelStackOffsetPx);
}

/// 最初の回り込み: 経過秒から次の向き。
double introBearing(double bearing, double dtSec) => bearing + kIntroBearingDegPerSec * dtSec;
