// 道順パネル（RoutePanel）と場所モード（GoScreen）の画面テスト。位置・向き・道のデータはプロバイダを差し替える
// （GPS もセンサーも使わない。通信もしない）。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shibuya_machimachi/core/core.dart';
import 'package:shibuya_machimachi/features/route/engine/graph_provider.dart';
import 'package:shibuya_machimachi/features/route/engine/route_engine.dart';
import 'package:shibuya_machimachi/features/route/route_screen.dart';

import 'graph_helpers.dart';

class FakeLocation implements LocationService {
  FakeLocation(this.lat, this.lng);
  final double lat;
  final double lng;
  int permissionRequests = 0;

  @override
  Future<LocationAccess> currentAccess() async => LocationAccess.granted;

  @override
  Future<LocationAccess> ensurePermission() async {
    permissionRequests++;
    return LocationAccess.granted;
  }

  @override
  Stream<PositionFix> watch() {
    final c = StreamController<PositionFix>();
    c.add(PositionFix(lat: lat, lng: lng, accuracy: 5, timestampMs: 0));
    return c.stream;
  }
}

Widget app(Widget child, List overrides) => ProviderScope(
      overrides: [...overrides.cast()],
      child: MaterialApp(theme: buildAppTheme(), home: child),
    );

Widget panelPage(Widget panel) => Scaffold(body: ListView(children: [panel]));

void useTallScreen(WidgetTester tester) {
  tester.view.physicalSize = const Size(480 * 3, 2400 * 3);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
}

void main() {
  final escalator = makeGraph([
    [0, 0],
    [0, 60],
    [0, 75],
    [0, 140],
  ], [
    [0, 1, EdgeType.walk, 0, 0],
    [1, 2, EdgeType.escalator, 0, 1],
    [2, 3, EdgeType.walk, 1, 1],
  ]);

  testWidgets('RoutePanel(場所): 階の移動の案内と「2階に着いた」→ 今いる階が 2F になり、上の階から案内を続ける', (tester) async {
    useTallScreen(tester);
    final here = at(0, 55);
    final goal = at(0, 140);
    final lines = <List<GeoPoint>?>[];
    await tester.pumpWidget(app(
      panelPage(RoutePanel(
        mode: RoutePanelMode.place,
        target: RouteTarget(point: GeoPoint(goal.lat, goal.lng), name: 'ゴール', level: 1),
        onRoute: lines.add,
      )),
      [
        routeGraphProvider.overrideWith((ref) async => escalator),
        positionProvider.overrideWith((ref) => Stream.value(PositionFix(lat: here.lat, lng: here.lng, timestampMs: 0))),
        headingProvider.overrideWith((ref) => Stream.value(null)),
      ],
    ));
    await tester.pumpAndSettle();

    expect(find.text('道順で案内'), findsOneWidget);
    expect(find.text('エスカレーターで2階へ'), findsOneWidget);
    expect(find.text('残り85m・約1分'), findsOneWidget);
    expect(find.text('サーバーには'), findsOneWidget, reason: '場所モードの注記');
    expect(lines, isNotEmpty);
    expect(lines.last!.length, greaterThanOrEqualTo(2));

    final container = ProviderScope.containerOf(tester.element(find.byType(RoutePanel)));
    await tester.tap(find.text('2階に着いた'));
    await tester.pumpAndSettle();
    expect(container.read(ownFloorProvider), '2F');
    expect(find.text('あと65mで到着'), findsOneWidget);
    expect(find.text('2階に着いた'), findsNothing);
  });

  testWidgets('RoutePanel(人): 行き先なしは「相手の位置を待っています…」、チップで階を変えられる', (tester) async {
    useTallScreen(tester);
    final here = at(0, 10);
    await tester.pumpWidget(app(
      panelPage(const RoutePanel(mode: RoutePanelMode.person, target: null)),
      [
        routeGraphProvider.overrideWith((ref) async => escalator),
        positionProvider.overrideWith((ref) => Stream.value(PositionFix(lat: here.lat, lng: here.lng, timestampMs: 0))),
        headingProvider.overrideWith((ref) => Stream.value(90)),
      ],
    ));
    await tester.pumpAndSettle();
    expect(find.text('相手の位置を待っています…'), findsOneWidget);
    expect(find.text('推定です。'), findsOneWidget, reason: '人モードの注記');
    final container = ProviderScope.containerOf(tester.element(find.byType(RoutePanel)));
    await tester.tap(find.text('B1'));
    await tester.pumpAndSettle();
    expect(container.read(ownFloorProvider), 'B1');
  });

  testWidgets('幅320・文字200%でも道順パネルがはみ出さない', (tester) async {
    tester.view.physicalSize = const Size(320 * 3, 2400 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final here = at(0, 55);
    final goal = at(0, 140);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        routeGraphProvider.overrideWith((ref) async => escalator),
        positionProvider.overrideWith((ref) => Stream.value(PositionFix(lat: here.lat, lng: here.lng, timestampMs: 0))),
        headingProvider.overrideWith((ref) => Stream.value(null)),
      ],
      child: MaterialApp(
        theme: buildAppTheme(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: const TextScaler.linear(2)),
          child: child!,
        ),
        home: panelPage(RoutePanel(
          mode: RoutePanelMode.person,
          target: RouteTarget(point: GeoPoint(goal.lat, goal.lng), name: 'とても長いニックネームの相手さん', level: 1),
        )),
      ),
    ));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('エスカレーターで2階へ'), findsOneWidget);
  });

  group('GoScreen', () {
    final places = parsePlaces(jsonDecode(File(kAssetPlaces).readAsStringSync()));
    final graph = decodeGraphText(File(kAssetGraph).readAsStringSync());
    final hachiko = places.firstWhere((p) => p.id == 'hachiko');

    testWidgets('一覧（13件・直線距離）→ 選ぶと許可を求めて道順パネルと3D → 「ほかの場所を選ぶ」で戻る', (tester) async {
      useTallScreen(tester);
      final loc = FakeLocation(hachiko.lat, hachiko.lng);
      await tester.pumpWidget(app(const GoScreen(), [
        placesProvider.overrideWith((ref) async => places),
        routeGraphProvider.overrideWith((ref) async => graph),
        locationServiceProvider.overrideWithValue(loc),
        headingProvider.overrideWith((ref) => Stream.value(null)),
      ]));
      await tester.pumpAndSettle();

      expect(find.text('場所へ行く（1人で使えます）'), findsOneWidget);
      for (final p in places) {
        expect(find.text(p.name), findsOneWidget, reason: p.name);
      }
      expect(find.textContaining('直線'), findsNWidgets(13));
      expect(loc.permissionRequests, 0, reason: '許可はタップの中でだけ求める');

      await tester.tap(find.text('モヤイ像'));
      await tester.pumpAndSettle();
      expect(loc.permissionRequests, 1);
      expect(find.text('道順で案内'), findsOneWidget);
      expect(find.text('モヤイ像 1階', findRichText: true), findsOneWidget, reason: '行き先の名前と階');
      expect(find.text('3D渋谷（オレンジの線が道順）'), findsOneWidget);
      expect(find.textContaining('残り'), findsOneWidget, reason: '案内中');
      final container = ProviderScope.containerOf(tester.element(find.byType(GoScreen)));
      expect(container.read(ownFloorProvider), '1F', reason: '未設定なら1F');

      await tester.tap(find.text('ほかの場所を選ぶ'));
      await tester.pumpAndSettle();
      expect(find.text('場所へ行く（1人で使えます）'), findsOneWidget);
    });
  });
}
