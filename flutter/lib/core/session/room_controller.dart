// 待ち合わせ部屋の司令塔。HTTP（作る・のぞく・参加）と WebSocket（承認・階・場所・判定・停止・位置）を束ね、
// プライバシーの約束をここ1か所で守る:
//   - phase == active の state を受けるまで location を送らない
//   - 渋谷駅から 1500m の外では送らない（端末の中で判定し、圏外表示だけ出す）
//   - 1.2秒に1回まで・2048バイトまで
//   - stop したら（WS が切れていても）直ちに位置の送信をやめ、つながったら stop を送り直す
// 機能側（features/*）は location を直接送れない。送るのはこのクラスだけ。
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/api_client.dart';
import '../constants.dart';
import '../demo/demo_mode.dart';
import '../geo.dart';
import '../models/room_models.dart';
import '../providers.dart';
import '../sensors/floor.dart';
import '../sensors/location.dart';
import '../ws/outbound_guard.dart';
import '../ws/room_connection.dart';
import 'ar_guide.dart';

const Object _unset = Object();

class RoomViewState {
  const RoomViewState({
    this.session,
    this.server,
    this.connection,
    this.disconnectedAt,
    this.lastJudgeFailure,
    this.judgeFailureSeq = 0,
    this.lastLocationRejected,
    this.lastErrorCode,
    this.errorSeq = 0,
    this.selfOutOfArea = false,
    this.stopRequested = false,
  });

  /// 今つないでいる部屋（無ければ部屋の外）。
  final RoomSession? session;

  /// 最後に受け取った公開状態。
  final RoomState? server;

  /// 接続の状態。null はまだ接続していない。
  final ConnectionStatus? connection;

  /// 接続が切れた時刻（通信切れバナー用）。つながっていれば null。
  final DateTime? disconnectedAt;

  /// 押した本人にだけ届く「会えた？」の失敗。seq が変わったら新しい失敗。
  final JudgeResultEvent? lastJudgeFailure;
  final int judgeFailureSeq;

  /// not_active / stopped / out_of_area
  final String? lastLocationRejected;

  /// 直近の error.code（どの操作への返事かは書かれていないので、直前の操作から推測する）。
  final String? lastErrorCode;
  final int errorSeq;

  /// 自分が渋谷エリアの外（端末の中で判定。このとき位置は送っていない）。
  final bool selfOutOfArea;

  /// stop を押した（サーバーの返事を待たずに位置の送信はもう止めている）。
  final bool stopRequested;

  Phase get phase => server?.phase ?? Phase.unknown;
  bool get isActive => phase == Phase.active;
  bool get wsConnected => connection is Connected;
  ConnectionEnd? get endedBy => switch (connection) { Ended(:final reason) => reason, _ => null };
  bool get isDemo => session?.isDemo ?? false;

  RoomViewState copyWith({
    Object? session = _unset,
    Object? server = _unset,
    Object? connection = _unset,
    Object? disconnectedAt = _unset,
    Object? lastJudgeFailure = _unset,
    int? judgeFailureSeq,
    Object? lastLocationRejected = _unset,
    Object? lastErrorCode = _unset,
    int? errorSeq,
    bool? selfOutOfArea,
    bool? stopRequested,
  }) =>
      RoomViewState(
        session: identical(session, _unset) ? this.session : session as RoomSession?,
        server: identical(server, _unset) ? this.server : server as RoomState?,
        connection: identical(connection, _unset) ? this.connection : connection as ConnectionStatus?,
        disconnectedAt: identical(disconnectedAt, _unset) ? this.disconnectedAt : disconnectedAt as DateTime?,
        lastJudgeFailure:
            identical(lastJudgeFailure, _unset) ? this.lastJudgeFailure : lastJudgeFailure as JudgeResultEvent?,
        judgeFailureSeq: judgeFailureSeq ?? this.judgeFailureSeq,
        lastLocationRejected:
            identical(lastLocationRejected, _unset) ? this.lastLocationRejected : lastLocationRejected as String?,
        lastErrorCode: identical(lastErrorCode, _unset) ? this.lastErrorCode : lastErrorCode as String?,
        errorSeq: errorSeq ?? this.errorSeq,
        selfOutOfArea: selfOutOfArea ?? this.selfOutOfArea,
        stopRequested: stopRequested ?? this.stopRequested,
      );
}

class RoomController extends Notifier<RoomViewState> {
  RoomConnection? _conn;
  ProviderSubscription<AsyncValue<PositionFix>>? _posSub;
  PositionFix? _lastFix;
  final OutboundGuard _guard = OutboundGuard();
  Timer? _pendingLocation;
  Timer? _heartbeat;
  int _lastLocationSentMs = 0;
  bool _demoFloorPreset = false;

  @override
  RoomViewState build() {
    ref.onDispose(_teardown);
    return const RoomViewState();
  }

  ApiClient get _api => ref.read(apiClientProvider);

  // ---------------- HTTP ----------------

  /// 部屋を作って host として接続する。ニックネームが不正なら ApiException('invalid_nickname')。
  Future<RoomSession> createRoom(String rawNickname) async {
    final nickname = sanitizeNickname(rawNickname);
    if (nickname == null) throw const ApiException('invalid_nickname');
    final api = _api;
    final r = await api.createRoom(nickname);
    final session = RoomSession(
      roomId: r.roomId,
      role: Role.host,
      secret: r.hostSecret,
      inviteUrl: api.inviteUrl(r.roomId, r.inviteToken),
      isDemo: ref.read(demoModeProvider),
    );
    await ref.read(activeSessionStoreProvider).save(session);
    _connect(session);
    return session;
  }

  /// デモを始める（ニックネームが空なら「あなた」）。
  Future<RoomSession> startDemo(String rawNickname) async {
    await leave();
    ref.read(demoModeProvider.notifier).start();
    return createRoom(sanitizeNickname(rawNickname) ?? 'あなた');
  }

  /// 参加前ののぞき見（副作用なし）。ホストのニックネームを返す。
  Future<String> preview(String roomId, String invite) => _api.preview(roomId, invite);

  /// 招待で参加する（＝guest の同意）。guest として接続する。
  Future<RoomSession> join(String roomId, String invite, String rawNickname) async {
    final nickname = sanitizeNickname(rawNickname);
    if (nickname == null) throw const ApiException('invalid_nickname');
    final r = await _api.join(roomId, invite, nickname);
    final session = RoomSession(roomId: roomId, role: Role.guest, secret: r.guestSecret);
    await ref.read(activeSessionStoreProvider).save(session);
    _connect(session);
    return session;
  }

  /// 保存済みのセッションがあれば接続し直す（招待プレビューを飛ばす）。無ければ false。
  Future<bool> resume(String roomId) async {
    final cur = state.session;
    if (cur != null && cur.roomId == roomId) return true;
    final saved = await ref.read(activeSessionStoreProvider).load(roomId);
    if (saved == null) return false;
    _connect(saved);
    return true;
  }

  /// 今のセッションのまま接続し直す（二重接続で閉じられたあとの「もう一度つなぐ」）。
  /// セッションが無い・デモ中なら false（デモは接続し直す相手がいない）。
  bool reconnect() {
    final s = state.session;
    if (s == null || s.isDemo) return false;
    _connect(s);
    return true;
  }

  // ---------------- WebSocket（ユーザー操作） ----------------

  /// host の承認（guest が送っても何も起きない）。
  bool approve() => _send({'type': 'approve'});

  /// 今いる階を送る。通常は ownFloorProvider.setByUser から呼ばれる。
  bool sendFloor(String label) {
    if (state.session == null) return false;
    return _send({'type': 'floor', 'floor': label});
  }

  /// 待ち合わせ場所（ID だけ。null で取り消し）。
  bool setSpot(String? spotId) {
    if (spotId != null && !kSpotIdPattern.hasMatch(spotId)) return false;
    return _send({'type': 'spot', 'spotId': spotId});
  }

  /// 「会えた？」
  bool judge() => _send({'type': 'judge'});

  /// 共有をやめる。送れなくても、この端末からの位置の送信はすぐ止め、つながったら送り直す。
  bool stop() {
    state = state.copyWith(stopRequested: true);
    _stopLocation();
    return _send({'type': 'stop'});
  }

  void clearJudgeFailure() => state = state.copyWith(lastJudgeFailure: null);

  /// 部屋を出る（接続を閉じ、保存したセッションを消す）。デモなら終える。
  Future<void> leave() async {
    final s = state.session;
    _teardown();
    if (s != null) await ref.read(activeSessionStoreProvider).clear(s.roomId);
    if (s?.isDemo ?? false) {
      ref.read(demoBackendProvider).dispose();
      ref.read(demoModeProvider.notifier).end();
    }
    ref.read(ownFloorProvider.notifier).clear();
    ref.read(arGuideProvider.notifier).clear();
    _demoFloorPreset = false;
    state = const RoomViewState();
  }

  // ---------------- 内部 ----------------

  void _connect(RoomSession session) {
    _teardown();
    _guard.reset();
    _demoFloorPreset = false;
    state = RoomViewState(session: session, connection: const Connecting(0));
    late final RoomConnection conn;
    conn = RoomConnection(
      uri: _api.wsUri(session.roomId, session.role, session.secret),
      connector: ref.read(roomSocketConnectorProvider),
      // 古い接続（閉じかけ）からの通知は無視する。
      onEvent: (e) {
        if (identical(_conn, conn)) _onEvent(e);
      },
      onStatus: (s) {
        if (identical(_conn, conn)) _onStatus(s);
      },
    );
    _conn = conn;
    conn.start();
    _startLocation();
  }

  bool _send(Map<String, Object?> msg) {
    final text = _guard.encode(msg);
    if (text == null) return false;
    return _conn?.send(text) ?? false;
  }

  void _onStatus(ConnectionStatus s) {
    if (!ref.mounted) return;
    final wasConnected = state.wsConnected;
    var next = state.copyWith(connection: s);
    if (s is Connected) {
      next = next.copyWith(disconnectedAt: null);
    } else if (wasConnected || (state.disconnectedAt == null && state.server != null)) {
      next = next.copyWith(disconnectedAt: state.disconnectedAt ?? DateTime.now());
    }
    if (s is Ended && s.reason == ConnectionEnd.expired) {
      next = next.copyWith(server: RoomState(phase: Phase.expired, roomId: state.session?.roomId));
      _onTerminal();
    } else if (s is Ended && s.reason == ConnectionEnd.unauthorized) {
      _onTerminal();
    }
    state = next;
    if (s is Connected && state.stopRequested) _send({'type': 'stop'});
  }

  void _onEvent(ServerEvent ev) {
    if (!ref.mounted) return;
    switch (ev) {
      case StateEvent(state: final s):
        _onState(s);
      case LocationRejectedEvent(:final reason):
        state = state.copyWith(lastLocationRejected: reason);
      case JudgeResultEvent():
        state = state.copyWith(lastJudgeFailure: ev, judgeFailureSeq: state.judgeFailureSeq + 1);
      case ErrorEvent(:final code):
        state = state.copyWith(lastErrorCode: code, errorSeq: state.errorSeq + 1);
        if (code == 'expired') {
          state = state.copyWith(server: RoomState(phase: Phase.expired, roomId: state.session?.roomId));
          _onTerminal();
        }
    }
  }

  void _onState(RoomState s) {
    final wasActive = state.isActive;
    state = state.copyWith(server: s, lastLocationRejected: s.isActive ? state.lastLocationRejected : null);
    ref.read(ownFloorProvider.notifier).syncFromServer(s.self?.floor);
    if (s.phase.isTerminal) {
      _onTerminal();
      return;
    }
    if (s.isActive) {
      if (!wasActive) _trySendLocation();
      _presetDemoFloor();
    } else {
      _pendingLocation?.cancel();
    }
  }

  /// デモだけ: 承認の 0.3 秒後に自分の階を 1F にする（demo.js の presetSelfFloor）。
  void _presetDemoFloor() {
    if (!state.isDemo || _demoFloorPreset) return;
    _demoFloorPreset = true;
    Timer(const Duration(milliseconds: 300), () {
      if (!ref.mounted || ref.read(ownFloorProvider) != null) return;
      ref.read(ownFloorProvider.notifier).setByUser(DemoConfig.selfDefaultFloor);
    });
  }

  void _onTerminal() {
    _conn?.markTerminal();
    _stopLocation();
    final s = state.session;
    if (s != null) unawaited(ref.read(activeSessionStoreProvider).clear(s.roomId));
  }

  // ---- 位置 ----

  void _startLocation() {
    _posSub?.close();
    _posSub = ref.listen<AsyncValue<PositionFix>>(positionProvider, (_, next) {
      final fix = next.value;
      if (fix != null) _onFix(fix);
    }, fireImmediately: true);
    _heartbeat?.cancel();
    _heartbeat = Timer.periodic(const Duration(milliseconds: kLocationHeartbeatMs ~/ 2), (_) {
      if (DateTime.now().millisecondsSinceEpoch - _lastLocationSentMs >= kLocationHeartbeatMs) _trySendLocation();
    });
  }

  void _stopLocation() {
    _posSub?.close();
    _posSub = null;
    _heartbeat?.cancel();
    _heartbeat = null;
    _pendingLocation?.cancel();
    _pendingLocation = null;
    _lastFix = null;
  }

  void _onFix(PositionFix fix) {
    _lastFix = fix;
    final out = !fix.inShibuya;
    if (out != state.selfOutOfArea) state = state.copyWith(selfOutOfArea: out);
    _trySendLocation();
  }

  void _trySendLocation() {
    final fix = _lastFix;
    if (fix == null || state.stopRequested || state.session == null) return;
    if (!state.isActive) return; // 相互承認の前は送らない
    if (!fix.inShibuya) return; // 渋谷エリアの外では送らない
    if (!(_conn?.isOpen ?? false)) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    final wait = _guard.locationWaitMs(now);
    if (wait > 0) {
      // 間引き: 最新の1点だけを、送ってよくなった時点で送る。
      _pendingLocation ??= Timer(Duration(milliseconds: wait), () {
        _pendingLocation = null;
        _trySendLocation();
      });
      return;
    }
    final sent = _send({
      'type': 'location',
      'lat': fix.lat,
      'lng': fix.lng,
      if (fix.accuracy != null) 'acc': fix.accuracy,
    });
    if (sent) {
      _guard.markLocationSent(now);
      _lastLocationSentMs = now;
    }
  }

  void _teardown() {
    _stopLocation();
    final c = _conn;
    _conn = null;
    if (c != null) unawaited(c.dispose());
  }
}

/// 待ち合わせ部屋（アプリ全体で1つ）。
final roomControllerProvider = NotifierProvider<RoomController, RoomViewState>(RoomController.new);

/// 相手の推定位置。相互承認後（active）で、自分の位置と distance/bearing が揃っているときだけ値がある。
/// 自分の GPS にサーバーの距離・方角を当てはめて端末の中だけで計算する（サーバーは相手の座標を送らない）。
/// 3D・AR・高画質・お店・道順（人モード）は全部これを使う。どこにも送らないこと。
final partnerEstimateProvider = Provider.autoDispose<GeoPoint?>((ref) {
  final s = ref.watch(roomControllerProvider.select((v) => v.server));
  if (s == null || !s.isActive || s.distanceM == null || s.bearingDeg == null) return null;
  final me = ref.watch(positionProvider).value;
  if (me == null) return null;
  return destinationPoint(me.lat, me.lng, s.bearingDeg!.toDouble(), s.distanceM!.toDouble());
});

/// 相手の位置が古い（2分より前）か。バナー用。
bool isPartnerStale(RoomState? s, {int? nowMs}) {
  final at = s?.other?.lastUpdatedAt;
  if (at == null) return false;
  return (nowMs ?? DateTime.now().millisecondsSinceEpoch) - at > kLocationStaleMs;
}
