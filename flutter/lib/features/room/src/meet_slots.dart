// meet 画面に他の担当の部品を差し込む口（3D渋谷・道順パネル）。
// 既定は map3d / route の公開ウィジェットをそのまま呼ぶ（並行作業中は相手の仮画面が出る）。
// テストでは地図（プラットフォームビュー）や経路エンジンを起こさないよう、軽い部品に差し替える。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/core.dart';
import '../../map3d/map3d_screen.dart';
import '../../route/route_screen.dart';

typedef Map3dSlotBuilder = Widget Function(BuildContext context, Map3dController controller);
typedef RouteSlotBuilder = Widget Function(
  BuildContext context,
  RouteTarget? target,
  ValueChanged<List<GeoPoint>?> onRoute,
  VoidCallback onArrive,
);

class MeetSlots {
  const MeetSlots({this.map3d = defaultMap3d, this.routePanel = defaultRoutePanel});

  final Map3dSlotBuilder map3d;
  final RouteSlotBuilder routePanel;

  static Widget defaultMap3d(BuildContext context, Map3dController controller) =>
      Map3dView(controller: controller, height: 280);

  static Widget defaultRoutePanel(
    BuildContext context,
    RouteTarget? target,
    ValueChanged<List<GeoPoint>?> onRoute,
    VoidCallback onArrive,
  ) =>
      RoutePanel(mode: RoutePanelMode.person, target: target, onRoute: onRoute, onArrive: onArrive);
}

/// 差し替え口（テストで overrideWithValue する）。
final meetSlotsProvider = Provider<MeetSlots>((ref) => const MeetSlots());
