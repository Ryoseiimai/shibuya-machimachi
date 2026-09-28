// room 画面の文言と、状態から表示を決める純関数。文言は worker/src/html.js・worker/public/assets/js/app.js が正。
// 画面から切り離しておくと、テストで文言と優先順を直接確かめられる。
import '../../../core/core.dart';

// ---------------- 作成・参加 ----------------

const kMsgNicknameRequired = 'ニックネームを入力してください';
const kMsgNetwork = '通信エラーが発生しました';
const kMsgRateLimitedDefault = 'しばらく時間をおいてから、もう一度お試しください。';
const kMsgNeedInvite = 'このリンクだけでは参加できません。招待リンクを開いてください。';
const kMsgFull = 'この待ち合わせはすでに満員です。';
const kMsgNotFound = '待ち合わせが見つかりません。URLを確認してください。';
const kMsgInvalidInvite = 'この招待リンクは使えません。';
const kMsgExpired = 'この待ち合わせは終了しました(3時間経過)。位置情報のデータは削除されています。';
const kMsgDuplicate = '別の画面でこの待ち合わせが開かれたため、こちらの接続を閉じました。';

/// 秘密値が合わない（401）で接続できないとき。Web 版には無い（Web はエラー画面に出さず再接続を続けていた）。
const kMsgUnauthorized = 'この待ち合わせに接続できませんでした。招待リンクを開き直すか、新しく待ち合わせを作ってください。';

/// 「待ち合わせを作る」の失敗文（html.js / app.js の initCreateScreen）。
/// 本物の待ち合わせの途中で、デモ・別の待ち合わせを始めようとした（RoomController が止めた）。
const kMsgRoomActive = '今の待ち合わせが続いています。新しく始めるには、先に今の待ち合わせで「共有をやめる」を押してください。';

String createErrorText(ApiException e) => switch (e.reason) {
      'invalid_nickname' => kMsgNicknameRequired,
      'room_active' => kMsgRoomActive,
      'rate_limited' => e.message ?? kMsgRateLimitedDefault,
      'network' => kMsgNetwork,
      _ => '作成に失敗しました(${e.reason})',
    };

/// 「承認して参加」の失敗文（その場で出すもの）。満員・期限切れ・見つからない・招待不可は行き止まり画面へ回す。
String joinErrorText(ApiException e) => switch (e.reason) {
      'invalid_nickname' => kMsgNicknameRequired,
      'room_active' => kMsgRoomActive,
      'network' => kMsgNetwork,
      _ => '参加に失敗しました(${e.reason})',
    };

/// 招待プレビュー・参加の失敗のうち、画面ごと行き止まりにするもの。
enum RoomDeadEnd { full, expired, notFound, invalidInvite, needInvite, network }

/// preview の失敗を行き止まりの種類に（app.js の initRoomScreen と同じ振り分け）。
RoomDeadEnd previewDeadEnd(ApiException e) => switch (e.reason) {
      'full' => RoomDeadEnd.full,
      'expired' => RoomDeadEnd.expired,
      'not_found' => RoomDeadEnd.notFound,
      'network' => RoomDeadEnd.network,
      _ => RoomDeadEnd.invalidInvite,
    };

/// join の失敗のうち、行き止まりにするもの（それ以外は null ＝ その場で文を出す）。
RoomDeadEnd? joinDeadEnd(ApiException e) => switch (e.reason) {
      'full' => RoomDeadEnd.full,
      'expired' => RoomDeadEnd.expired,
      'not_found' => RoomDeadEnd.notFound,
      'invalid_invite' => RoomDeadEnd.invalidInvite,
      _ => null,
    };

String deadEndText(RoomDeadEnd d) => switch (d) {
      RoomDeadEnd.full => kMsgFull,
      RoomDeadEnd.expired => kMsgExpired,
      RoomDeadEnd.notFound => kMsgNotFound,
      RoomDeadEnd.invalidInvite => kMsgInvalidInvite,
      RoomDeadEnd.needInvite => kMsgNeedInvite,
      RoomDeadEnd.network => kMsgNetwork,
    };

/// 停止画面の文（stopped.by が自分の role なら「あなた」）。
String stoppedText(RoomState? s) {
  final by = s?.stopped?.by;
  final who = by != null && by == s?.role ? 'あなた' : '相手';
  return '$whoが共有をやめたため、位置の共有は停止しました。';
}

// ---------------- 招待 ----------------

/// 「{host}さんから渋谷マチマチの招待です」
String inviteMessage(String? hostNickname) => '${hostNickname ?? ''}さんから渋谷マチマチの招待です';

/// LINE の「送る」画面を開く URL（app.js の buildShareLinks と同じ形）。
Uri lineShareUri(String inviteUrl, String? hostNickname) =>
    Uri.parse('https://line.me/R/msg/text/?${Uri.encodeComponent('${inviteMessage(hostNickname)}\n$inviteUrl')}');

// ---------------- 時刻 ----------------

String _two(int n) => n.toString().padLeft(2, '0');

/// 「HH:MM」（端末の時刻）。null は「--:--」（app.js の formatClockTime）。
String formatClockHm(int? epochMs) {
  if (epochMs == null || epochMs <= 0) return '--:--';
  final t = DateTime.fromMillisecondsSinceEpoch(epochMs);
  return '${_two(t.hour)}:${_two(t.minute)}';
}

/// 「HH:MM:SS」（相手の最終更新）。
String formatClockHms(int epochMs) {
  final t = DateTime.fromMillisecondsSinceEpoch(epochMs);
  return '${_two(t.hour)}:${_two(t.minute)}:${_two(t.second)}';
}

// ---------------- meet の状態バナー ----------------

class MeetBanner {
  const MeetBanner(this.kind, this.text, {this.dimDistance = false});
  final BannerKind kind;
  final String text;

  /// 距離・矢印を薄く（opacity 0.4）して「今の値ではない」と伝えるか。
  final bool dimDistance;

  @override
  bool operator ==(Object other) =>
      other is MeetBanner && other.kind == kind && other.text == text && other.dimDistance == dimDistance;

  @override
  int get hashCode => Object.hash(kind, text, dimDistance);

  @override
  String toString() => 'MeetBanner($kind, $text, dim: $dimDistance)';
}

/// 状態バナーを1つだけ選ぶ（app.js の updateStatusBanner と同じ優先順）:
/// 通信切れ > 自分が圏外 > 相手が圏外 > 相手の位置が古い。無ければ null。
MeetBanner? meetBanner(RoomViewState v, {required int nowMs}) {
  final s = v.server;
  if (!v.wsConnected && v.disconnectedAt != null) {
    final at = s?.other?.lastUpdatedAt ?? v.disconnectedAt!.millisecondsSinceEpoch;
    return MeetBanner(BannerKind.offline, '通信が切れました。位置が更新されていません(最終更新 ${formatClockHm(at)})',
        dimDistance: true);
  }
  if (s == null || !s.isActive) return null;
  if (v.selfOutOfArea) return const MeetBanner(BannerKind.warn, '渋谷エリアの外なので共有を止めています');
  if (s.other?.inArea == false) return const MeetBanner(BannerKind.warn, '相手が渋谷エリアの外にいるため、距離を計算できません');
  if (isPartnerStale(s, nowMs: nowMs)) {
    return const MeetBanner(BannerKind.warn, '相手の位置が古くなっています', dimDistance: true);
  }
  return null;
}

/// 位置情報が使えないときの注意（Web 版は黙っていた所。ネイティブでは設定へ案内する）。
const kMsgLocationOff = '位置情報が許可されていないため、あなたの位置を相手に送れません。設定から位置情報を許可してください。';

// ---------------- 待ち合わせ場所 ----------------

/// 待ち合わせ場所の今の表示（PhraseText 用に ／ で区切る）。
/// places が null なら一覧の読み込み中。一覧に無い ID は「まだ決めていません」扱い（SPEC §6.1.4）。
String meetSpotText(MeetSpotView? spot, List<Place>? places) {
  if (spot == null) return 'まだ決めていません';
  if (places == null) return '待ち合わせ場所を読み込んでいます…';
  final place = findPlace(places, spot.id);
  if (place == null) return 'まだ決めていません';
  return '待ち合わせ場所：／${place.name}／${spot.byMe ? '(あなたが決めました)' : '(相手が決めました)'}';
}

// ---------------- 会えた判定 ----------------

/// 「会えた! 87%」か「未確認」。
String judgeStatusText(JudgeView? j) {
  if (j == null || !j.found) return '未確認';
  final p = j.probability;
  return p == null ? '会えた!' : '会えた! ${jsRound(p * 100)}%';
}

/// found のときの注記（Jev か距離か）。
String judgeSourceText(JudgeView j) => j.source == 'jev' ? 'Jev判定' : '距離による判定';

/// judgeResult（失敗）の注記（app.js の showJudgeNote）。
String judgeFailureText(JudgeResultEvent e) {
  switch (e.reason) {
    case 'not_found':
      final n = e.remainingJevCalls;
      return 'まだ判定できませんでした。相手の姿が見えたらもう一度押してください${n != null ? '(残り$n回)' : ''}';
    case 'too_far':
      final d = e.distanceM;
      return 'まだ${kMeetDistanceM}m以内に近づいていません${d != null ? '(現在約${d}m)' : ''}';
    case 'different_floor':
      return '階が違います。同じ階に来てから押してください';
    case 'missing_floor':
      return 'お互いに今いる階を選んでください';
    case 'missing_location':
      return '位置情報を取得中です。少し待ってからもう一度押してください';
    case 'not_active':
      return 'まだお互いの承認が完了していません';
    case 'judge_in_progress':
      return '判定中です。少し待ってからもう一度押してください';
    default:
      return 'まだ判定できません';
  }
}

// ---------------- 距離と矢印 ----------------

/// 矢印の回転（度・[0,360)）。heading が null なら北が上（heading=0 とみなす。app.js の初期値と同じ）。
double arrowRotationDeg(num bearingDeg, double? headingDeg) {
  final h = headingDeg ?? 0;
  return ((bearingDeg - h) % 360 + 360) % 360;
}

/// 前の角度から最短の向きに回すための、次の累積角度（359°→1° を 2° 回すだけにする）。
double nextContinuousAngle(double previousCumulative, double targetDeg) {
  final prev = ((previousCumulative % 360) + 360) % 360;
  var delta = targetDeg - prev;
  if (delta > 180) delta -= 360;
  if (delta < -180) delta += 360;
  return previousCumulative + delta;
}

/// 読み上げ用: 相手のいる向き（端末の向きが分かるときは前後左右、分からなければ方角）。
String directionSpeech(num bearingDeg, double? headingDeg) {
  if (headingDeg == null) {
    const names = ['北', '北東', '東', '南東', '南', '南西', '西', '北西'];
    final i = jsRound(((bearingDeg % 360) + 360) % 360 / 45) % 8;
    return '相手は${names[i]}の方向です';
  }
  const rel = ['前', '右前', '右', '右後ろ', '後ろ', '左後ろ', '左', '左前'];
  final i = jsRound(arrowRotationDeg(bearingDeg, headingDeg) / 45) % 8;
  return '相手はあなたの${rel[i]}の方向です';
}
