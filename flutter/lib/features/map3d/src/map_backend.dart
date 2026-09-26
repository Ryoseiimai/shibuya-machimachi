// 地図エンジン（maplibre_gl）への窓口。Map3dView はこの小さな面だけを使うので、テストでは偽物に差し替えられる。
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

import '../../../core/core.dart';
import 'map_math.dart';

abstract interface class MapBackend {
  Future<void> setGeoJson(String sourceId, Map<String, dynamic> featureCollection);
  Future<void> setLayerVisibility(String layerId, bool visible);

  /// duration が null なら端末の既定の速さ。
  Future<void> animateTo(CameraState camera, {Duration? duration});
  Future<void> setBearing(double bearing);

  /// 画面上の位置（論理 px）。
  Future<List<Offset>> toScreen(List<GeoPoint> points);

  CameraState? get camera;
}

/// 地図の部品を作る関数。onReady は style を読み終えたあとに1回、onCameraMove はカメラが動くたびに呼ぶ。
typedef Map3dPlatformBuilder = Widget Function({
  required String styleJson,
  required CameraState initialCamera,
  required ValueChanged<MapBackend> onReady,
  required VoidCallback onCameraMove,
});

/// テスト用の差し替え口（null なら本物の MapLibreMap）。
@visibleForTesting
Map3dPlatformBuilder? debugMap3dPlatformBuilder;

Map3dPlatformBuilder get map3dPlatformBuilder => debugMap3dPlatformBuilder ?? buildMapLibreView;

class MapLibreBackend implements MapBackend {
  MapLibreBackend(this._c, this._devicePixelRatio);
  final MapLibreMapController _c;

  /// Android の toScreenLocation は物理ピクセルで返るので論理 px に直す（iOS は point のまま）。
  final double _devicePixelRatio;

  @override
  Future<void> setGeoJson(String sourceId, Map<String, dynamic> featureCollection) => _c.setGeoJsonSource(sourceId, featureCollection);

  @override
  Future<void> setLayerVisibility(String layerId, bool visible) => _c.setLayerVisibility(layerId, visible);

  @override
  Future<void> animateTo(CameraState camera, {Duration? duration}) => _c.animateCamera(
        CameraUpdate.newCameraPosition(CameraPosition(
          target: LatLng(camera.center.lat, camera.center.lng),
          zoom: camera.zoom,
          bearing: camera.bearing,
          tilt: camera.pitch,
        )),
        duration: duration,
      );

  @override
  Future<void> setBearing(double bearing) => _c.moveCamera(CameraUpdate.bearingTo(bearing));

  @override
  Future<List<Offset>> toScreen(List<GeoPoint> points) async {
    if (points.isEmpty) return const [];
    final raw = await _c.toScreenLocationBatch(points.map((p) => LatLng(p.lat, p.lng)));
    final scale = defaultTargetPlatform == TargetPlatform.android ? _devicePixelRatio : 1.0;
    return [for (final p in raw) Offset(p.x.toDouble() / scale, p.y.toDouble() / scale)];
  }

  @override
  CameraState? get camera {
    final p = _c.cameraPosition;
    if (p == null) return null;
    return CameraState(center: GeoPoint(p.target.latitude, p.target.longitude), zoom: p.zoom, bearing: p.bearing, pitch: p.tilt);
  }
}

Widget buildMapLibreView({
  required String styleJson,
  required CameraState initialCamera,
  required ValueChanged<MapBackend> onReady,
  required VoidCallback onCameraMove,
}) =>
    _MapLibreHost(styleJson: styleJson, initialCamera: initialCamera, onReady: onReady, onCameraMove: onCameraMove);

class _MapLibreHost extends StatefulWidget {
  const _MapLibreHost({required this.styleJson, required this.initialCamera, required this.onReady, required this.onCameraMove});
  final String styleJson;
  final CameraState initialCamera;
  final ValueChanged<MapBackend> onReady;
  final VoidCallback onCameraMove;

  @override
  State<_MapLibreHost> createState() => _MapLibreHostState();
}

class _MapLibreHostState extends State<_MapLibreHost> {
  MapLibreMapController? _controller;

  @override
  Widget build(BuildContext context) {
    final maxB = computeMaxBounds();
    final cam = widget.initialCamera;
    return MapLibreMap(
      styleString: widget.styleJson,
      initialCameraPosition: CameraPosition(
        target: LatLng(cam.center.lat, cam.center.lng),
        zoom: cam.zoom,
        bearing: cam.bearing,
        tilt: cam.pitch,
      ),
      minMaxZoomPreference: const MinMaxZoomPreference(kMinZoom, kMaxZoom),
      cameraTargetBounds: CameraTargetBounds(LatLngBounds(
        southwest: LatLng(maxB.south, maxB.west),
        northeast: LatLng(maxB.north, maxB.east),
      )),
      rotateGesturesEnabled: true,
      tiltGesturesEnabled: true,
      compassEnabled: true,
      compassViewPosition: CompassViewPosition.topRight,
      logoEnabled: false,
      // 出典は地図の外（埋め込み先の AttributionText）で一元的に出す（Web 版と同じ）。
      attributionButtonPosition: AttributionButtonPosition.bottomRight,
      myLocationEnabled: false,
      trackCameraPosition: true,
      // ページのスクロールより地図の操作を優先する（Web 版も地図の上では地図が動く）。
      gestureRecognizers: <Factory<OneSequenceGestureRecognizer>>{
        Factory<OneSequenceGestureRecognizer>(EagerGestureRecognizer.new),
      },
      onMapCreated: (c) => _controller = c,
      onStyleLoadedCallback: () {
        final c = _controller;
        if (c == null || !mounted) return;
        widget.onReady(MapLibreBackend(c, MediaQuery.devicePixelRatioOf(context)));
      },
      onCameraMove: (_) => widget.onCameraMove(),
      onCameraIdle: widget.onCameraMove,
    );
  }
}
