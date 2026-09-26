// Map3dView が controller の指示を地図へどう渡すか（偽の地図で確かめる）と、近くのお店。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shibuya_machimachi/core/core.dart';
import 'package:shibuya_machimachi/features/map3d/map3d_screen.dart';
import 'package:shibuya_machimachi/features/map3d/src/map_backend.dart';
import 'package:shibuya_machimachi/features/map3d/src/map_math.dart';

class FakeMap implements MapBackend {
  final geo = <String, Map<String, dynamic>>{};
  final visibility = <String, bool>{};
  final animations = <(CameraState, Duration?)>[];
  final bearings = <double>[];
  CameraState cam = kInitialCamera;

  @override
  Future<void> setGeoJson(String sourceId, Map<String, dynamic> fc) async => geo[sourceId] = fc;
  @override
  Future<void> setLayerVisibility(String layerId, bool visible) async => visibility[layerId] = visible;
  @override
  Future<void> animateTo(CameraState camera, {Duration? duration}) async {
    animations.add((camera, duration));
    cam = camera;
  }

  @override
  Future<void> setBearing(double bearing) async {
    bearings.add(bearing);
    cam = cam.copyWith(bearing: bearing);
  }

  // 画面の中央付近に適当に並べる（ラベルが出ることだけ見る）。
  @override
  Future<List<Offset>> toScreen(List<GeoPoint> points) async => [
        for (var i = 0; i < points.length; i++) Offset(40.0 + (i * 37) % 260, 200),
      ];
  @override
  CameraState? get camera => cam;

  int features(String id) => ((geo[id]?['features'] as List?) ?? const []).length;
}

void main() {
  late FakeMap map;
  CameraState? initial;

  setUp(() {
    map = FakeMap();
    debugMap3dPlatformBuilder = ({required styleJson, required initialCamera, required onReady, required onCameraMove}) {
      initial = initialCamera;
      return _FakeMapWidget(onReady: () => onReady(map));
    };
  });
  tearDown(() => debugMap3dPlatformBuilder = null);

  Future<void> pumpView(WidgetTester tester, Map3dController c) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: SizedBox(width: 343, child: Map3dView(controller: c))),
    ));
    // 建物データ（4MB）の読み込みと style 作成を待つ
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
  }

  testWidgets('ピンが無い間はピッチ60で回り込み、ピンが来たら止まる', (tester) async {
    final c = Map3dController();
    await pumpView(tester, c);
    expect(initial!.pitch, 60);
    expect(initial!.zoom, 15.6);
    expect(initial!.bearing, -17);
    await tester.pump(const Duration(milliseconds: 300));
    expect(map.bearings, isNotEmpty);
    expect(map.bearings.last, greaterThan(-17));

    c.setMe(const MapPin(point: GeoPoint(35.659, 139.7005), floor: 3, name: 'ignored'));
    await tester.pump();
    final n = map.bearings.length;
    await tester.pump(const Duration(milliseconds: 300));
    expect(map.bearings.length, n, reason: '回り込みは止まる');
    expect(map.features('pins'), 1);
    expect(find.text('自分 ・ 3F'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('相手→focusBoth で2人が収まるように寄せ、点線を出す・道順を出すと点線を隠す', (tester) async {
    final c = Map3dController();
    await pumpView(tester, c);
    c.setMe(const MapPin(point: GeoPoint(35.6580, 139.7000), floor: 1));
    c.setPartner(const MapPin(point: GeoPoint(35.6600, 139.7020), floor: -2, name: 'すず'));
    c.focusBoth();
    await tester.pump();
    await tester.pump();
    expect(map.features('pins'), 2);
    expect(map.features('pins-line'), 1);
    expect(map.visibility['pins-line'], isTrue);
    final (cam, dur) = map.animations.last;
    expect(cam.pitch, 50);
    expect(cam.zoom, lessThanOrEqualTo(17));
    expect(dur, const Duration(milliseconds: 800));
    expect(find.text('すず ・ B2'), findsOneWidget);
    expect(find.text('ハチ公像'), findsOneWidget);

    final before = map.animations.length;
    c.setRoute(const [GeoPoint(35.6580, 139.7000), GeoPoint(35.6590, 139.7010), GeoPoint(35.6600, 139.7020)], fit: true);
    await tester.pump();
    await tester.pump();
    expect(map.features('route-line'), 1);
    expect(map.visibility['pins-line'], isFalse);
    expect(map.animations.length, before + 1, reason: 'fit の1回だけ寄せる');
    expect(map.animations.last.$1.zoom, lessThanOrEqualTo(17.5));

    c.setRoute(const [GeoPoint(35.6580, 139.7000), GeoPoint(35.6600, 139.7020)]);
    await tester.pump();
    await tester.pump();
    expect(map.animations.length, before + 1, reason: 'fit でない更新では寄せない');

    c.setRoute(null);
    await tester.pump();
    await tester.pump();
    expect(map.features('route-line'), 0);
    expect(map.visibility['pins-line'], isTrue);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('1人だけで focusBoth → そのピンへ z17', (tester) async {
    final c = Map3dController()..setMe(const MapPin(point: GeoPoint(35.659, 139.7005), floor: 1));
    await pumpView(tester, c);
    expect(initial!.pitch, 50, reason: '最初からピンがあれば回り込まない');
    c.focusBoth();
    await tester.pump();
    await tester.pump();
    expect(map.animations.last.$1.zoom, 17);
    expect(map.animations.last.$1.center, const GeoPoint(35.659, 139.7005));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('埋め込み先の build の途中で setPartner を呼んでも落ちず、次の拍で反映する', (tester) async {
    final c = Map3dController();
    await pumpView(tester, c);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Column(children: [
          SizedBox(width: 343, child: Map3dView(controller: c)),
          Builder(builder: (context) {
            c.setPartner(const MapPin(point: GeoPoint(35.6600, 139.7020), floor: 2, name: 'すず'));
            return const SizedBox();
          }),
        ]),
      ),
    ));
    await tester.pump();
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(map.features('pins'), 1);
    expect(find.text('すず ・ 2F'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  group('NearbyShopsList', () {
    const pois = [
      Poi(name: '遠い店', lat: 35.6650, lng: 139.7100),
      Poi(name: 'カフェA', lat: 35.6591, lng: 139.7006, level: '2'),
      Poi(name: '本屋B', lat: 35.6593, lng: 139.7008),
      Poi(name: '雑貨C', lat: 35.6596, lng: 139.7010, level: '-1;0'),
    ];

    Future<void> pumpShops(WidgetTester tester, GeoPoint? partner) async {
      await tester.pumpWidget(ProviderScope(
        overrides: [
          poisProvider.overrideWith((ref) async => pois),
          partnerEstimateProvider.overrideWith((ref) => partner),
        ],
        child: const MaterialApp(home: Scaffold(body: NearbyShopsList())),
      ));
      await tester.pumpAndSettle();
    }

    testWidgets('相手の推定位置の近い順に3件・距離と階', (tester) async {
      await pumpShops(tester, const GeoPoint(35.659, 139.7005));
      final names = tester.widgetList<Text>(find.byType(Text)).map((t) => t.data).toList();
      expect(names.where((n) => ['カフェA', '本屋B', '雑貨C', '遠い店'].contains(n)), ['カフェA', '本屋B', '雑貨C']);
      expect(find.text('2階'), findsOneWidget);
      expect(find.text('-1;0階'), findsOneWidget);
      expect(find.textContaining(RegExp(r'^\d+m$')), findsNWidgets(3));
    });

    testWidgets('相手の位置が無いときの文言', (tester) async {
      await pumpShops(tester, null);
      expect(find.text(NearbyShopsList.emptyText), findsOneWidget);
    });
  });
}

class _FakeMapWidget extends StatefulWidget {
  const _FakeMapWidget({required this.onReady});
  final VoidCallback onReady;
  @override
  State<_FakeMapWidget> createState() => _FakeMapWidgetState();
}

class _FakeMapWidgetState extends State<_FakeMapWidget> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => widget.onReady());
  }

  @override
  Widget build(BuildContext context) => const ColoredBox(color: Color(0xFFEEF1F3));
}
