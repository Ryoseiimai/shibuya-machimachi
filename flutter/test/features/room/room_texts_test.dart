// room の文言と、状態から表示を決める純関数（app.js の文言・優先順と同じか）。
import 'package:flutter_test/flutter_test.dart';
import 'package:shibuya_machimachi/core/core.dart';
import 'package:shibuya_machimachi/features/room/src/room_texts.dart';

RoomViewState view({
  bool connected = true,
  DateTime? disconnectedAt,
  bool selfOut = false,
  bool? otherInArea,
  int? lastUpdatedAt,
  Phase phase = Phase.active,
}) =>
    RoomViewState(
      connection: connected ? const Connected() : const WaitingRetry(1, Duration(seconds: 1)),
      disconnectedAt: disconnectedAt,
      selfOutOfArea: selfOut,
      server: RoomState(
        phase: phase,
        other: OtherView(nickname: 'すず', inArea: otherInArea, lastUpdatedAt: lastUpdatedAt),
      ),
    );

void main() {
  const now = 1_800_000_000_000;

  group('状態バナー（優先順は 通信切れ > 自分が圏外 > 相手が圏外 > 古い）', () {
    test('何も無ければ null', () {
      expect(meetBanner(view(lastUpdatedAt: now - 1000), nowMs: now), isNull);
    });
    test('通信切れは最優先で、相手の最終更新の時刻を出し、距離を薄くする', () {
      final at = DateTime(2026, 9, 27, 9, 5).millisecondsSinceEpoch;
      final b = meetBanner(
        view(connected: false, disconnectedAt: DateTime(2026, 9, 27, 9, 7), selfOut: true, lastUpdatedAt: at),
        nowMs: now,
      )!;
      expect(b.kind, BannerKind.offline);
      expect(b.text, '通信が切れました。位置が更新されていません(最終更新 09:05)');
      expect(b.dimDistance, isTrue);
    });
    test('相手の時刻が無ければ切れた時刻', () {
      final b = meetBanner(view(connected: false, disconnectedAt: DateTime(2026, 9, 27, 21, 30)), nowMs: now)!;
      expect(b.text, endsWith('(最終更新 21:30)'));
    });
    test('つながっていないが一度もつながっていない（disconnectedAt なし）ならバナーは出さない', () {
      expect(meetBanner(view(connected: false), nowMs: now), isNull);
    });
    test('自分が圏外 > 相手が圏外 > 古い', () {
      final old = now - kLocationStaleMs - 1;
      expect(meetBanner(view(selfOut: true, otherInArea: false, lastUpdatedAt: old), nowMs: now)!.text,
          '渋谷エリアの外なので共有を止めています');
      expect(meetBanner(view(otherInArea: false, lastUpdatedAt: old), nowMs: now)!.text,
          '相手が渋谷エリアの外にいるため、距離を計算できません');
      final stale = meetBanner(view(lastUpdatedAt: old), nowMs: now)!;
      expect(stale.text, '相手の位置が古くなっています');
      expect(stale.dimDistance, isTrue);
      expect(meetBanner(view(lastUpdatedAt: now - kLocationStaleMs + 1), nowMs: now), isNull);
    });
    test('active でなければ（通信切れ以外）出さない', () {
      expect(meetBanner(view(selfOut: true, phase: Phase.waitingHostApproval), nowMs: now), isNull);
    });
  });

  group('会えた判定の文言', () {
    test('失敗の理由（8種）', () {
      String t(String r, {int? d, int? n}) =>
          judgeFailureText(JudgeResultEvent(reason: r, distanceM: d, remainingJevCalls: n));
      expect(t('too_far', d: 35), 'まだ20m以内に近づいていません(現在約35m)');
      expect(t('too_far'), 'まだ20m以内に近づいていません');
      expect(t('different_floor'), '階が違います。同じ階に来てから押してください');
      expect(t('missing_floor'), 'お互いに今いる階を選んでください');
      expect(t('missing_location'), '位置情報を取得中です。少し待ってからもう一度押してください');
      expect(t('not_active'), 'まだお互いの承認が完了していません');
      expect(t('judge_in_progress'), '判定中です。少し待ってからもう一度押してください');
      expect(t('not_found', n: 3), 'まだ判定できませんでした。相手の姿が見えたらもう一度押してください(残り3回)');
      expect(t('not_found'), 'まだ判定できませんでした。相手の姿が見えたらもう一度押してください');
      expect(t('weird'), 'まだ判定できません');
    });
    test('状態と出どころ', () {
      expect(judgeStatusText(null), '未確認');
      expect(judgeStatusText(const JudgeView()), '未確認');
      expect(judgeStatusText(const JudgeView(found: true, probability: 0.865)), '会えた! 87%');
      expect(judgeStatusText(const JudgeView(found: true)), '会えた!');
      expect(judgeSourceText(const JudgeView(found: true, source: 'jev')), 'Jev判定');
      expect(judgeSourceText(const JudgeView(found: true, source: 'distance_only')), '距離による判定');
    });
  });

  group('作成・参加・行き止まり', () {
    test('作成の失敗', () {
      expect(createErrorText(const ApiException('invalid_nickname')), 'ニックネームを入力してください');
      expect(createErrorText(const ApiException('rate_limited')), 'しばらく時間をおいてから、もう一度お試しください。');
      expect(createErrorText(const ApiException('rate_limited', message: '待って')), '待って');
      expect(createErrorText(const ApiException('network')), '通信エラーが発生しました');
      expect(createErrorText(const ApiException('x')), '作成に失敗しました(x)');
    });
    test('プレビューと参加の振り分け', () {
      expect(previewDeadEnd(const ApiException('full')), RoomDeadEnd.full);
      expect(previewDeadEnd(const ApiException('expired')), RoomDeadEnd.expired);
      expect(previewDeadEnd(const ApiException('not_found')), RoomDeadEnd.notFound);
      expect(previewDeadEnd(const ApiException('network')), RoomDeadEnd.network);
      expect(previewDeadEnd(const ApiException('invalid_invite')), RoomDeadEnd.invalidInvite);
      expect(previewDeadEnd(const ApiException('anything')), RoomDeadEnd.invalidInvite);
      expect(joinDeadEnd(const ApiException('full')), RoomDeadEnd.full);
      expect(joinDeadEnd(const ApiException('invalid_nickname')), isNull);
      expect(joinDeadEnd(const ApiException('network')), isNull);
      expect(joinErrorText(const ApiException('invalid_request')), '参加に失敗しました(invalid_request)');
    });
    test('停止の文（誰が止めたか）', () {
      expect(stoppedText(const RoomState(phase: Phase.stopped, role: Role.host, stopped: StoppedInfo(by: Role.host))),
          'あなたが共有をやめたため、位置の共有は停止しました。');
      expect(stoppedText(const RoomState(phase: Phase.stopped, role: Role.host, stopped: StoppedInfo(by: Role.guest))),
          '相手が共有をやめたため、位置の共有は停止しました。');
    });
  });

  test('LINE の URL は本文と招待 URL を改行でつないでエンコードする', () {
    final u = lineShareUri('https://x.example/r/abc?invite=def', 'りょう');
    expect(u.toString(), startsWith('https://line.me/R/msg/text/?'));
    expect(Uri.decodeComponent(u.toString().split('?').skip(1).join('?')),
        'りょうさんから渋谷マチマチの招待です\nhttps://x.example/r/abc?invite=def');
  });

  test('待ち合わせ場所の表示（読み込み中・一覧に無い ID・誰が決めたか）', () {
    const places = [Place(id: 'hachiko', name: 'ハチ公像', lat: 0, lng: 0)];
    expect(meetSpotText(null, null), 'まだ決めていません');
    expect(meetSpotText(const MeetSpotView(id: 'hachiko', byMe: true), null), '待ち合わせ場所を読み込んでいます…');
    expect(meetSpotText(const MeetSpotView(id: 'gone', byMe: true), places), 'まだ決めていません');
    expect(meetSpotText(const MeetSpotView(id: 'hachiko', byMe: false), places), '待ち合わせ場所：／ハチ公像／(相手が決めました)');
  });

  group('矢印', () {
    test('回転 = (bearing − heading + 360) % 360、heading が無ければ北が上', () {
      expect(arrowRotationDeg(90, null), 90);
      expect(arrowRotationDeg(10, 350), 20);
      expect(arrowRotationDeg(350, 10), 340);
      expect(arrowRotationDeg(0, 0), 0);
    });
    test('359°→1° は 2° だけ回す（逆回りしない）', () {
      expect(nextContinuousAngle(359, 1), 361);
      expect(nextContinuousAngle(361, 359), 359);
      expect(nextContinuousAngle(0, 180), 180);
      expect(nextContinuousAngle(720 + 10, 20), 730 + 10);
    });
    test('読み上げ', () {
      expect(directionSpeech(0, null), '相手は北の方向です');
      expect(directionSpeech(95, null), '相手は東の方向です');
      expect(directionSpeech(90, 90), '相手はあなたの前の方向です');
      expect(directionSpeech(180, 90), '相手はあなたの右の方向です');
      expect(directionSpeech(0, 90), '相手はあなたの左の方向です');
    });
  });

  test('時刻の表記', () {
    expect(formatClockHm(null), '--:--');
    expect(formatClockHm(DateTime(2026, 9, 27, 7, 3).millisecondsSinceEpoch), '07:03');
    expect(formatClockHms(DateTime(2026, 9, 27, 17, 3, 9).millisecondsSinceEpoch), '17:03:09');
  });
}
