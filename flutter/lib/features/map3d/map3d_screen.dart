// 【map3d 担当】3D渋谷（MapLibre Native の fill-extrusion）と高画質3D（WebView + three.js）。
// 公開インターフェース（Map3dController のメソッド・Map3dView・HqViewerScreen）は固定。仕様は flutter/SPEC.md §6.3。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/core.dart';

/// 地図に立てるピン。floor は app の階整数（1F=1、B1=-1。0 は 1F 扱い）。
class MapPin {
  const MapPin({required this.point, required this.floor, this.name});
  final GeoPoint point;
  final int floor;

  /// 表示名。自分は「自分」、相手は name ?? 「相手」。
  final String? name;
}

/// 地図への指示を溜める箱（shibuya3d.mjs の mount() が返す API と同じ形）。
/// room・route はこれを作って Map3dView に渡し、setMe/setPartner/focusBoth/setRoute を呼ぶだけ。
class Map3dController extends ChangeNotifier {
  MapPin? _me;
  MapPin? _partner;
  List<GeoPoint>? _route;
  bool _fitRoute = false;
  int _focusRequest = 0;

  MapPin? get me => _me;
  MapPin? get partner => _partner;
  List<GeoPoint>? get route => _route;
  bool get fitRoute => _fitRoute;

  /// focusBoth() が呼ばれた回数。View は増えたら 2人が収まるように寄せる。
  int get focusRequest => _focusRequest;

  void setMe(MapPin? pin) {
    _me = pin;
    notifyListeners();
  }

  void setPartner(MapPin? pin) {
    _partner = pin;
    notifyListeners();
  }

  void focusBoth() {
    _focusRequest++;
    notifyListeners();
  }

  /// 2点以上で道順の線を出す（出している間は2人を結ぶ点線を隠す）。null で消す。fit なら経路全体に寄せる。
  void setRoute(List<GeoPoint>? coords, {bool fit = false}) {
    _route = coords == null || coords.length < 2 ? null : List.unmodifiable(coords);
    _fitRoute = fit;
    notifyListeners();
  }
}

/// 軽量の3D渋谷（カードの中に埋め込む。既定の高さ 280）。
class Map3dView extends StatefulWidget {
  const Map3dView({super.key, required this.controller, this.height = 280});
  final Map3dController controller;
  final double height;

  @override
  State<Map3dView> createState() => _Map3dViewState();
}

class _Map3dViewState extends State<Map3dView> {
  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: widget.controller,
        builder: (context, _) {
          final c = widget.controller;
          return Container(
            height: widget.height,
            decoration: BoxDecoration(color: AppColors.mapBg, borderRadius: BorderRadius.circular(14)),
            alignment: Alignment.center,
            child: Text(
              '（仮）3D渋谷\n自分: ${c.me == null ? 'なし' : formatFloor(c.me!.floor)}／相手: ${c.partner == null ? 'なし' : formatFloor(c.partner!.floor)}／道順: ${c.route == null ? 'なし' : '${c.route!.length}点'}',
              textAlign: TextAlign.center,
              style: AppText.hint,
            ),
          );
        },
      );
}

/// `/hq`: 高画質3D（全画面）。自分の位置（positionProvider）・相手の推定位置（partnerEstimateProvider）・
/// 階（roomControllerProvider の self.floor / other.floor）をプロバイダから読む。閉じたら WebView ごと破棄する。
class HqViewerScreen extends ConsumerStatefulWidget {
  const HqViewerScreen({super.key});

  @override
  ConsumerState<HqViewerScreen> createState() => _HqViewerScreenState();
}

class _HqViewerScreenState extends ConsumerState<HqViewerScreen> {
  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: const Color(0xFF0B1114),
        body: SafeArea(
          child: Stack(children: [
            const Center(child: Text('（仮）高画質3D（map3d 担当が作る）', style: TextStyle(color: Colors.white))),
            Positioned(
              right: 12,
              top: 12,
              child: IconButton.filled(
                tooltip: '閉じる',
                onPressed: () => Navigator.of(context).maybePop(),
                icon: const Icon(Icons.close),
              ),
            ),
            const Positioned(left: 12, right: 12, bottom: 8, child: AttributionText(Attributions.hq, color: Color(0xBFFFFFFF))),
          ]),
        ),
      );
}
