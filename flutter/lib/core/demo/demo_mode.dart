// デモモード（1台で体験）。app/src/demo.js の移植。
// API と WebSocket を端末内の模擬に差し替える。何も送信しない。位置は固定点（DemoLocationService）。
import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/api_client.dart';
import '../constants.dart';
import '../floors.dart';
import '../geo.dart';
import '../models/room_models.dart';
import '../ws/room_socket.dart';

/// デモ中か。true の間は API・WS・位置・セッション保存がすべて模擬に替わる。
class DemoModeNotifier extends Notifier<bool> {
  @override
  bool build() => false;

  void start() => state = true;
  void end() => state = false;
}

final demoModeProvider = NotifierProvider<DemoModeNotifier, bool>(DemoModeNotifier.new);

/// デモの定数（demo.js と同じ）。
abstract final class DemoConfig {
  static final String roomId = 'de${'0' * 30}';
  static const partnerNickname = 'すず';
  static const selfLat = 35.65905;
  static const selfLng = 139.70058;
  static const partnerStartBearingDeg = 300.0;
  static const partnerStartDistanceM = 260.0;
  static const walkSpeedMps = 5.0;
  static const arriveDistanceM = 6.0;
  static const partnerStartFloor = '2F';
  static const partnerArriveFloor = '1F';
  static const floorChangeDistanceM = 60.0;
  static const selfDefaultFloor = '1F';
  static const tick = Duration(seconds: 1);
  static const joinDelay = Duration(seconds: 3);
  static const inviteText = '$kProdBaseUrl/r/demo（デモ用のリンク）';
  static const bannerText = 'デモ中：相手の「すず」さんは模擬の動きです（実際より速く歩きます）';
  static const shareAlertText = 'デモなので、招待リンクは送られません。\n実際に使うときは、ここから会う相手に1回だけ使える招待リンクを送ります。';
}

/// 模擬の API と WS。1つのデモ部屋だけを持つ。
class DemoBackend implements ApiClient {
  _DemoRoom? _room;

  bool isDemoRoom(String roomId) => roomId == DemoConfig.roomId;
  bool get hasRoom => _room != null;

  @override
  Future<CreateRoomResult> createRoom(String nickname) async {
    _room?.dispose();
    _room = _DemoRoom(nickname);
    return CreateRoomResult(roomId: DemoConfig.roomId, hostSecret: 'demo', inviteToken: 'demo');
  }

  @override
  Future<String> preview(String roomId, String invite) async => throw const ApiException('not_found', status: 404);

  @override
  Future<JoinResult> join(String roomId, String invite, String nickname) async =>
      throw const ApiException('not_found', status: 404);

  @override
  String inviteUrl(String roomId, String inviteToken) => DemoConfig.inviteText;

  @override
  Uri wsUri(String roomId, Role role, String secret) => Uri(scheme: 'demo', host: 'local', path: '/ws');

  Future<RoomSocket> connect(Uri uri) async {
    final room = _room;
    // デモ部屋はメモリにしか無い。無ければ「部屋が消えた」と同じ扱い。
    if (room == null) throw const WsHandshakeException(404, 'not_found');
    return room.attach();
  }

  void dispose() {
    _room?.dispose();
    _room = null;
  }
}

class _DemoRoom {
  _DemoRoom(this.hostNickname) : createdAt = DateTime.now().millisecondsSinceEpoch;

  final String hostNickname;
  final int createdAt;
  Phase phase = Phase.waitingGuest;
  String? selfFloor;
  String partnerFloor = DemoConfig.partnerStartFloor;
  GeoPoint? partner;
  int? partnerUpdatedAt;
  StoppedInfo? stopped;
  String? spotId;
  JudgeView judge = const JudgeView();
  final List<Timer> _timers = [];
  _DemoSocket? _socket;
  bool _joinScheduled = false;

  RoomSocket attach() {
    _socket?.closeWith(4001, 'duplicate_connection');
    final s = _DemoSocket(this);
    _socket = s;
    _timers.add(Timer(const Duration(milliseconds: 50), () {
      _emitState();
      if (phase == Phase.waitingGuest && !_joinScheduled) {
        _joinScheduled = true;
        _timers.add(Timer(DemoConfig.joinDelay, () {
          phase = Phase.waitingHostApproval;
          _emitState();
        }));
      }
    }));
    return s;
  }

  (int?, int?) _distanceAndBearing() {
    final p = partner;
    if (p == null) return (null, null);
    return (
      jsRound(distanceMeters(DemoConfig.selfLat, DemoConfig.selfLng, p.lat, p.lng)),
      jsRound(bearingDegrees(DemoConfig.selfLat, DemoConfig.selfLng, p.lat, p.lng)) % 360,
    );
  }

  Map<String, Object?> _publicState() {
    final active = phase == Phase.active;
    final (d, b) = active ? _distanceAndBearing() : (null, null);
    return {
      'type': 'state',
      'role': 'host',
      'phase': phase.wire,
      'roomId': DemoConfig.roomId,
      'expiresAt': createdAt + kRoomTtlMs,
      'self': {'nickname': hostNickname, 'approved': active || phase == Phase.stopped, 'floor': selfFloor, 'inArea': true},
      'other': phase == Phase.waitingGuest
          ? null
          : {
              'nickname': DemoConfig.partnerNickname,
              'approved': true,
              'connected': true,
              'inArea': active ? true : null,
              'floor': active ? partnerFloor : null,
              'lastUpdatedAt': active ? partnerUpdatedAt : null,
            },
      'distance_m': d,
      'bearing_deg': b,
      'floorDiffText': active && selfFloor != null ? floorDiffLabel(selfFloor, partnerFloor) : null,
      'meetSpot': active && spotId != null ? {'id': spotId, 'byMe': true} : null,
      'stopped': stopped == null ? null : {'by': stopped!.by?.name, 'at': stopped!.at},
      'judge': {
        'found': judge.found,
        'probability': judge.probability,
        'source': judge.source,
        'at': judge.at,
        'callsUsed': 0,
        'maxCalls': kMaxJudgeCalls,
        'limitReached': false,
      },
    };
  }

  void _emit(Map<String, Object?> m) => _socket?.push(jsonEncode(m));
  void _emitState() => _emit(_publicState());

  void _startWalking() {
    partner = destinationPoint(
        DemoConfig.selfLat, DemoConfig.selfLng, DemoConfig.partnerStartBearingDeg, DemoConfig.partnerStartDistanceM);
    partnerUpdatedAt = DateTime.now().millisecondsSinceEpoch;
    _emitState();
    _timers.add(Timer.periodic(DemoConfig.tick, (_) => _stepPartner()));
  }

  void _stepPartner() {
    final p = partner;
    if (phase != Phase.active || p == null) return;
    var d = distanceMeters(p.lat, p.lng, DemoConfig.selfLat, DemoConfig.selfLng);
    if (d > DemoConfig.arriveDistanceM) {
      final step = [DemoConfig.walkSpeedMps * DemoConfig.tick.inMilliseconds / 1000, d - DemoConfig.arriveDistanceM]
          .reduce((a, b) => a < b ? a : b);
      final toSelf = bearingDegrees(p.lat, p.lng, DemoConfig.selfLat, DemoConfig.selfLng);
      partner = destinationPoint(p.lat, p.lng, toSelf, step);
      d -= step;
    }
    if (d <= DemoConfig.floorChangeDistanceM) partnerFloor = DemoConfig.partnerArriveFloor;
    partnerUpdatedAt = DateTime.now().millisecondsSinceEpoch;
    _emitState();
  }

  void _handleJudge() {
    final (d, _) = _distanceAndBearing();
    String? reason;
    if (selfFloor == null) {
      reason = 'missing_floor';
    } else if (d == null) {
      reason = 'missing_location';
    } else if (d > kMeetDistanceM) {
      reason = 'too_far';
    } else if (selfFloor != partnerFloor) {
      reason = 'different_floor';
    }
    if (reason != null) {
      _emit({'type': 'judgeResult', 'ok': false, 'reason': reason, 'distance_m': d});
      return;
    }
    judge = JudgeView(found: true, source: 'distance_only', at: DateTime.now().millisecondsSinceEpoch);
    _emitState();
  }

  void handle(String text) {
    Object? msg;
    try {
      msg = jsonDecode(text);
    } catch (_) {
      return;
    }
    if (msg is! Map) return;
    switch (msg['type']) {
      case 'approve' when phase == Phase.waitingHostApproval:
        phase = Phase.active;
        _emitState();
        _startWalking();
      case 'floor' when msg['floor'] is String && isValidFloor(msg['floor'] as String):
        selfFloor = msg['floor'] as String;
        _emitState();
      case 'spot' when phase == Phase.active:
        final id = msg['spotId'];
        if (id == null || (id is String && kSpotIdPattern.hasMatch(id))) {
          spotId = id as String?;
          _emitState();
        } else {
          _emit({'type': 'error', 'code': 'invalid_spot'});
        }
      case 'judge' when phase == Phase.active:
        _handleJudge();
      case 'stop' when stopped == null:
        stopped = StoppedInfo(by: Role.host, at: DateTime.now().millisecondsSinceEpoch);
        phase = Phase.stopped;
        _emitState();
        _cancelTimers();
      // "location" は無視する（デモの自分の位置は固定点で、端末の外にも出さない）。
    }
  }

  void _cancelTimers() {
    for (final t in _timers) {
      t.cancel();
    }
    _timers.clear();
  }

  void dispose() {
    _cancelTimers();
    _socket?.closeWith(1000, 'demo_end');
    _socket = null;
  }
}

class _DemoSocket implements RoomSocket {
  _DemoSocket(this._room);
  final _DemoRoom _room;
  final _ctrl = StreamController<String>.broadcast();
  int? _code;
  String? _reason;

  void push(String text) {
    if (!_ctrl.isClosed) _ctrl.add(text);
  }

  void closeWith(int code, String reason) {
    if (_ctrl.isClosed) return;
    _code = code;
    _reason = reason;
    _ctrl.close();
  }

  @override
  Stream<String> get messages => _ctrl.stream;

  @override
  void send(String text) {
    if (!_ctrl.isClosed) _room.handle(text);
  }

  @override
  Future<void> close([int? code, String? reason]) async => closeWith(code ?? 1000, reason ?? '');

  @override
  int? get closeCode => _code;

  @override
  String? get closeReason => _reason;
}

/// デモの模擬サーバー（アプリ全体で1つ）。
final demoBackendProvider = Provider<DemoBackend>((ref) {
  final b = DemoBackend();
  ref.onDispose(b.dispose);
  return b;
});
