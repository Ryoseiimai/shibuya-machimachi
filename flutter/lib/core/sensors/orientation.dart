// 向き（コンパス）と傾き。どちらも端末の中だけで使い、送らない。
import 'dart:math' as math;

import 'package:flutter_compass/flutter_compass.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sensors_plus/sensors_plus.dart';

import '../geo.dart';

/// 端末の向き（真北0・時計回り・[0,360)）。センサーが無い/取れないときは null。
/// iOS は CoreLocation の方位（Capacitor 版の CompassPlugin と同じ仕組み）。
/// 意図的な簡略化: flutter_compass は更新が止まっている。壊れたら自前 MethodChannel に替える（SPEC.md §6.4）。
final headingProvider = StreamProvider.autoDispose<double?>((ref) {
  final events = FlutterCompass.events;
  if (events == null) return Stream<double?>.value(null);
  return events.map((e) {
    final h = e.heading;
    if (h == null || !h.isFinite) return null;
    return (h % 360 + 360) % 360;
  });
});

/// Web の DeviceOrientation の beta に相当する前後の傾き（度）。
/// 平らに置いて画面が上 = 0、縦に立てて正面を向く = 90。
double betaFromAccelerometer(double y, double z) => toDeg(math.atan2(y, z));

/// 傾き（beta）。加速度センサーから求める。
final tiltProvider = StreamProvider.autoDispose<double>((ref) {
  return accelerometerEventStream(samplingPeriod: SensorInterval.uiInterval).map((e) => betaFromAccelerometer(e.y, e.z));
});
