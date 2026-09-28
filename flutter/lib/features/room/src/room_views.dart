// meet 以外の部屋の画面（招待・参加プレビュー・承認・承認待ち・行き止まり・デモバナー）。
// 文言は html.js の screen-waiting-guest / preview / approve / waiting-approval-guest / stopped / full / expired / error。
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/core.dart';
import 'room_texts.dart';

/// 送れなかったとき（通信が切れている）の短い知らせ。
const kMsgNotSent = '通信が切れているため送れませんでした。つながってからもう一度押してください。';

/// その場に出すエラー文（赤・太字・読み上げ装置に届く）。
class InlineError extends StatelessWidget {
  const InlineError(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) => Semantics(
        liveRegion: true,
        child: Padding(
          padding: const EdgeInsets.only(top: 10),
          child: Text(text, style: const TextStyle(color: AppColors.offlineRed, fontSize: 14, fontWeight: FontWeight.w700)),
        ),
      );
}

/// 太字を混ぜた本文（「**{name}**さんから招待されました。」の形）。
class BoldLead extends StatelessWidget {
  const BoldLead({super.key, this.before = '', required this.bold, this.after = ''});
  final String before;
  final String bold;
  final String after;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Text.rich(
          TextSpan(style: AppText.body, children: [
            TextSpan(text: before),
            TextSpan(text: bold, style: const TextStyle(fontWeight: FontWeight.w800)),
            TextSpan(text: after),
          ]),
        ),
      );
}

// ---------------- デモバナー ----------------

/// デモ中の帯（app/src/app.css の .demo-banner）。右の「終了」でデモを終える。
class DemoBanner extends StatelessWidget {
  const DemoBanner({super.key, required this.onEnd});
  final VoidCallback onEnd;

  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.only(bottom: 14),
        padding: const EdgeInsets.fromLTRB(14, 10, 12, 10),
        decoration: BoxDecoration(color: AppColors.demoBanner, borderRadius: BorderRadius.circular(14)),
        child: Row(children: [
          const Expanded(
            child: Text(DemoConfig.bannerText,
                style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w700, height: 1.5)),
          ),
          const SizedBox(width: 10),
          TextButton(
            onPressed: onEnd,
            style: TextButton.styleFrom(
              backgroundColor: Colors.white,
              foregroundColor: AppColors.ink,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              minimumSize: const Size(44, 44),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w800),
            ),
            child: const Text('終了'),
          ),
        ]),
      );
}

/// デモでは招待リンクを外に出さない（demo.js の share と同じ文をダイアログで出す）。
Future<void> showDemoShareAlert(BuildContext context) => showAdaptiveDialog<void>(
      context: context,
      builder: (c) => AlertDialog.adaptive(
        content: const Text(DemoConfig.shareAlertText),
        actions: [adaptiveAction(context: c, onPressed: () => Navigator.of(c).pop(), child: const Text('OK'))],
      ),
    );

// ---------------- 招待（host・waiting_guest） ----------------

class InviteView extends StatelessWidget {
  const InviteView({super.key, required this.inviteUrl, required this.hostNickname, required this.isDemo});
  final String? inviteUrl;
  final String? hostNickname;
  final bool isDemo;

  Future<void> _line(BuildContext context) async {
    if (isDemo) return showDemoShareAlert(context);
    final url = inviteUrl;
    if (url == null) return;
    await Haptics.light();
    var opened = false;
    try {
      opened = await launchUrl(lineShareUri(url, hostNickname), mode: LaunchMode.externalApplication);
    } catch (_) {
      opened = false;
    }
    // LINE も Safari も開けない端末では、共有シートで代わりに送れるようにする。
    if (!opened && context.mounted) await _share(context);
  }

  Future<void> _share(BuildContext context) async {
    if (isDemo) return showDemoShareAlert(context);
    final url = inviteUrl;
    if (url == null) return;
    final box = context.findRenderObject() as RenderBox?;
    final origin = box != null && box.hasSize ? box.localToGlobal(Offset.zero) & box.size : null;
    try {
      await SharePlus.instance.share(ShareParams(
        title: '渋谷マチマチ',
        text: '${inviteMessage(hostNickname)}\n$url',
        sharePositionOrigin: origin,
      ));
    } catch (_) {
      if (context.mounted) await _copy(context);
    }
  }

  Future<void> _copy(BuildContext context) async {
    if (isDemo) return showDemoShareAlert(context);
    final url = inviteUrl;
    if (url == null) return;
    await Clipboard.setData(ClipboardData(text: url));
    await Haptics.light();
    if (context.mounted) showToast(context, 'コピーしました');
  }

  @override
  Widget build(BuildContext context) => AppCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const AppBadge('招待リンクを送ってください'),
          const FieldLabel('招待リンク(1回だけ使えます)'),
          TextFormField(
            key: ValueKey(inviteUrl),
            initialValue: inviteUrl ?? '',
            readOnly: true,
            style: const TextStyle(fontSize: 16, color: AppColors.readonlyText),
            decoration: const InputDecoration(fillColor: AppColors.readonlyFill),
          ),
          const HintText('このリンクは1回だけ使えます。公開の場には貼らないでください。'),
          const SizedBox(height: 14),
          FilledButton.icon(
            onPressed: () => _line(context),
            style: FilledButton.styleFrom(backgroundColor: AppColors.lineGreen, foregroundColor: Colors.white),
            icon: const Icon(Icons.chat_bubble, size: 20),
            label: const Text('LINEで送る'),
          ),
          const SizedBox(height: 10),
          Builder(
            builder: (c) => SecondaryButton(
              label: '共有する',
              icon: Icon(Icons.adaptive.share, size: 20),
              onPressed: () => _share(c),
            ),
          ),
          const SizedBox(height: 10),
          SecondaryButton(label: 'リンクをコピー', icon: const Icon(Icons.copy, size: 20), onPressed: () => _copy(context)),
          const HintText('相手がリンクを開いて参加するまでお待ちください。'),
        ]),
      );
}

// ---------------- 参加プレビュー（guest） ----------------

class PreviewView extends StatefulWidget {
  const PreviewView({
    super.key,
    required this.hostNickname,
    required this.onJoin,
    this.fieldError,
    this.error,
    this.busy = false,
  });
  final String hostNickname;
  final ValueChanged<String> onJoin;
  final String? fieldError;
  final String? error;
  final bool busy;

  @override
  State<PreviewView> createState() => _PreviewViewState();
}

class _PreviewViewState extends State<PreviewView> {
  final _nick = TextEditingController();

  @override
  void dispose() {
    _nick.dispose();
    super.dispose();
  }

  void _submit() {
    if (!widget.busy) widget.onJoin(_nick.text);
  }

  @override
  Widget build(BuildContext context) => AppCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          BoldLead(bold: widget.hostNickname, after: 'さんから招待されました。'),
          const FieldLabel('あなたのニックネーム'),
          TextField(
            controller: _nick,
            maxLength: kNicknameMaxLength,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _submit(),
            decoration: InputDecoration(hintText: '例: すず', counterText: '', errorText: widget.fieldError),
          ),
          const HintText('承認すると、相手の画面の3D地図にあなたのおおよその位置と近くのお店が表示されます。'),
          const SizedBox(height: 14),
          PrimaryButton(label: '承認して参加', onPressed: widget.busy ? null : _submit),
          if (widget.error != null) InlineError(widget.error!),
          const HintText('参加すると、位置情報の共有についてお互いが承認するまで位置は送られません。'),
        ]),
      );
}

// ---------------- 承認（host）・承認待ち（guest） ----------------

class ApproveView extends StatelessWidget {
  const ApproveView({super.key, required this.guestNickname, required this.onApprove});
  final String guestNickname;
  final VoidCallback onApprove;

  @override
  Widget build(BuildContext context) => AppCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          BoldLead(bold: guestNickname, after: 'さんが参加しました。'),
          const HintText('承認すると、相手の画面の3D地図にあなたのおおよその位置と近くのお店が表示されます。'),
          const SizedBox(height: 14),
          PrimaryButton(label: 'この人と位置を共有する', onPressed: onApprove),
          const HintText('押すまで、あなたの位置は相手に送られません。'),
        ]),
      );
}

class WaitingApprovalView extends StatelessWidget {
  const WaitingApprovalView({super.key, required this.hostNickname});
  final String hostNickname;

  @override
  Widget build(BuildContext context) => AppCard(
        child: Semantics(
          liveRegion: true,
          child: BoldLead(before: '参加しました。', bold: hostNickname, after: 'さんの承認をお待ちください。'),
        ),
      );
}

// ---------------- 行き止まり ----------------

/// 行き止まり＋任意の副ボタン（「もう一度つなぐ」「もう一度試す」）。
class RoomDeadEndView extends StatelessWidget {
  const RoomDeadEndView({super.key, required this.message, required this.onRestart, this.retryLabel, this.onRetry});
  final String message;
  final VoidCallback onRestart;
  final String? retryLabel;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        DeadEndCard(message: message, onRestart: onRestart),
        if (retryLabel != null && onRetry != null) SecondaryButton(label: retryLabel!, onPressed: onRetry),
      ]);
}

/// 接続を待っている間（state が来るまで）。再接続待ちなら一言添える。
class RoomLoadingView extends ConsumerWidget {
  const RoomLoadingView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final retrying = ref.watch(roomControllerProvider.select((v) => v.connection is WaitingRetry));
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const LoadingView(),
      if (retrying) const HintText('通信を確かめています。つながると自動で続きます。', textAlign: TextAlign.center),
    ]);
  }
}
