// 距離・方位などの純関数。worker/public/assets/js/geo.js と worker/src/geo.js の移植。
import 'dart:math' as math;

import 'constants.dart';

const double kEarthRadiusM = 6371000;
const double _deg2rad = math.pi / 180;
const double _rad2deg = 180 / math.pi;

/// AR の視野角（度）。
const double kDefaultFovDegrees = 60;

/// 緯度経度の点。maplibre_gl の LatLng と名前がぶつからないよう GeoPoint にしている。
class GeoPoint {
  const GeoPoint(this.lat, this.lng);
  final double lat;
  final double lng;

  bool get isFinite => lat.isFinite && lng.isFinite;

  @override
  bool operator ==(Object other) => other is GeoPoint && other.lat == lat && other.lng == lng;

  @override
  int get hashCode => Object.hash(lat, lng);

  /// 座標をログに出さないため、toString は中身を出さない。
  @override
  String toString() => 'GeoPoint(<redacted>)';
}

double toRad(double deg) => deg * _deg2rad;
double toDeg(double rad) => rad * _rad2deg;

double clampDouble(double v, double min, double max) => math.min(math.max(v, min), max);

/// JS の Math.round と同じ丸め（.5 は +∞ 側）。Dart の round() は 0 から遠い側なので負の .5 でずれる。
int jsRound(num x) => (x + 0.5).floor();

/// ハバーサイン距離(m)。R=6371000。
double distanceMeters(double lat1, double lng1, double lat2, double lng2) {
  final phi1 = toRad(lat1);
  final phi2 = toRad(lat2);
  final dPhi = toRad(lat2 - lat1);
  final dLambda = toRad(lng2 - lng1);
  final a = math.pow(math.sin(dPhi / 2), 2) +
      math.cos(phi1) * math.cos(phi2) * math.pow(math.sin(dLambda / 2), 2);
  final c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
  return kEarthRadiusM * c;
}

/// 真方位（0=北・時計回り・[0,360)）。
double bearingDegrees(double lat1, double lng1, double lat2, double lng2) {
  final phi1 = toRad(lat1);
  final phi2 = toRad(lat2);
  final dLambda = toRad(lng2 - lng1);
  final y = math.sin(dLambda) * math.cos(phi2);
  final x = math.cos(phi1) * math.sin(phi2) - math.sin(phi1) * math.cos(phi2) * math.cos(dLambda);
  return (toDeg(math.atan2(y, x)) + 360) % 360;
}

/// b−a を −180〜180 に収める。正なら右、負なら左。
double normalizeAngleDiff(double a, double b) {
  // JS の % は被除数の符号を残すので remainder で合わせる。
  var diff = (b - a).remainder(360);
  if (diff > 180) diff -= 360;
  if (diff < -180) diff += 360;
  return diff;
}

/// 起点から方位・距離だけ進んだ点（Movable Type の式）。
GeoPoint destinationPoint(double lat, double lng, double bearingDeg, double distM) {
  final phi1 = toRad(lat);
  final lambda1 = toRad(lng);
  final theta = toRad(bearingDeg);
  final delta = distM / kEarthRadiusM;
  final phi2 = math.asin(math.sin(phi1) * math.cos(delta) + math.cos(phi1) * math.sin(delta) * math.cos(theta));
  final lambda2 = lambda1 +
      math.atan2(math.sin(theta) * math.sin(delta) * math.cos(phi1), math.cos(delta) - math.sin(phi1) * math.sin(phi2));
  return GeoPoint(toDeg(phi2), ((toDeg(lambda2) + 540) % 360) - 180);
}

/// 北へ northM・東へ eastM 進んだ点。
GeoPoint destinationFromOffset(double lat, double lng, double northM, double eastM) {
  final distM = math.sqrt(northM * northM + eastM * eastM);
  if (distM == 0) return GeoPoint(lat, lng);
  final bearing = (toDeg(math.atan2(eastM, northM)) + 360) % 360;
  return destinationPoint(lat, lng, bearing, distM);
}

/// 渋谷駅から半径 1500m 以内か（サーバーの isWithinRadius と同じ判定）。
bool isInShibuyaArea(double lat, double lng) {
  if (!lat.isFinite || !lng.isFinite) return false;
  return distanceMeters(kShibuyaStationLat, kShibuyaStationLng, lat, lng) <= kShibuyaRadiusM;
}

/// AR 用の距離表記（geo.js の formatDistance）。道順の formatDistance とは別物。
String formatDistanceAr(double distM) {
  if (distM < 1000) return 'あと${jsRound(distM)}m';
  return 'あと${(distM / 1000).toStringAsFixed(1)}km';
}
