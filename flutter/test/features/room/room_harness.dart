// room のウィジェットテスト用の部品（偽の API・WebSocket・位置、差し替えた 3D/道順、テスト用ルーター）。
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shibuya_machimachi/core/core.dart';
import 'package:shibuya_machimachi/core/ws/room_socket.dart';
import 'package:shibuya_machimachi/features/room/room_screen.dart';
import 'package:shibuya_machimachi/features/room/src/meet_slots.dart';

final String kRoomId = 'a' * 32;
final String kInvite = 'c' * 32;

class FakeApi implements ApiClient {
  ApiException? createError;
  ApiException? previewError;
  ApiException? joinError;
  String hostNickname = 'りょう';
  final calls = <String>[];

  @override
  Future<CreateRoomResult> createRoom(String nickname) async {
    calls.add('create:$nickname');
    if (createError != null) throw createError!;
    return CreateRoomResult(roomId: kRoomId, hostSecret: 'b' * 32, inviteToken: kInvite);
  }

  @override
  Future<String> preview(String roomId, String invite) async {
    calls.add('preview');
    if (previewError != null) throw previewError!;
    return hostNickname;
  }

  @override
  Future<JoinResult> join(String roomId, String invite, String nickname) async {
    calls.add('join:$nickname');
    if (joinError != null) throw joinError!;
    return JoinResult(guestSecret: 'd' * 32);
  }

  @override
  String inviteUrl(String roomId, String inviteToken) => '$kProdBaseUrl/r/$roomId?invite=$inviteToken';

  @override
  Uri wsUri(String roomId, Role role, String secret) => Uri.parse('wss://example.invalid/ws');
}

class FakeSocket implements RoomSocket {
  final _c = StreamController<String>.broadcast();
  final sent = <Map<String, Object?>>[];
  int? _code;
  String? _reason;

  void push(Map<String, Object?> m) => _c.add(jsonEncode(m));
  void serverClose(int code, [String reason = '']) {
    _code = code;
    _reason = reason;
    _c.close();
  }

  List<Map<String, Object?>> ofType(String t) => sent.where((m) => m['type'] == t).toList();

  @override
  Stream<String> get messages => _c.stream;
  @override
  void send(String text) => sent.add((jsonDecode(text) as Map).cast<String, Object?>());
  @override
  Future<void> close([int? code, String? reason]) async {
    if (!_c.isClosed) await _c.close();
  }

  @override
  int? get closeCode => _code;
  @override
  String? get closeReason => _reason;
}

class FakeLocation implements LocationService {
  final c = StreamController<PositionFix>.broadcast();
  int permissionAsks = 0;
  void emit(double lat, double lng) =>
      c.add(PositionFix(lat: lat, lng: lng, accuracy: 5, timestampMs: DateTime.now().millisecondsSinceEpoch));
  @override
  Future<LocationAccess> currentAccess() async => LocationAccess.granted;
  @override
  Future<LocationAccess> ensurePermission() async {
    permissionAsks++;
    return LocationAccess.granted;
  }

  @override
  Stream<PositionFix> watch() => c.stream;
}

const testPlaces = [
  Place(id: 'hachiko', name: 'ハチ公像', lat: 35.65910, lng: 139.70060),
  Place(id: 'moyai', name: 'モヤイ像', lat: 35.65800, lng: 139.70030),
];

const testPois = [
  Poi(name: 'カフェA', lat: 35.65930, lng: 139.70040, level: '1'),
  Poi(name: '本屋B', lat: 35.65950, lng: 139.70020),
];

/// 3D と道順は軽い代わりに差し替える（中身は他の担当のテストで見る）。
MeetSlots fakeSlots() => MeetSlots(
      map3d: (context, c) => ListenableBuilder(
        listenable: c,
        builder: (_, _) => Text(
          'map3d me=${c.me != null} partner=${c.partner?.name} route=${c.route?.length} focus=${c.focusRequest}',
        ),
      ),
      routePanel: (context, target, onRoute, onArrive) => Text('route-panel:${target?.name ?? '-'}'),
    );

/// テスト1本ぶんの環境。
class RoomHarness {
  RoomHarness({this.demo = false, this.slots});

  final bool demo;

  /// 3D・道順の差し替え（null なら fakeSlots）。
  final MeetSlots? slots;
  final api = FakeApi();
  final loc = FakeLocation();
  final sockets = <FakeSocket>[];
  final clipboard = <String>[];
  int haptics = 0;
  late final ProviderContainer container;
  late final GoRouter router;

  FakeSocket get socket => sockets.last;

  List<Map<String, Object?>> allSent() => [for (final s in sockets) ...s.sent];

  RoomController get ctrl => container.read(roomControllerProvider.notifier);
  RoomViewState get view => container.read(roomControllerProvider);

  Future<void> start(WidgetTester tester, String initialLocation) async {
    // 縦に長い画面にして、スクロールせずに全部押せるようにする。
    tester.view.physicalSize = const Size(480, 6000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') clipboard.add((call.arguments as Map)['text'] as String);
      if (call.method == 'HapticFeedback.vibrate') haptics++;
      return null;
    });
    container = ProviderContainer(overrides: [
      headingProvider.overrideWith((ref) => Stream<double?>.value(null)),
      placesProvider.overrideWith((ref) => Future.value(testPlaces)),
      poisProvider.overrideWith((ref) => Future.value(testPois)),
      meetSlotsProvider.overrideWithValue(slots ?? fakeSlots()),
      // 端末の secure storage（プラグイン）には触らない。
      sessionStoreProvider.overrideWithValue(MemorySessionStore()),
      if (!demo) ...[
        apiClientProvider.overrideWithValue(api),
        roomSocketConnectorProvider.overrideWithValue((_) async {
          final s = FakeSocket();
          sockets.add(s);
          return s;
        }),
        activeSessionStoreProvider.overrideWithValue(MemorySessionStore()),
        locationServiceProvider.overrideWithValue(loc),
      ],
    ]);
    router = GoRouter(
      initialLocation: initialLocation,
      routes: [
        GoRoute(
          path: '/new',
          builder: (_, s) => CreateRoomScreen(key: ValueKey(s.uri.toString()), startDemo: s.uri.queryParameters['demo'] == '1'),
        ),
        GoRoute(
          path: '/r/:roomId',
          builder: (_, s) => RoomScreen(
            key: ValueKey(s.pathParameters['roomId']),
            roomId: s.pathParameters['roomId']!,
            invite: s.uri.queryParameters['invite'],
          ),
        ),
        GoRoute(path: '/go', builder: (_, _) => const Scaffold(body: Text('go-screen'))),
        GoRoute(path: '/ar', builder: (_, _) => const Scaffold(body: Text('ar-screen'))),
        GoRoute(path: '/hq', builder: (_, _) => const Scaffold(body: Text('hq-screen'))),
      ],
    );
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        theme: buildAppTheme(),
        routerConfig: router,
        locale: const Locale('ja', 'JP'),
        supportedLocales: const [Locale('ja', 'JP')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
      ),
    ));
    await tester.pump();
    await tester.pump();
  }

  /// 画面を外し、タイマーとセッションを止める（pending timer を残さない）。
  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await ctrl.leave();
    container.dispose();
    router.dispose();
    await tester.pump(const Duration(seconds: 1));
  }
}

/// サーバーの state（host 視点）。
Map<String, Object?> stateMsg(
  String phase, {
  String role = 'host',
  String selfNick = 'りょう',
  String? otherNick,
  int? distance,
  int? bearing,
  int? lastUpdatedAt,
  bool? otherInArea,
  String? otherFloor,
  String? floorDiff,
  Map<String, Object?>? meetSpot,
  Map<String, Object?>? stopped,
  Map<String, Object?>? judge,
}) =>
    {
      'type': 'state',
      'role': role,
      'phase': phase,
      'roomId': kRoomId,
      'self': {'nickname': selfNick, 'approved': phase == 'active', 'floor': null, 'inArea': null},
      'other': otherNick == null
          ? null
          : {
              'nickname': otherNick,
              'approved': true,
              'connected': true,
              'inArea': otherInArea,
              'floor': otherFloor,
              'lastUpdatedAt': lastUpdatedAt,
            },
      'distance_m': distance,
      'bearing_deg': bearing,
      'floorDiffText': floorDiff,
      'meetSpot': meetSpot,
      'stopped': stopped,
      'judge': judge,
    };

/// 何度か pump して非同期の続き（Future・Stream）を流す。
Future<void> settle(WidgetTester tester, [int times = 4]) async {
  for (var i = 0; i < times; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}
