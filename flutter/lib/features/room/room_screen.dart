// 【room 担当】作成・招待・参加プレビュー・承認・待ち合わせ（meet）・行き止まりの画面。
// 公開インターフェース（クラス名・コンストラクタ）は固定。仕様は flutter/SPEC.md §6.1、文言は worker/src/html.js・
// worker/public/assets/js/app.js が正。内部の部品は src/ に分けてある（他の機能からは import しない）。
//
// プライバシー: この機能から位置は送らない（送るのは core の RoomController だけ）。位置の許可は
// 「待ち合わせを作る」「承認して参加」「この人と位置を共有する」のタップの中でだけ求める。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/core.dart';
import 'src/meet_view.dart';
import 'src/room_texts.dart';
import 'src/room_views.dart';

/// `/new`（`?demo=1` なら startDemo=true）: 作成画面。
class CreateRoomScreen extends ConsumerStatefulWidget {
  const CreateRoomScreen({super.key, this.startDemo = false});

  /// true なら開いた直後にデモを始める（ディープリンク shibuyamachimachi-flutter://demo）。
  final bool startDemo;

  @override
  ConsumerState<CreateRoomScreen> createState() => _CreateRoomScreenState();
}

class _CreateRoomScreenState extends ConsumerState<CreateRoomScreen> {
  final _nick = TextEditingController();
  bool _busy = false;
  String? _fieldError;
  String? _error;

  @override
  void initState() {
    super.initState();
    if (widget.startDemo) WidgetsBinding.instance.addPostFrameCallback((_) => _demo());
  }

  @override
  void dispose() {
    _nick.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    if (_busy) return;
    // 入力エラーは画面を移らず、その場で出す（Web 版はエラー画面へ飛んでいた）。
    if (sanitizeNickname(_nick.text) == null) {
      setState(() {
        _fieldError = kMsgNicknameRequired;
        _error = null;
      });
      return;
    }
    setState(() {
      _busy = true;
      _fieldError = null;
      _error = null;
    });
    final ctrl = ref.read(roomControllerProvider.notifier);
    try {
      // 前のデモが残っていたら終える（デモの模擬サーバーに本物の部屋を作らないように）。
      if (ref.read(demoModeProvider)) await ctrl.leave();
      // 位置の許可はこのタップの中で求める。拒否されても部屋は作れる（meet 画面で「設定を開く」を出す）。
      await _askLocation();
      final s = await ctrl.createRoom(_nick.text);
      unawaited(Haptics.light());
      if (mounted) context.go('/r/${s.roomId}');
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        if (e.reason == 'invalid_nickname') {
          _fieldError = createErrorText(e);
        } else {
          _error = createErrorText(e);
        }
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _askLocation() async {
    try {
      await ref.read(locationServiceProvider).ensurePermission();
    } catch (_) {
      // 許可の問い合わせ自体が失敗しても、作成・参加は続ける。
    }
  }

  Future<void> _demo() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _fieldError = null;
      _error = null;
    });
    try {
      final s = await ref.read(roomControllerProvider.notifier).startDemo(_nick.text);
      if (mounted) context.go('/r/${s.roomId}');
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = createErrorText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AppPage(children: [
        AppCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const FieldLabel('ニックネーム(相手に表示されます)'),
            TextField(
              controller: _nick,
              maxLength: kNicknameMaxLength,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _create(),
              onChanged: (_) {
                if (_fieldError != null) setState(() => _fieldError = null);
              },
              decoration: InputDecoration(hintText: '例: りょうせい', counterText: '', errorText: _fieldError),
            ),
            const SizedBox(height: 6),
            PrimaryButton(label: '待ち合わせを作る', onPressed: _busy ? null : _create),
            if (_error != null) InlineError(_error!),
            const HintText('作ると1回だけ使える招待リンクが出ます。相手に送って参加してもらいましょう。'),
            const HintText('アカウント登録は不要です。作った待ち合わせは3時間で自動的に終了します。'),
            const SizedBox(height: 14),
            SecondaryButton(label: 'デモで試す（1台で体験）', onPressed: _busy ? null : _demo),
            const HintText('デモでは、模擬の相手が渋谷駅前であなたに近づいてきます。位置情報は使わず、何も送信しません。'),
          ]),
        ),
        AppCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const Padding(
              padding: EdgeInsets.only(bottom: 10),
              child: PhraseText('1人で行きたい場所がありますか？', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
            ),
            SecondaryButton(label: '場所へ行く（道順で案内・1人で使えます）', onPressed: () => context.go('/go')),
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: PhraseText(
                'ハチ公像・モヤイ像などの定番スポットまで、歩ける道に沿った矢印で案内します。上の階や地下への移動も案内します。位置はサーバーに送りません。',
                style: AppText.hint,
              ),
            ),
          ]),
        ),
      ]);
}

/// `/r/:roomId?invite=`: 部屋の画面（招待プレビュー・承認・待ち合わせ・行き止まり）。
class RoomScreen extends ConsumerStatefulWidget {
  const RoomScreen({super.key, required this.roomId, this.invite});

  /// 32桁の16進（ルーターで検査済み）。
  final String roomId;

  /// 招待トークン（guest として初めて開くときだけある）。
  final String? invite;

  @override
  ConsumerState<RoomScreen> createState() => _RoomScreenState();
}

/// 部屋に入る前の段階（入ってからは RoomViewState の phase で出し分ける）。
enum _Entry { starting, preview, connected, deadEnd }

class _RoomScreenState extends ConsumerState<RoomScreen> {
  _Entry _entry = _Entry.starting;
  RoomDeadEnd? _deadEnd;
  String? _hostNickname;
  bool _busy = false;
  String? _joinFieldError;
  String? _joinError;

  RoomController get _ctrl => ref.read(roomControllerProvider.notifier);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _enter());
  }

  /// SPEC §6.1.2: 保存済みなら接続し直す → 招待が無ければ行き止まり → 招待をのぞく。
  Future<void> _enter() async {
    if (!mounted) return;
    setState(() {
      _entry = _Entry.starting;
      _deadEnd = null;
    });
    var resumed = false;
    try {
      resumed = await _ctrl.resume(widget.roomId);
    } catch (_) {
      resumed = false;
    }
    if (!mounted) return;
    if (resumed) {
      setState(() => _entry = _Entry.connected);
      return;
    }
    if (widget.roomId == DemoConfig.roomId) {
      // デモの部屋はメモリにしか無い。終わっていれば作成画面へ戻す。
      context.go('/new');
      return;
    }
    final invite = widget.invite;
    if (invite == null || invite.isEmpty) return _toDeadEnd(RoomDeadEnd.needInvite);
    try {
      final host = await _ctrl.preview(widget.roomId, invite);
      if (!mounted) return;
      setState(() {
        _hostNickname = host;
        _entry = _Entry.preview;
      });
    } on ApiException catch (e) {
      _toDeadEnd(previewDeadEnd(e));
    }
  }

  void _toDeadEnd(RoomDeadEnd d) {
    if (!mounted) return;
    setState(() {
      _entry = _Entry.deadEnd;
      _deadEnd = d;
    });
  }

  Future<void> _join(String raw) async {
    final invite = widget.invite;
    if (_busy || invite == null) return;
    if (sanitizeNickname(raw) == null) {
      setState(() {
        _joinFieldError = kMsgNicknameRequired;
        _joinError = null;
      });
      return;
    }
    setState(() {
      _busy = true;
      _joinFieldError = null;
      _joinError = null;
    });
    try {
      await _askLocation();
      await _ctrl.join(widget.roomId, invite, raw);
      unawaited(Haptics.light());
      if (!mounted) return;
      setState(() => _entry = _Entry.connected);
      // 招待トークンを URL から外す（戻る・開き直しで使用済みの招待を再送しない）。
      context.go('/r/${widget.roomId}');
    } on ApiException catch (e) {
      if (!mounted) return;
      final d = joinDeadEnd(e);
      if (d != null) return _toDeadEnd(d);
      setState(() {
        if (e.reason == 'invalid_nickname') {
          _joinFieldError = joinErrorText(e);
        } else {
          _joinError = joinErrorText(e);
        }
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _askLocation() async {
    try {
      await ref.read(locationServiceProvider).ensurePermission();
    } catch (_) {}
  }

  Future<void> _approve() async {
    await _askLocation();
    if (!mounted) return;
    unawaited(Haptics.light());
    if (!_ctrl.approve()) showToast(context, kMsgNotSent);
  }

  /// 部屋を出て作成画面へ（行き止まり・デモの「終了」）。
  Future<void> _restart({bool leave = true}) async {
    if (leave) await _ctrl.leave();
    if (mounted) context.go('/new');
  }

  /// 「もう一度つなぐ」（二重接続で閉じられたあと）。今のセッションのまま接続し直す。
  Future<void> _reconnect() async {
    if (!_ctrl.reconnect()) await _enter();
  }

  @override
  Widget build(BuildContext context) {
    final v = ref.watch(roomControllerProvider);
    final mine = v.session?.roomId == widget.roomId;
    final demo = mine && v.isDemo;
    return AppPage(
      top: demo ? DemoBanner(onEnd: _restart) : null,
      children: [_body(v, mine)],
    );
  }

  Widget _body(RoomViewState v, bool mine) {
    switch (_entry) {
      case _Entry.starting:
        return const LoadingView();
      case _Entry.deadEnd:
        final d = _deadEnd ?? RoomDeadEnd.invalidInvite;
        return RoomDeadEndView(
          message: deadEndText(d),
          // まだ部屋に入っていない（別の部屋に入っているかもしれない）ので leave しない。
          onRestart: () => _restart(leave: false),
          retryLabel: d == RoomDeadEnd.network ? 'もう一度試す' : null,
          onRetry: d == RoomDeadEnd.network ? _enter : null,
        );
      case _Entry.preview:
        return PreviewView(
          hostNickname: _hostNickname ?? '',
          onJoin: _join,
          fieldError: _joinFieldError,
          error: _joinError,
          busy: _busy,
        );
      case _Entry.connected:
        return _connected(v, mine);
    }
  }

  Widget _connected(RoomViewState v, bool mine) {
    if (!mine) return const RoomLoadingView();
    final s = v.server;
    final phase = v.phase;
    if (phase == Phase.expired) return RoomDeadEndView(message: kMsgExpired, onRestart: _restart);
    if (phase == Phase.stopped) return RoomDeadEndView(message: stoppedText(s), onRestart: _restart);
    switch (v.endedBy) {
      case ConnectionEnd.duplicate:
        return RoomDeadEndView(
          message: kMsgDuplicate,
          onRestart: _restart,
          retryLabel: 'もう一度つなぐ',
          onRetry: _reconnect,
        );
      case ConnectionEnd.unauthorized:
        return RoomDeadEndView(message: kMsgUnauthorized, onRestart: _restart);
      case ConnectionEnd.expired:
        return RoomDeadEndView(message: kMsgExpired, onRestart: _restart);
      default:
        break;
    }
    final isHost = (s?.role ?? v.session?.role) == Role.host;
    switch (phase) {
      case Phase.waitingGuest:
        return isHost
            ? InviteView(inviteUrl: v.session?.inviteUrl, hostNickname: s?.self?.nickname, isDemo: v.isDemo)
            : WaitingApprovalView(hostNickname: s?.other?.nickname ?? '相手');
      case Phase.waitingHostApproval:
        return isHost
            ? ApproveView(guestNickname: s?.other?.nickname ?? '相手', onApprove: _approve)
            : WaitingApprovalView(hostNickname: s?.other?.nickname ?? '相手');
      case Phase.active:
        return const MeetView();
      default:
        return const RoomLoadingView();
    }
  }
}
