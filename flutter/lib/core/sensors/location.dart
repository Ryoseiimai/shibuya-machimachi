// 位置のプロバイダ。GPS は画面の中だけで使い、送るかどうかは RoomController だけが決める。
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';

import '../demo/demo_mode.dart';
import '../geo.dart';

/// 1回分の測位。座標をログに出さないため toString は中身を伏せる。
class PositionFix {
  const PositionFix({required this.lat, required this.lng, this.accuracy, required this.timestampMs});
  final double lat;
  final double lng;

  /// 精度(m)。サーバーの acc に入れる。
  final double? accuracy;
  final int timestampMs;

  GeoPoint get point => GeoPoint(lat, lng);
  bool get inShibuya => isInShibuyaArea(lat, lng);

  @override
  String toString() => 'PositionFix(<redacted>)';
}

enum LocationAccess { granted, denied, deniedForever, serviceDisabled }

abstract interface class LocationService {
  /// 許可を求める（ボタンのタップの中で呼ぶ）。
  Future<LocationAccess> ensurePermission();

  /// 今の許可の状態（ダイアログは出さない）。
  Future<LocationAccess> currentAccess();

  /// 位置の監視。許可が無いとエラーで終わる。
  Stream<PositionFix> watch();
}

class GeolocatorLocationService implements LocationService {
  const GeolocatorLocationService();

  LocationAccess _map(LocationPermission p) => switch (p) {
        LocationPermission.always || LocationPermission.whileInUse => LocationAccess.granted,
        LocationPermission.deniedForever => LocationAccess.deniedForever,
        _ => LocationAccess.denied,
      };

  @override
  Future<LocationAccess> currentAccess() async {
    if (!await Geolocator.isLocationServiceEnabled()) return LocationAccess.serviceDisabled;
    return _map(await Geolocator.checkPermission());
  }

  @override
  Future<LocationAccess> ensurePermission() async {
    if (!await Geolocator.isLocationServiceEnabled()) return LocationAccess.serviceDisabled;
    var p = await Geolocator.checkPermission();
    if (p == LocationPermission.denied) p = await Geolocator.requestPermission();
    return _map(p);
  }

  @override
  Stream<PositionFix> watch() => Geolocator.getPositionStream(
        // Web 版の watchPosition(enableHighAccuracy) に相当。
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.best, distanceFilter: 0),
      ).map((p) => PositionFix(
            lat: p.latitude,
            lng: p.longitude,
            accuracy: p.accuracy.isFinite && p.accuracy >= 0 ? p.accuracy : null,
            timestampMs: p.timestamp.millisecondsSinceEpoch,
          ));
}

/// デモ用: 渋谷駅ハチ公口の固定点（精度8m）を1秒ごとに返す。GPS は使わない。
class DemoLocationService implements LocationService {
  const DemoLocationService();
  static const lat = 35.65905;
  static const lng = 139.70058;

  @override
  Future<LocationAccess> currentAccess() async => LocationAccess.granted;

  @override
  Future<LocationAccess> ensurePermission() async => LocationAccess.granted;

  @override
  Stream<PositionFix> watch() async* {
    PositionFix fix() => PositionFix(lat: lat, lng: lng, accuracy: 8, timestampMs: DateTime.now().millisecondsSinceEpoch);
    yield fix();
    yield* Stream.periodic(const Duration(seconds: 1), (_) => fix());
  }
}

final locationServiceProvider = Provider<LocationService>((ref) {
  return ref.watch(demoModeProvider) ? const DemoLocationService() : const GeolocatorLocationService();
});

/// 自分の現在地。誰も見ていなければ GPS を止める（autoDispose）。
/// 許可が無いとエラー状態になり、Riverpod の自動リトライで許可後に動き出す。
final positionProvider = StreamProvider.autoDispose<PositionFix>((ref) {
  return ref.watch(locationServiceProvider).watch();
});
