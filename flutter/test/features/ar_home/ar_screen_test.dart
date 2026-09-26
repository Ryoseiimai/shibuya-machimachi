// AR 画面: 人影・端の矢印・中立表示・赤帯・設定を開く・道順モード・自分で閉じる・カメラの開け閉め。
// カメラとセンサーは全部フェイク（プラグインには触れない）。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:shibuya_machimachi/core/core.dart';
import 'package:shibuya_machimachi/features/ar_home/ar_camera.dart';
import 'package:shibuya_machimachi/features/ar_home/ar_home_screen.dart';

const me = GeoPoint(35.6590, 139.7005);

class FakeArCamera implements ArCamera {
  FakeArCamera(this.result);
  ArCameraStatus result;
  int starts = 0;
  int stops = 0;

  @override
  Future<ArCameraStatus> start() async {
    starts++;
    return result;
  }

  @override
  Widget buildPreview() => const ColoredBox(key: ValueKey('fake-preview'), color: Colors.green);

  @override
  Future<void> stop() async => stops++;
}

class FakeRoomController extends RoomController {
  FakeRoomController(this.initial);
  final RoomViewState initial;

  @override
  RoomViewState build() => initial;

  void put(RoomViewState s) => state = s;
}

RoomViewState activeState({String? nick = 'たかし', String? otherFloor = '3F', String? selfFloor = '1F'}) => RoomViewState(
  server: RoomState(
    phase: Phase.active,
    self: SelfView(nickname: 'わたし', approved: true, floor: selfFloor),
    other: OtherView(nickname: nick, approved: true, connected: true, floor: otherFloor),
    distanceM: 60,
    bearingDeg: 0,
  ),
);

PositionFix fixAt(GeoPoint p) => PositionFix(lat: p.lat, lng: p.lng, accuracy: 5, timestampMs: 0);

class Harness {
  Harness({
    this.camera = ArCameraStatus.ready,
    this.heading,
    this.headingNone = false,
    this.partner,
    RoomViewState? room,
    this.positionError = false,
  }) : room = room ?? activeState();

  final ArCameraStatus camera;
  final Stream<double?>? heading;
  final bool headingNone;
  final GeoPoint? partner;
  final RoomViewState room;
  final bool positionError;

  late final FakeArCamera cam = FakeArCamera(camera);
  late final FakeRoomController controller = FakeRoomController(room);
  int settingsOpened = 0;

  List<Override> get overrides => [
    arCameraFactoryProvider.overrideWithValue(() => cam),
    arOpenSettingsProvider.overrideWithValue(() async {
      settingsOpened++;
      return true;
    }),
    roomControllerProvider.overrideWith(() => controller),
    positionProvider.overrideWith(
      (ref) => positionError ? Stream<PositionFix>.error(StateError('denied')) : Stream.value(fixAt(me)),
    ),
    headingProvider.overrideWith(
      (ref) => heading ?? (headingNone ? Stream<double?>.value(null) : Stream<double?>.value(0)),
    ),
    tiltProvider.overrideWith((ref) => Stream.value(90.0)),
    partnerEstimateProvider.overrideWith((ref) => partner),
  ];
}

Future<ProviderContainer> pumpAr(
  WidgetTester tester,
  Harness h, {
  Size surface = const Size(390, 844),
  double textScale = 1,
}) async {
  await tester.binding.setSurfaceSize(surface);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    ProviderScope(
      overrides: h.overrides,
      child: MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: FilledButton(
                onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const ArScreen())),
                child: const Text('ARで探す'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('ARで探す'));
  await tester.pumpAndSettle();
  return ProviderScope.containerOf(tester.element(find.byType(ArScreen)));
}

void main() {
  testWidgets('正面の相手: 人影・名前・距離・階差バッジ。カメラ映像が出る', (tester) async {
    final h = Harness(partner: destinationPoint(me.lat, me.lng, 0, 60));
    await pumpAr(tester, h);
    expect(find.byKey(const ValueKey('fake-preview')), findsOneWidget);
    expect(find.byKey(const ValueKey('ar-silhouette')), findsOneWidget);
    expect(find.text('たかし'), findsOneWidget);
    expect(find.text('あと60m'), findsOneWidget);
    expect(find.text('↑2階上'), findsOneWidget);
    expect(find.byKey(const ValueKey('ar-error-band')), findsNothing);
    expect(find.text('相手: たかし'), findsOneWidget);
    expect(h.cam.starts, 1);
  });

  testWidgets('右にいる相手: 右端の矢印', (tester) async {
    final h = Harness(partner: destinationPoint(me.lat, me.lng, 100, 120));
    await pumpAr(tester, h);
    expect(find.byKey(const ValueKey('ar-silhouette')), findsNothing);
    expect(find.text('→ 右に振り向いて（あと120m・たかし）'), findsOneWidget);
  });

  testWidgets('相手の階が未設定なら階差バッジを出さない', (tester) async {
    final h = Harness(partner: destinationPoint(me.lat, me.lng, 0, 60), room: activeState(otherFloor: null));
    await pumpAr(tester, h);
    expect(find.byKey(const ValueKey('ar-floor-badge')), findsNothing);
  });

  testWidgets('向きセンサーが無い: 中立表示と赤帯（方向は出さない）', (tester) async {
    final h = Harness(partner: destinationPoint(me.lat, me.lng, 0, 60), headingNone: true);
    await pumpAr(tester, h);
    expect(find.byKey(const ValueKey('ar-silhouette')), findsNothing);
    expect(find.bySemanticsLabel('コンパスが使えないので方向は出せません。距離: 60m'), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp('向き\\(コンパス\\)に対応していない')), findsOneWidget);
    expect(find.text('設定を開く'), findsNothing);
  });

  testWidgets('向きの値が来ないまま3秒たったら中立表示＋赤帯', (tester) async {
    final never = StreamController<double?>();
    addTearDown(never.close);
    final h = Harness(partner: destinationPoint(me.lat, me.lng, 0, 60), heading: never.stream);
    await pumpAr(tester, h);
    expect(find.bySemanticsLabel('向きを確かめています…　距離: 60m'), findsOneWidget);
    expect(find.byKey(const ValueKey('ar-error-band')), findsNothing);
    await tester.pump(const Duration(seconds: 3));
    expect(find.bySemanticsLabel('コンパスが使えないので方向は出せません。距離: 60m'), findsOneWidget);
    expect(find.byKey(const ValueKey('ar-error-band')), findsOneWidget);
    // あとから値が来たら方向を出す
    never.add(0);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('ar-silhouette')), findsOneWidget);
    expect(find.byKey(const ValueKey('ar-error-band')), findsNothing);
  });

  testWidgets('カメラ拒否: 灰色の地・赤帯・「設定を開く」', (tester) async {
    final h = Harness(partner: destinationPoint(me.lat, me.lng, 0, 60), camera: ArCameraStatus.denied);
    await pumpAr(tester, h);
    expect(find.byKey(const ValueKey('ar-no-camera')), findsOneWidget);
    expect(find.byKey(const ValueKey('fake-preview')), findsNothing);
    expect(find.bySemanticsLabel(RegExp('カメラの利用が許可されませんでした')), findsOneWidget);
    await tester.tap(find.text('設定を開く'));
    await tester.pump();
    expect(h.settingsOpened, 1);
    // 人影（方向）はカメラが無くても出す
    expect(find.byKey(const ValueKey('ar-silhouette')), findsOneWidget);
  });

  testWidgets('カメラが無い端末: 赤帯（設定ボタンは出さない）', (tester) async {
    final h = Harness(partner: destinationPoint(me.lat, me.lng, 0, 60), camera: ArCameraStatus.unavailable);
    await pumpAr(tester, h);
    expect(find.bySemanticsLabel('この端末・ブラウザではカメラが利用できません。'), findsOneWidget);
    expect(find.text('設定を開く'), findsNothing);
  });

  testWidgets('相手の位置がまだ: 「相手の位置を待っています…」', (tester) async {
    final h = Harness();
    await pumpAr(tester, h);
    expect(find.bySemanticsLabel('相手の位置を待っています…'), findsOneWidget);
  });

  testWidgets('位置が取れない: 赤帯と「設定を開く」', (tester) async {
    final h = Harness(partner: destinationPoint(me.lat, me.lng, 0, 60), positionError: true);
    await pumpAr(tester, h);
    expect(find.bySemanticsLabel('現在地が取れません'), findsOneWidget);
    expect(find.text('設定を開く'), findsOneWidget);
  });

  testWidgets('道順モード: 次の曲がり角を指し、終点では行き先名と階', (tester) async {
    final h = Harness();
    final c = await pumpAr(tester, h);
    final corner = destinationPoint(me.lat, me.lng, 0, 40);
    final end = destinationPoint(corner.lat, corner.lng, 20, 30);
    c
        .read(arGuideProvider.notifier)
        .set(ArGuide(route: [me, corner, end], destinationName: 'ハチ公像', destinationLevel: 0));
    await tester.pumpAndSettle();
    expect(find.text('道順: ハチ公像まで'), findsOneWidget);
    expect(find.text('次の曲がり角'), findsOneWidget);
    expect(find.text('あと40m'), findsOneWidget);
    expect(find.byKey(const ValueKey('ar-floor-badge')), findsNothing); // 途中の点は階が分からないので出さない

    // 曲がり角が無ければ終点（行き先名）を指し、行き先の階との差も出す
    c.read(arGuideProvider.notifier).set(ArGuide(route: [me, end], destinationName: 'ハチ公像', destinationLevel: 2));
    await tester.pumpAndSettle();
    expect(find.text('ハチ公像'), findsOneWidget);
    expect(find.text('↑2階上'), findsOneWidget); // level 2 = 3F、自分は 1F

    c.read(arGuideProvider.notifier).clear();
    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel('相手の位置を待っています…'), findsOneWidget);
  });

  testWidgets('待ち合わせが止まったら自分で閉じる', (tester) async {
    final h = Harness(partner: destinationPoint(me.lat, me.lng, 0, 60));
    await pumpAr(tester, h);
    expect(find.byType(ArScreen), findsOneWidget);
    h.controller.put(const RoomViewState(server: RoomState(phase: Phase.stopped)));
    await tester.pumpAndSettle();
    expect(find.byType(ArScreen), findsNothing);
    expect(h.cam.stops, greaterThanOrEqualTo(1));
  });

  testWidgets('✕で閉じる（tooltip「閉じる」・40px）とカメラを閉じる', (tester) async {
    final h = Harness(partner: destinationPoint(me.lat, me.lng, 0, 60));
    await pumpAr(tester, h);
    final btn = find.byTooltip('閉じる');
    expect(tester.getSize(find.ancestor(of: btn, matching: find.byType(SizedBox)).first), const Size(40, 40));
    await tester.tap(btn);
    await tester.pumpAndSettle();
    expect(find.byType(ArScreen), findsNothing);
    expect(h.cam.stops, 1);
  });

  testWidgets('裏に回ったらカメラを閉じ、戻ったら開き直す', (tester) async {
    final h = Harness(partner: destinationPoint(me.lat, me.lng, 0, 60));
    await pumpAr(tester, h);
    expect(h.cam.starts, 1);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    expect(h.cam.stops, 1);
    expect(find.byKey(const ValueKey('fake-preview')), findsNothing);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(h.cam.starts, 2);
    expect(find.byKey(const ValueKey('fake-preview')), findsOneWidget);
  });

  testWidgets('拒否のあと設定から戻ったら、もう一度確かめる', (tester) async {
    final h = Harness(partner: destinationPoint(me.lat, me.lng, 0, 60), camera: ArCameraStatus.denied);
    await pumpAr(tester, h);
    h.cam.result = ArCameraStatus.ready;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(h.cam.starts, 2);
    expect(find.byKey(const ValueKey('fake-preview')), findsOneWidget);
    expect(find.text('設定を開く'), findsNothing);
  });

  testWidgets('小さい画面・文字 200% でも赤帯と中立表示がはみ出さない', (tester) async {
    final h = Harness(
      partner: destinationPoint(me.lat, me.lng, 0, 60),
      headingNone: true,
      camera: ArCameraStatus.denied,
    );
    await pumpAr(tester, h, surface: const Size(320, 568), textScale: 2);
    expect(tester.takeException(), isNull);
    expect(find.text('設定を開く'), findsOneWidget);
    expect(find.byKey(const ValueKey('ar-center-card')), findsOneWidget);
  });
}
