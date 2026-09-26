// 【room 担当】作成・招待・参加プレビュー・承認・待ち合わせ（meet）・行き止まりの画面。
// 公開インターフェース（クラス名・コンストラクタ）は固定。中身は差し替えてよい。仕様は flutter/SPEC.md §6.1。
// これは骨組み担当が置いた仮画面。配線の確認用に最小の動きだけ入れてある。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/core.dart';

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
    try {
      final s = await ref.read(roomControllerProvider.notifier).createRoom(_nick.text);
      if (mounted) context.go('/r/${s.roomId}');
    } on ApiException catch (e) {
      if (mounted) showToast(context, '（仮）作成に失敗しました(${e.reason})');
    }
  }

  Future<void> _demo() async {
    final s = await ref.read(roomControllerProvider.notifier).startDemo(_nick.text);
    if (mounted) context.go('/r/${s.roomId}');
  }

  @override
  Widget build(BuildContext context) => AppPage(children: [
        const AppBadge('仮画面（room 担当が作る）'),
        AppCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const FieldLabel('ニックネーム(相手に表示されます)'),
            TextField(controller: _nick, maxLength: kNicknameMaxLength, decoration: const InputDecoration(hintText: '例: りょうせい')),
            const SizedBox(height: 8),
            PrimaryButton(label: '待ち合わせを作る', onPressed: _create),
            const SizedBox(height: 12),
            SecondaryButton(label: 'デモで試す（1台で体験）', onPressed: _demo),
            const SizedBox(height: 12),
            SecondaryButton(label: '場所へ行く（道順で案内・1人で使えます）', onPressed: () => context.go('/go')),
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

class _RoomScreenState extends ConsumerState<RoomScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => ref.read(roomControllerProvider.notifier).resume(widget.roomId));
  }

  @override
  Widget build(BuildContext context) {
    final v = ref.watch(roomControllerProvider);
    final ctrl = ref.read(roomControllerProvider.notifier);
    return AppPage(children: [
      const AppBadge('仮画面（room 担当が作る）'),
      AppCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('phase: ${v.phase.wire.isEmpty ? '-' : v.phase.wire}／role: ${v.session?.role.name ?? '-'}', style: AppText.body),
          Text('接続: ${v.wsConnected ? 'つながっています' : 'つながっていません'}', style: AppText.hint),
          if (v.session?.inviteUrl != null) SelectableText(v.session!.inviteUrl!, style: AppText.hint),
          if (v.server?.distanceM != null) Text('${v.server!.distanceM} m', style: AppText.distance),
          const SizedBox(height: 12),
          if (v.phase == Phase.waitingHostApproval && v.session?.role == Role.host)
            PrimaryButton(label: 'この人と位置を共有する', onPressed: ctrl.approve),
          if (v.isActive) ...[
            const FloorChips(),
            const SizedBox(height: 12),
            SecondaryButton(label: 'ARで探す', onPressed: () => context.push('/ar')),
            const SizedBox(height: 8),
            SecondaryButton(label: '高画質で見る', onPressed: () => context.push('/hq')),
            const SizedBox(height: 8),
            SecondaryButton(label: '共有をやめる', onPressed: ctrl.stop),
          ],
          if (v.phase.isTerminal)
            DeadEndCard(
              message: v.phase == Phase.expired ? 'この待ち合わせは終了しました(3時間経過)。位置情報のデータは削除されています。' : '位置の共有は停止されました。',
              onRestart: () async {
                await ctrl.leave();
                if (context.mounted) context.go('/new');
              },
            ),
        ]),
      ),
    ]);
  }
}
