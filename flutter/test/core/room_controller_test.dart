// RoomController のプライバシーの約束（承認前は送らない・圏外は送らない・間引き・stop 後は送らない）と再接続の終わり方。
import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shibuya_machimachi/core/core.dart';
import 'package:shibuya_machimachi/core/ws/room_socket.dart';

class FakeApi implements ApiClient {
  @override
  Future<CreateRoomResult> createRoom(String nickname) async =>
      CreateRoomResult(roomId: 'a' * 32, hostSecret: 'b' * 32, inviteToken: 'c' * 32);
  @override
  Future<String> preview(String roomId, String invite) async => 'りょう';
  @override
  Future<JoinResult> join(String roomId, String invite, String nickname) async => JoinResult(guestSecret: 'd' * 32);
  @override
  String inviteUrl(String roomId, String inviteToken) => 'https://example.invalid/r/$roomId?invite=$inviteToken';
  @override
  Uri wsUri(String roomId, Role role, String secret) => Uri.parse('wss://example.invalid/ws');
}

class FakeSocket implements RoomSocket {
  final _c = StreamController<String>.broadcast();
  final sent = <Map<String, Object?>>[];
  int? _code;
  String? _reason;
  void push(Map<String, Object?> m) => _c.add(jsonEncode(m));
  void serverClose(int code, String reason) {
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
  void emit(double lat, double lng) =>
      c.add(PositionFix(lat: lat, lng: lng, accuracy: 5, timestampMs: DateTime.now().millisecondsSinceEpoch));
  @override
  Future<LocationAccess> currentAccess() async => LocationAccess.granted;
  @override
  Future<LocationAccess> ensurePermission() async => LocationAccess.granted;
  @override
  Stream<PositionFix> watch() => c.stream;
}

Map<String, Object?> stateMsg(String phase) => {
      'type': 'state',
      'role': 'host',
      'phase': phase,
      'roomId': 'a' * 32,
      'self': {'nickname': 'りょう', 'approved': phase == 'active', 'floor': null, 'inArea': null},
      'other': null,
    };

Future<void> pump([int ms = 20]) => Future<void>.delayed(Duration(milliseconds: ms));

void main() {
  late ProviderContainer container;
  late FakeSocket socket;
  late FakeLocation loc;

  setUp(() {
    socket = FakeSocket();
    loc = FakeLocation();
    container = ProviderContainer(overrides: [
      apiClientProvider.overrideWithValue(FakeApi()),
      roomSocketConnectorProvider.overrideWithValue((_) async => socket),
      activeSessionStoreProvider.overrideWithValue(MemorySessionStore()),
      locationServiceProvider.overrideWithValue(loc),
    ]);
    container.listen(roomControllerProvider, (_, _) {});
  });
  tearDown(() => container.dispose());

  RoomController ctrl() => container.read(roomControllerProvider.notifier);
  RoomViewState view() => container.read(roomControllerProvider);

  test('相互承認の前は location を送らず、active になったら送る', () async {
    final session = await ctrl().createRoom('りょう');
    expect(session.inviteUrl, contains('invite='));
    await pump();
    socket.push(stateMsg('waiting_guest'));
    loc.emit(35.6585, 139.7016);
    await pump();
    socket.push(stateMsg('waiting_host_approval'));
    loc.emit(35.6585, 139.7016);
    await pump();
    expect(socket.ofType('location'), isEmpty);

    socket.push(stateMsg('active'));
    await pump();
    expect(socket.ofType('location'), hasLength(1));
    expect(socket.ofType('location').single.keys, containsAll(['lat', 'lng', 'acc']));
  });

  test('1.2秒以内の2回目は間引き、最新の1点をあとで送る', () async {
    await ctrl().createRoom('りょう');
    await pump();
    socket.push(stateMsg('active'));
    loc.emit(35.6585, 139.7016);
    await pump();
    loc.emit(35.6586, 139.7016);
    loc.emit(35.6587, 139.7016);
    await pump();
    expect(socket.ofType('location'), hasLength(1));
    await pump(1300);
    expect(socket.ofType('location'), hasLength(2));
    expect(socket.ofType('location').last['lat'], 35.6587);
  });

  test('渋谷1.5kmの外では送らず、圏外として表示する', () async {
    await ctrl().createRoom('りょう');
    await pump();
    socket.push(stateMsg('active'));
    loc.emit(35.6812, 139.7671); // 東京駅
    await pump();
    expect(socket.ofType('location'), isEmpty);
    expect(view().selfOutOfArea, isTrue);
  });

  test('stop を押したら、以後は位置を送らない', () async {
    await ctrl().createRoom('りょう');
    await pump();
    socket.push(stateMsg('active'));
    loc.emit(35.6585, 139.7016);
    await pump();
    expect(ctrl().stop(), isTrue);
    await pump(1300);
    loc.emit(35.6586, 139.7016);
    await pump();
    expect(socket.ofType('stop'), hasLength(1));
    expect(socket.ofType('location'), hasLength(1));
  });

  test('close 4001（別の接続が来た）では再接続しない', () async {
    await ctrl().createRoom('りょう');
    await pump();
    socket.push(stateMsg('waiting_guest'));
    await pump();
    socket.serverClose(4001, 'duplicate_connection');
    await pump();
    expect(view().endedBy, ConnectionEnd.duplicate);
  });

  test('期限切れの最小形 state で終端になり、セッションが消える', () async {
    await ctrl().createRoom('りょう');
    await pump();
    socket.push({'type': 'state', 'phase': 'expired'});
    await pump();
    expect(view().phase, Phase.expired);
    expect(await container.read(activeSessionStoreProvider).load('a' * 32), isNull);
  });

  test('ニックネームが空なら API を呼ばずに invalid_nickname', () async {
    expect(() => ctrl().createRoom('  '), throwsA(isA<ApiException>().having((e) => e.reason, 'reason', 'invalid_nickname')));
  });
}
