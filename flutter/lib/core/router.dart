// 画面遷移（go_router）。機能の画面はここからだけ辿れるようにする。パスを足す・変えるのは骨組み/統合担当。
import 'package:flutter/widgets.dart' show ValueKey;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../features/ar_home/ar_home_screen.dart';
import '../features/map3d/map3d_screen.dart';
import '../features/room/room_screen.dart';
import '../features/route/route_screen.dart';
import 'constants.dart';
import 'models/room_models.dart';
import 'widgets/common.dart';

abstract final class AppRoutes {
  static const home = '/';
  static const create = '/new';
  static const demo = '/new?demo=1';
  static const go = '/go';
  static const ar = '/ar';
  static const hq = '/hq';
  static String room(String roomId, {String? invite}) =>
      invite == null ? '/r/$roomId' : Uri(path: '/r/$roomId', queryParameters: {'invite': invite}).toString();
}

GoRouter buildRouter({String initialLocation = AppRoutes.home}) => GoRouter(
      initialLocation: initialLocation,
      errorBuilder: (_, _) => const NotFoundScreen(),
      routes: [
        GoRoute(path: '/', builder: (_, _) => const HomeScreen()),
        GoRoute(
          path: '/new',
          builder: (_, s) => CreateRoomScreen(key: ValueKey(s.uri.toString()), startDemo: s.uri.queryParameters['demo'] == '1'),
        ),
        GoRoute(path: '/demo', redirect: (_, _) => AppRoutes.demo),
        GoRoute(path: '/go', builder: (_, _) => const GoScreen()),
        GoRoute(
          path: '/r/:roomId',
          redirect: (_, s) => kHex32.hasMatch(s.pathParameters['roomId'] ?? '') ? null : '/not-found',
          builder: (_, s) => RoomScreen(
            key: ValueKey(s.pathParameters['roomId']),
            roomId: s.pathParameters['roomId']!,
            invite: s.uri.queryParameters['invite'],
          ),
        ),
        // AR と高画質は待ち合わせ画面の上に push で重ねる（閉じたら meet に戻る）。
        GoRoute(path: '/ar', builder: (_, _) => const ArScreen()),
        GoRoute(path: '/hq', builder: (_, _) => const HqViewerScreen()),
      ],
    );

/// 起動したときに開く場所。main.dart が、端末に保存した待ち合わせ（OS に終了させられた部屋）があれば
/// `/r/<id>` に差し替える（Web 版でタブを開き直すと部屋に戻るのと同じ）。
final initialLocationProvider = Provider<String>((ref) => AppRoutes.home);

/// 保存した待ち合わせから、起動時に開く場所を決める（無ければホーム）。
String initialLocationFor(RoomSession? saved) =>
    saved != null && kHex32.hasMatch(saved.roomId) ? AppRoutes.room(saved.roomId) : AppRoutes.home;

final routerProvider = Provider<GoRouter>((ref) {
  final r = buildRouter(initialLocation: ref.read(initialLocationProvider));
  ref.onDispose(r.dispose);
  return r;
});
