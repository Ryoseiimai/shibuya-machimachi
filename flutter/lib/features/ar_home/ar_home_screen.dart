// 【ar_home 担当】ホーム（`/`・アプリの入口と「このアプリについて」）と AR（`/ar`・カメラ越しに相手の方向）。
// 公開インターフェース（クラス名・コンストラクタ）は固定。仕様は flutter/SPEC.md §6.4。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/core.dart';

/// `/`: アプリの入口。LP の要点（できること・安心の設計・出典）と、作る/場所へ行く/デモの入口。
class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) => AppPage(children: [
        const AppBadge('仮画面（ar_home 担当が作る）'),
        AppCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const PhraseText('お互いに承認した2人だけで、／渋谷で迷わず会える', style: AppText.body),
            const SizedBox(height: 16),
            PrimaryButton(label: '待ち合わせを作る', onPressed: () => context.go('/new')),
            const SizedBox(height: 8),
            SecondaryButton(label: '場所へ行く（道順で案内）', onPressed: () => context.go('/go')),
            const SizedBox(height: 8),
            SecondaryButton(label: 'デモで試す（1台で体験）', onPressed: () => context.go('/new?demo=1')),
          ]),
        ),
        const AttributionText(Attributions.all),
      ]);
}

/// `/ar`: AR（全画面・黒地）。相手の推定位置（partnerEstimateProvider）・自分の位置・向き（headingProvider）・
/// 傾き（tiltProvider）・相手の名前と階（roomControllerProvider）をプロバイダから読む。
/// active でなくなったら自分で閉じる。カメラ映像は画面に出すだけ（送信・保存・画像ストリーム・録音なし）。
class ArScreen extends ConsumerStatefulWidget {
  const ArScreen({super.key});

  @override
  ConsumerState<ArScreen> createState() => _ArScreenState();
}

class _ArScreenState extends ConsumerState<ArScreen> {
  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: Colors.black,
        body: SafeArea(
          child: Stack(children: [
            const Center(child: Text('（仮）AR（ar_home 担当が作る）', style: TextStyle(color: Colors.white))),
            Positioned(
              right: 12,
              top: 12,
              child: IconButton.filled(
                tooltip: '閉じる',
                onPressed: () => Navigator.of(context).maybePop(),
                icon: const Icon(Icons.close),
              ),
            ),
          ]),
        ),
      );
}
