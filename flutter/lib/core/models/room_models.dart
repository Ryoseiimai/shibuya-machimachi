// サーバー契約（SPEC.md §3）どおりのモデル。受信側は全フィールドを nullable にして、
// alarm が送る最小形 {"type":"state","phase":"expired"} でも落ちないようにする。

enum Role {
  host,
  guest;

  static Role? parse(Object? v) => switch (v) {
        'host' => Role.host,
        'guest' => Role.guest,
        _ => null,
      };
}

enum Phase {
  waitingGuest('waiting_guest'),
  waitingHostApproval('waiting_host_approval'),
  active('active'),
  stopped('stopped'),
  expired('expired'),
  unknown('');

  const Phase(this.wire);
  final String wire;

  static Phase parse(Object? v) =>
      Phase.values.firstWhere((p) => p.wire == v && p != Phase.unknown, orElse: () => Phase.unknown);

  /// これ以上変わらない phase。再接続しない。
  bool get isTerminal => this == Phase.stopped || this == Phase.expired;
}

String? _str(Object? v) => v is String ? v : null;
bool? _bool(Object? v) => v is bool ? v : null;
int? _int(Object? v) => v is num && v.isFinite ? v.round() : null;
double? _dbl(Object? v) => v is num && v.isFinite ? v.toDouble() : null;
Map<String, Object?>? _map(Object? v) => v is Map ? v.cast<String, Object?>() : null;

class SelfView {
  const SelfView({this.nickname, this.approved, this.floor, this.inArea});
  final String? nickname;
  final bool? approved;
  final String? floor;
  final bool? inArea;

  static SelfView? fromJson(Object? json) {
    final m = _map(json);
    if (m == null) return null;
    return SelfView(
      nickname: _str(m['nickname']),
      approved: _bool(m['approved']),
      floor: _str(m['floor']),
      inArea: _bool(m['inArea']),
    );
  }
}

class OtherView {
  const OtherView({this.nickname, this.approved, this.connected, this.inArea, this.floor, this.lastUpdatedAt});
  final String? nickname;
  final bool? approved;
  final bool? connected;

  /// active のときだけ値が入る。
  final bool? inArea;
  final String? floor;

  /// 相手の位置を最後に更新したサーバー時刻（epoch ms）。
  final int? lastUpdatedAt;

  static OtherView? fromJson(Object? json) {
    final m = _map(json);
    if (m == null) return null;
    return OtherView(
      nickname: _str(m['nickname']),
      approved: _bool(m['approved']),
      connected: _bool(m['connected']),
      inArea: _bool(m['inArea']),
      floor: _str(m['floor']),
      lastUpdatedAt: _int(m['lastUpdatedAt']),
    );
  }
}

class MeetSpotView {
  const MeetSpotView({required this.id, required this.byMe});
  final String id;
  final bool byMe;

  static MeetSpotView? fromJson(Object? json) {
    final m = _map(json);
    final id = _str(m?['id']);
    if (m == null || id == null) return null;
    return MeetSpotView(id: id, byMe: _bool(m['byMe']) ?? false);
  }
}

class StoppedInfo {
  const StoppedInfo({this.by, this.at});
  final Role? by;
  final int? at;

  static StoppedInfo? fromJson(Object? json) {
    final m = _map(json);
    if (m == null) return null;
    return StoppedInfo(by: Role.parse(m['by']), at: _int(m['at']));
  }
}

class JudgeView {
  const JudgeView({
    this.found = false,
    this.probability,
    this.source,
    this.at,
    this.callsUsed = 0,
    this.maxCalls = 10,
    this.limitReached = false,
  });
  final bool found;
  final double? probability;

  /// "jev" | "distance_only" | null
  final String? source;
  final int? at;
  final int callsUsed;
  final int maxCalls;
  final bool limitReached;

  static JudgeView? fromJson(Object? json) {
    final m = _map(json);
    if (m == null) return null;
    return JudgeView(
      found: _bool(m['found']) ?? false,
      probability: _dbl(m['probability']),
      source: _str(m['source']),
      at: _int(m['at']),
      callsUsed: _int(m['callsUsed']) ?? 0,
      maxCalls: _int(m['maxCalls']) ?? 10,
      limitReached: _bool(m['limitReached']) ?? false,
    );
  }
}

/// 公開状態（buildPublicState）。lat/lng はどこにも無い。
class RoomState {
  const RoomState({
    required this.phase,
    this.role,
    this.roomId,
    this.expiresAt,
    this.self,
    this.other,
    this.distanceM,
    this.bearingDeg,
    this.floorDiffText,
    this.meetSpot,
    this.stopped,
    this.judge,
  });

  final Phase phase;
  final Role? role;
  final String? roomId;
  final int? expiresAt;
  final SelfView? self;
  final OtherView? other;
  final int? distanceM;
  final int? bearingDeg;
  final String? floorDiffText;
  final MeetSpotView? meetSpot;
  final StoppedInfo? stopped;
  final JudgeView? judge;

  bool get isActive => phase == Phase.active;

  static RoomState fromJson(Map<String, Object?> m) => RoomState(
        phase: Phase.parse(m['phase']),
        role: Role.parse(m['role']),
        roomId: _str(m['roomId']),
        expiresAt: _int(m['expiresAt']),
        self: SelfView.fromJson(m['self']),
        other: OtherView.fromJson(m['other']),
        distanceM: _int(m['distance_m']),
        bearingDeg: _int(m['bearing_deg']),
        floorDiffText: _str(m['floorDiffText']),
        meetSpot: MeetSpotView.fromJson(m['meetSpot']),
        stopped: StoppedInfo.fromJson(m['stopped']),
        judge: JudgeView.fromJson(m['judge']),
      );
}

/// サーバー → クライアントのメッセージ。
sealed class ServerEvent {
  const ServerEvent();

  /// 読めないもの・未知の type は null（サーバーと同じく黙って無視する）。
  static ServerEvent? fromJson(Object? json) {
    final m = _map(json);
    if (m == null) return null;
    switch (m['type']) {
      case 'state':
        return StateEvent(RoomState.fromJson(m));
      case 'locationRejected':
        return LocationRejectedEvent(_str(m['reason']) ?? '');
      case 'judgeResult':
        return JudgeResultEvent(
          reason: _str(m['reason']) ?? '',
          distanceM: _int(m['distance_m']),
          remainingJevCalls: _int(m['remainingJevCalls']),
        );
      case 'error':
        return ErrorEvent(_str(m['code']) ?? '');
      default:
        return null;
    }
  }
}

class StateEvent extends ServerEvent {
  const StateEvent(this.state);
  final RoomState state;
}

/// "not_active" | "stopped" | "out_of_area"
class LocationRejectedEvent extends ServerEvent {
  const LocationRejectedEvent(this.reason);
  final String reason;
}

/// 判定の失敗（ok:true は存在しない。成功は state.judge.found で知る）。
class JudgeResultEvent extends ServerEvent {
  const JudgeResultEvent({required this.reason, this.distanceM, this.remainingJevCalls});

  /// not_active / missing_location / missing_floor / different_floor / too_far / judge_in_progress / not_found
  final String reason;
  final int? distanceM;
  final int? remainingJevCalls;
}

/// unauthorized / expired / stopped / no_guest / invalid_floor / invalid_location / not_active / invalid_spot / internal_error
class ErrorEvent extends ServerEvent {
  const ErrorEvent(this.code);
  final String code;
}

// ---- HTTP の結果 ----

class CreateRoomResult {
  const CreateRoomResult({required this.roomId, required this.hostSecret, required this.inviteToken});
  final String roomId;
  final String hostSecret;
  final String inviteToken;
}

class JoinResult {
  const JoinResult({required this.guestSecret});
  final String guestSecret;
}

/// 端末に保存する接続情報（secure storage）。secret を含むのでログに出さない。
class RoomSession {
  const RoomSession({
    required this.roomId,
    required this.role,
    required this.secret,
    this.inviteUrl,
    this.isDemo = false,
    this.savedAtMs,
    this.stopPending = false,
  });
  final String roomId;
  final Role role;
  final String secret;

  /// host だけが持つ招待 URL（招待画面を開き直したとき用）。
  final String? inviteUrl;
  final bool isDemo;

  /// 端末に保存した時刻（作成・参加した時刻）。これから 3 時間（部屋の寿命）を過ぎた保存は消す。
  final int? savedAtMs;

  /// 「共有をやめる」を押したが、まだサーバーに届いたと確かめられていない。
  /// 開き直し・つなぎ直しのあとも位置は送らず、stop だけを送る（終端の state が来たら保存ごと消す）。
  final bool stopPending;

  RoomSession copyWith({bool? stopPending, int? savedAtMs}) => RoomSession(
        roomId: roomId,
        role: role,
        secret: secret,
        inviteUrl: inviteUrl,
        isDemo: isDemo,
        savedAtMs: savedAtMs ?? this.savedAtMs,
        stopPending: stopPending ?? this.stopPending,
      );

  Map<String, Object?> toJson() => {
        'roomId': roomId,
        'role': role.name,
        'secret': secret,
        'inviteUrl': inviteUrl,
        'savedAt': savedAtMs,
        if (stopPending) 'stopPending': true,
      };

  static RoomSession? fromJson(Object? json) {
    final m = _map(json);
    final role = Role.parse(m?['role']);
    final roomId = _str(m?['roomId']);
    final secret = _str(m?['secret']);
    if (role == null || roomId == null || secret == null) return null;
    return RoomSession(
      roomId: roomId,
      role: role,
      secret: secret,
      inviteUrl: _str(m?['inviteUrl']),
      savedAtMs: _int(m?['savedAt']),
      stopPending: _bool(m?['stopPending']) ?? false,
    );
  }

  @override
  String toString() => 'RoomSession(role: ${role.name}, <redacted>)';
}

/// 制御文字を除いて trim。1〜20文字（UTF-16）なら値、それ以外は null（サーバーの検証と同じ）。
String? sanitizeNickname(String raw) {
  final cleaned = raw.replaceAll(RegExp(r'[\u0000-\u001F\u007F-\u009F]'), '').trim();
  if (cleaned.isEmpty || cleaned.length > 20) return null;
  return cleaned;
}
