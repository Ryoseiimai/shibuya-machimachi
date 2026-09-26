// 【route 担当】場所モード（/go）と、道順パネル（待ち合わせ画面の「道順で案内」にも埋め込む）。
// 公開インターフェース（クラス名・コンストラクタ・コールバックの型）は固定。仕様は flutter/SPEC.md §6.2。
// 経路エンジン（route.js の移植）は engine/、パネルの状態機械（route-panel.js の移植）は route_panel_logic.dart。
//
// 位置情報の扱い: 自分の位置・行き先・経路はこの端末の中だけで使う。このファイルから通信はしない
// （道のデータは同梱アセット）。部屋が開いているときに送られうるのは「今いる階」の画面ラベルだけで、
// それも ownFloorProvider（core）が決める。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart' show Geolocator;
import 'package:go_router/go_router.dart';
import 'package:permission_handler/permission_handler.dart' show openAppSettings;

import '../../core/core.dart';
import '../map3d/map3d_screen.dart';
import 'engine/graph_provider.dart';
import 'engine/route_engine.dart' show formatDistance;
import 'route_panel_logic.dart';

/// `/go`: 1人で定番スポットへ行く。位置はサーバーに送らない。
class GoScreen extends ConsumerStatefulWidget {
  const GoScreen({super.key});

  @override
  ConsumerState<GoScreen> createState() => _GoScreenState();
}

class _GoScreenState extends ConsumerState<GoScreen> {
  Place? _selected;
  LocationAccess? _access;

  /// 許可を求めて断られた（まだ聞いていない状態と区別する。geolocator は両方 denied を返すため）。
  bool _refused = false;
  PositionFix? _lastFix;
  String? _fittedPlaceId;
  final Map3dController _map = Map3dController();
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    unawaited(_recheckAccess());
    // 設定アプリで許可して戻ってきたら、すぐ位置を取り直す
    _lifecycle = AppLifecycleListener(onResume: () => unawaited(_recheckAccess()));
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    _map.dispose();
    super.dispose();
  }

  Future<void> _recheckAccess() async {
    final a = await ref.read(locationServiceProvider).currentAccess();
    if (!mounted) return;
    _setAccess(a);
  }

  void _setAccess(LocationAccess a) {
    final wasGranted = _access == LocationAccess.granted;
    setState(() {
      _access = a;
      if (a == LocationAccess.granted) _refused = false;
    });
    // 許可された直後は、エラーで止まっている位置の監視をすぐ作り直す（自動リトライを待たない）
    if (a == LocationAccess.granted && !wasGranted) ref.invalidate(positionProvider);
  }

  Future<void> _select(Place p) async {
    unawaited(Haptics.light());
    // 今いる階が未設定なら 1F（Web 版の既定と同じ）。選び直しでユーザーが直した階は保つ。
    if (ref.read(ownFloorProvider) == null) ref.read(ownFloorProvider.notifier).setByUser('1F');
    setState(() => _selected = p);
    _map
      ..setPartner(MapPin(point: p.point, floor: levelToAppFloorInt(p.level), name: p.name))
      ..setRoute(null);
    _updateMapMe();
    _map.focusBoth();
    // 位置の許可は、このタップの中で求める
    final a = await ref.read(locationServiceProvider).ensurePermission();
    if (!mounted) return;
    _setAccess(a);
    if (a != LocationAccess.granted) setState(() => _refused = true);
  }

  void _back() {
    setState(() => _selected = null);
    _map.setRoute(null);
  }

  void _updateMapMe() {
    final fix = _lastFix;
    if (fix == null) return;
    final floor = floorLabelToInt(ref.read(ownFloorProvider)) ?? 1;
    _map.setMe(MapPin(point: fix.point, floor: floor, name: '自分'));
  }

  // 行き先を選んだ直後の最初の道順だけ、3D渋谷を経路全体が入る位置に寄せる（以後は手動操作を尊重）
  void _onRoute(List<GeoPoint>? line) {
    final place = _selected;
    final fit = line != null && place != null && _fittedPlaceId != place.id;
    if (fit) _fittedPlaceId = place.id;
    _map.setRoute(line, fit: fit);
  }

  @override
  Widget build(BuildContext context) {
    final granted = _access == LocationAccess.granted;
    if (granted) {
      ref.listen(positionProvider, (_, next) {
        final fix = next.value;
        if (fix == null) return;
        _lastFix = fix;
        _updateMapMe();
      });
      ref.listen(ownFloorProvider, (_, _) => _updateMapMe());
    }
    final fix = granted ? ref.watch(positionProvider).value : null;
    final selected = _selected;
    return PopScope(
      canPop: selected == null,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _back();
      },
      child: selected == null ? _buildSelect(context, fix) : _buildRoute(selected),
    );
  }

  Widget _buildSelect(BuildContext context, PositionFix? fix) {
    final places = ref.watch(placesProvider);
    final offText = '位置情報がオフになっています。許可すると道順を案内できます。';
    final locationOff = _refused || _access == LocationAccess.deniedForever || _access == LocationAccess.serviceDisabled;
    final String? status = places.when(
      data: (_) => locationOff ? offText : null,
      loading: () => '場所の一覧を読み込んでいます…',
      error: (_, _) => '場所の一覧を読み込めませんでした。通信を確かめて開き直してください。',
    );
    return AppPage(
      key: const ValueKey('go-select'),
      children: [
        AppCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const AppBadge('場所へ行く（1人で使えます）'),
            const PhraseText('行きたい場所を選ぶと、歩ける道に沿った矢印で案内します。エスカレーターや階段での上の階・地下への移動も案内します。',
                style: AppText.body),
            const SizedBox(height: 12),
            if (places.value case final ps?)
              for (final p in ps)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: _PlaceItem(
                    place: p,
                    distance: fix == null ? null : '直線${formatDistance(distanceMeters(fix.lat, fix.lng, p.lat, p.lng))}',
                    onTap: () => unawaited(_select(p)),
                  ),
                ),
            if (status != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Semantics(liveRegion: true, child: PhraseText(status, style: AppText.hint)),
              ),
            if (status == offText) ...[
              const SizedBox(height: 8),
              SecondaryButton(
                label: '設定を開く',
                onPressed: () => unawaited(
                    _access == LocationAccess.serviceDisabled ? Geolocator.openLocationSettings() : openAppSettings()),
              ),
            ],
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: PhraseText('位置情報はこの端末の中だけで使い、サーバーには送りません。', style: AppText.hint),
            ),
          ]),
        ),
        AppCard(child: SecondaryButton(label: '相手と待ち合わせる（招待リンクを作る）', onPressed: () => context.go('/new'))),
        const AttributionText(Attributions.places),
      ],
    );
  }

  Widget _buildRoute(Place p) {
    return AppPage(
      key: const ValueKey('go-route'),
      children: [
        RoutePanel(
          mode: RoutePanelMode.place,
          target: RouteTarget(point: p.point, name: p.name, level: p.level),
          onRoute: _onRoute,
          onArrive: () => unawaited(Haptics.success()),
        ),
        AppCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const FieldLabel('3D渋谷（オレンジの線が道順）'),
            Map3dView(controller: _map),
          ]),
        ),
        AppCard(child: SecondaryButton(label: 'ほかの場所を選ぶ', onPressed: _back)),
        const AttributionText(Attributions.placeRoute),
      ],
    );
  }
}

class _PlaceItem extends StatelessWidget {
  const _PlaceItem({required this.place, required this.distance, required this.onTap});
  final Place place;
  final String? distance;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(14),
      side: const BorderSide(color: AppColors.inputBorder, width: 2),
    );
    return Semantics(
      button: true,
      label: [place.name, if (place.hint.isNotEmpty) place.hint, ?distance].join('、'),
      excludeSemantics: true,
      child: Material(
        color: AppColors.card,
        shape: shape,
        child: InkWell(
          customBorder: shape,
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 52),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              child: Row(children: [
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(place.name, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: AppColors.ink)),
                    if (place.hint.isNotEmpty)
                      PhraseText(place.hint,
                          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppColors.mutedText)),
                  ]),
                ),
                if (distance != null) ...[
                  const SizedBox(width: 10),
                  Text(distance!,
                      style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: AppColors.brandOrangeOnSoft)),
                ],
              ]),
            ),
          ),
        ),
      ),
    );
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

  @override
  bool operator ==(Object other) => other is RouteTarget && other.point == point && other.name == name && other.level == level;

  @override
  int get hashCode => Object.hash(point, name, level);

  @override
  String toString() => 'RouteTarget(<redacted>)';
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

const _placeNote = '位置情報は／この端末の中だけで使い、／サーバーには／送りません。';
const _personNote = '道順は／この端末の中で／計算します。／相手の位置は、／届いた距離と方角からの／推定です。';

class _RoutePanelState extends ConsumerState<RoutePanel> {
  late final RoutePanelLogic _logic;

  /// initState・didUpdateWidget の中では setState しない（どちらの後にも build が走る）。
  bool _canSetState = false;

  @override
  void initState() {
    super.initState();
    _logic = RoutePanelLogic(
      emptyText: widget.mode == RoutePanelMode.person ? '相手の位置を待っています…' : '行き先を選んでください',
      onLevelChange: (level) {
        final label = levelToValidFloorLabel(level);
        if (label != null) ref.read(ownFloorProvider.notifier).setByUser(label);
      },
      onRoute: (route) {
        final line = routeLine(route);
        _afterFrame(() => widget.onRoute?.call(line));
      },
      onArrive: () => _afterFrame(() => widget.onArrive?.call()),
      onChanged: () {
        if (_canSetState && mounted) setState(() {});
      },
    );
    _logic.setLevel(floorLabelToLevel(ref.read(ownFloorProvider)) ?? 0);
    ref.listenManual(ownFloorProvider, (_, next) => _logic.setLevel(floorLabelToLevel(next) ?? 0));
    ref.listenManual(positionProvider, (_, next) {
      final fix = next.value;
      if (fix != null) _logic.setSelf(fix.lat, fix.lng);
    }, fireImmediately: true);
    ref.listenManual(routeGraphProvider, (_, next) {
      switch (next) {
        case AsyncData(:final value):
          _logic.setGraph(value);
        case AsyncError():
          _logic.setLoadError();
        default:
          break;
      }
    }, fireImmediately: true);
    _logic.setTarget(_toPanelTarget(widget.target));
    _canSetState = true;
  }

  @override
  void didUpdateWidget(RoutePanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.target != widget.target) {
      _canSetState = false;
      _logic.setTarget(_toPanelTarget(widget.target));
      _canSetState = true;
    }
  }

  @override
  void dispose() {
    _logic.dispose();
    super.dispose();
  }

  static PanelTarget? _toPanelTarget(RouteTarget? t) =>
      t == null ? null : PanelTarget(lat: t.point.lat, lng: t.point.lng, level: t.level, name: t.name);

  // 呼び出し側の setState が build の最中に走らないよう、コールバックはフレームの後に回す
  void _afterFrame(VoidCallback fn) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) fn();
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  @override
  Widget build(BuildContext context) {
    final v = _logic.view();
    final Color instructionBg;
    final Color instructionFg;
    final EdgeInsets instructionPad;
    if (v.arrived) {
      (instructionBg, instructionFg, instructionPad) = (AppColors.brandOrange, Colors.white, const EdgeInsets.all(10));
    } else if (v.floorChange) {
      (instructionBg, instructionFg, instructionPad) =
          (AppColors.brandOrangeSoftBg, AppColors.brandOrangeOnSoft, const EdgeInsets.symmetric(horizontal: 10, vertical: 8));
    } else {
      (instructionBg, instructionFg, instructionPad) = (Colors.transparent, AppColors.ink, EdgeInsets.zero);
    }
    return AppCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.center, children: [
        const _CenterBadge('道順で案内'),
        if (v.destName.isNotEmpty)
          Text.rich(
            TextSpan(children: [
              TextSpan(text: v.destName, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: AppColors.ink)),
              if (v.destFloor.isNotEmpty)
                TextSpan(
                    text: v.destFloor,
                    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: AppColors.mutedText)),
            ]),
            textAlign: TextAlign.center,
          ),
        const SizedBox(height: 10),
        _RouteArrow(bearingDeg: v.bearingDeg),
        const SizedBox(height: 6),
        Semantics(
          liveRegion: true,
          container: true,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            width: double.infinity,
            padding: instructionPad,
            decoration: BoxDecoration(color: instructionBg, borderRadius: BorderRadius.circular(12)),
            child: PhraseText(
              v.instruction,
              style: AppText.routeInstruction.copyWith(color: instructionFg, height: 1.4),
              alignment: WrapAlignment.center,
            ),
          ),
        ),
        if (v.remaining.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(v.remaining,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: AppColors.mutedText)),
          ),
        if (v.confirmLabel case final label?)
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: SizedBox(
              width: double.infinity,
              child: PrimaryButton(
                label: label,
                onPressed: () {
                  unawaited(Haptics.light());
                  _logic.confirmFloor();
                },
              ),
            ),
          ),
        const SizedBox(height: 14),
        const Align(alignment: Alignment.centerLeft, child: FloorChips()),
        const SizedBox(height: 4),
        PhraseText(widget.mode == RoutePanelMode.person ? _personNote : _placeNote,
            style: AppText.hint, alignment: WrapAlignment.center),
      ]),
    );
  }
}

class _CenterBadge extends StatelessWidget {
  const _CenterBadge(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.only(bottom: 4),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(color: AppColors.brandOrangeSoftBg, borderRadius: BorderRadius.circular(999)),
        child: Text(text, style: AppText.badge),
      );
}

/// 次の経由点を指す矢印（円 150・矢印 72）。向きのセンサーが無いときは北が上。案内が無い/到着したら薄くする。
class _RouteArrow extends ConsumerStatefulWidget {
  const _RouteArrow({required this.bearingDeg});
  final double? bearingDeg;

  @override
  ConsumerState<_RouteArrow> createState() => _RouteArrowState();
}

class _RouteArrowState extends ConsumerState<_RouteArrow> {
  /// 回転（回数）。350°→10° を逆回りに1周させないよう、前回に一番近い同じ向きを選ぶ。
  double _turns = 0;

  @override
  Widget build(BuildContext context) {
    final heading = ref.watch(headingProvider).value;
    final bearing = widget.bearingDeg;
    if (bearing != null) {
      final rel = ((bearing - (heading ?? 0)) % 360 + 360) % 360;
      var t = rel / 360;
      t += (_turns - t).roundToDouble();
      _turns = t;
    }
    return ExcludeSemantics(
      child: AnimatedOpacity(
        opacity: bearing == null ? 0.3 : 1,
        duration: const Duration(milliseconds: 300),
        child: Container(
          width: 150,
          height: 150,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: const RadialGradient(colors: [Color(0x1FC8431F), Color(0x00C8431F)], stops: [0, 0.7]),
            border: Border.all(color: const Color(0x59C8431F), width: 2),
          ),
          alignment: Alignment.center,
          child: AnimatedRotation(
            turns: _turns,
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeOut,
            child: const CustomPaint(size: Size(72, 72), painter: _ArrowPainter()),
          ),
        ),
      ),
    );
  }
}

/// route-panel.js の ARROW_PATH "M12 2 L20 20 L12 15.5 L4 20 Z"（24×24）。
class _ArrowPainter extends CustomPainter {
  const _ArrowPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width / 24;
    final path = Path()
      ..moveTo(12 * s, 2 * s)
      ..lineTo(20 * s, 20 * s)
      ..lineTo(12 * s, 15.5 * s)
      ..lineTo(4 * s, 20 * s)
      ..close();
    canvas.drawPath(path, Paint()..color = AppColors.brandOrange);
  }

  @override
  bool shouldRepaint(covariant _ArrowPainter oldDelegate) => false;
}
