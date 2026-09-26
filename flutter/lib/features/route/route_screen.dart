// 【route 担当】場所モード（/go）と、道順パネル（待ち合わせ画面の「道順で案内」にも埋め込む）。
// 公開インターフェース（クラス名・コンストラクタ・コールバックの型）は固定。仕様は flutter/SPEC.md §6.2。
// 経路エンジン（route.js の移植）は lib/features/route/engine/ に置く。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/core.dart';

/// `/go`: 1人で定番スポットへ行く。位置はサーバーに送らない。
class GoScreen extends ConsumerStatefulWidget {
  const GoScreen({super.key});

  @override
  ConsumerState<GoScreen> createState() => _GoScreenState();
}

class _GoScreenState extends ConsumerState<GoScreen> {
  @override
  Widget build(BuildContext context) {
    final places = ref.watch(placesProvider);
    return AppPage(children: [
      const AppBadge('仮画面（route 担当が作る）'),
      AppCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const Text('場所へ行く（1人で使えます）', style: AppText.label),
          const SizedBox(height: 8),
          places.when(
            data: (ps) => Text('スポット ${ps.length}件（例: ${ps.first.name}）', style: AppText.body),
            loading: () => const Text('場所の一覧を読み込んでいます…', style: AppText.hint),
            error: (_, _) => const Text('場所の一覧を読み込めませんでした。通信を確かめて開き直してください。', style: AppText.hint),
          ),
          const SizedBox(height: 12),
          SecondaryButton(label: '相手と待ち合わせる（招待リンクを作る）', onPressed: () => context.go('/new')),
        ]),
      ),
      const AttributionText(Attributions.places),
    ]);
  }
}

enum RoutePanelMode {
  /// 場所モード（/go）。空のときの文言は「行き先を選んでください」。
  place,

  /// 人モード（待ち合わせ画面）。空のときの文言は「相手の位置を待っています…」。
  person,
}

/// 道順の行き先。person モードの相手は partnerEstimateProvider の推定位置を渡す（name は相手のニックネーム）。
/// name が変わったら「別の目的地」として経路を作り直す。同じ name で動いた場合は 20m 以上か階が変わったら再計算。
class RouteTarget {
  const RouteTarget({required this.point, required this.name, this.level});
  final GeoPoint point;
  final String name;

  /// OSM の level（0=地上）。不明なら null。
  final num? level;
}

/// 道順パネル。自分の位置・向き・今いる階は core のプロバイダ（positionProvider・headingProvider・ownFloorProvider）から読む。
/// 階を変えたら ownFloorProvider.setByUser を呼ぶ（部屋が開いていればサーバーへ floor が送られる）。
class RoutePanel extends ConsumerStatefulWidget {
  const RoutePanel({super.key, required this.mode, required this.target, this.onRoute, this.onArrive});

  final RoutePanelMode mode;
  final RouteTarget? target;

  /// 経路を計算するたびに呼ぶ（null は経路なし）。3D 地図の線に使う。
  final ValueChanged<List<GeoPoint>?>? onRoute;

  /// 到着した瞬間に1回だけ呼ぶ（触覚は呼び出し側）。
  final VoidCallback? onArrive;

  @override
  ConsumerState<RoutePanel> createState() => _RoutePanelState();
}

class _RoutePanelState extends ConsumerState<RoutePanel> {
  @override
  Widget build(BuildContext context) => AppCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const AppBadge('道順で案内'),
          Text(widget.target?.name ?? (widget.mode == RoutePanelMode.person ? '相手の位置を待っています…' : '行き先を選んでください'),
              style: AppText.label),
          const SizedBox(height: 8),
          const Text('（仮）ここに矢印と案内文が入ります', style: AppText.hint),
          const SizedBox(height: 12),
          const FloorChips(),
        ]),
      );
}
