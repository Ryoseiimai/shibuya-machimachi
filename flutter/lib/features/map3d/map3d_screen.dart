// 【map3d 担当】3D渋谷（MapLibre Native の fill-extrusion）と高画質3D（WebView + three.js）。
// 公開インターフェース（Map3dController のメソッド・Map3dView・HqViewerScreen）は固定。仕様は flutter/SPEC.md §6.3。
// 追加の公開部品: NearbyShopsList（近くのお店3件。meet の「近くのお店」カードにそのまま入れられる）。
//
// 正本: worker/public/assets/js/shibuya3d.mjs（軽量3D）・shibuya3d-hq.mjs（高画質3D）。
// 座標はこの端末の中で描くだけ。地図・WebView から座標を外へ送る処理は無い
// （軽量3Dが外へ取りに行くのは地理院タイルだけ、高画質3Dは PLATEAU の配信元だけ）。
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/core.dart';
import 'src/hq_web.dart';
import 'src/map_backend.dart';
import 'src/map_math.dart';
import 'src/map_style.dart';

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

// =====================================================================================
// 軽量3D
// =====================================================================================

/// 軽量の3D渋谷（カードの中に埋め込む。既定の高さ 280）。
/// 建物は高さで白〜淡いグレー（ヒカリエ・ストリームはオレンジ）、光・ピッチ60で回り込む演出（触るか
/// ピンが来たら止まる）、ランドマーク6件のラベル、自分/相手の柱（階の高さ）、2人を結ぶ点線、道順の線。
/// 出典は埋め込み先で `AttributionText(Attributions.all)` などを必ず出すこと（地図の中には出さない）。
class Map3dView extends StatefulWidget {
  const Map3dView({super.key, required this.controller, this.height = 280});
  final Map3dController controller;
  final double height;

  @override
  State<Map3dView> createState() => _Map3dViewState();
}

/// 建物の GeoJSON（約4MB）はアプリの中で1回だけ読み、文字列のまま持っておく（2回目からは待たない）。
/// 失敗したら覚えず、次に開いたとき読み直す。
String? _buildingsText;
Future<String> _loadBuildingsText() async => _buildingsText ??= await rootBundle.loadString(kAssetBuildings);

class _Map3dViewState extends State<Map3dView> with SingleTickerProviderStateMixin {
  String? _styleJson;
  bool _styleFailed = false;
  MapBackend? _map;

  // 地図へ反映済みの状態
  PlacedPin? _appliedMe;
  PlacedPin? _appliedPartner;
  List<GeoPoint>? _appliedRoute;
  bool _routeApplied = false;
  int _appliedFocus = 0;
  bool _applying = false;
  bool _applyAgain = false;

  // 最初の回り込み
  bool _intro = true;
  Timer? _introTimer;
  final Stopwatch _introClock = Stopwatch();
  double _introBearing = kInitialBearing;
  bool _bearingInFlight = false;

  // ラベルの画面位置
  List<Offset?> _landmarkPos = List.filled(kLandmarks.length, null);
  Offset? _mePos;
  Offset? _partnerPos;
  CameraState? _labelCam;
  bool _labelsBusy = false;
  bool _labelsAgain = false;

  Size _size = Size.zero;
  late final AnimationController _pulse = AnimationController(vsync: this, duration: const Duration(milliseconds: 1200))
    ..repeat(reverse: true);

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onController);
    // 最初からピンがある（作り直し等）なら回り込みはしない（Web 版の upsertPin と同じ）。
    if (widget.controller.me != null || widget.controller.partner != null) _intro = false;
    _loadStyle();
  }

  Future<void> _loadStyle() async {
    try {
      final text = _buildingsText ?? await _loadBuildingsText();
      if (!mounted) return;
      setState(() => _styleJson = buildStyleJson(text));
    } catch (_) {
      if (mounted) setState(() => _styleFailed = true);
    }
  }

  @override
  void didUpdateWidget(Map3dView old) {
    super.didUpdateWidget(old);
    if (!identical(old.controller, widget.controller)) {
      old.controller.removeListener(_onController);
      widget.controller.addListener(_onController);
      _appliedFocus = 0;
      _onController();
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onController);
    _stopIntro();
    _pulse.dispose();
    _map = null; // 地図（ネイティブ）は MapLibreMap の dispose で破棄される
    super.dispose();
  }

  // ---- 回り込み ----
  void _startIntro() {
    if (!_intro || _introTimer != null || _map == null) return;
    _introClock
      ..reset()
      ..start();
    _introTimer = Timer.periodic(const Duration(milliseconds: 50), (_) async {
      final map = _map;
      if (!_intro || map == null || _bearingInFlight) return;
      final dt = _introClock.elapsedMicroseconds / 1e6;
      _introClock
        ..reset()
        ..start();
      _introBearing = introBearing(_introBearing, math.min(dt, 0.2));
      _bearingInFlight = true;
      try {
        await map.setBearing(_introBearing);
      } catch (_) {
        // 地図が閉じる途中など。次の拍でやり直す。
      } finally {
        _bearingInFlight = false;
      }
    });
  }

  void _stopIntro() {
    _intro = false;
    _introTimer?.cancel();
    _introTimer = null;
    _introClock.stop();
  }

  // ---- 地図の準備ができた ----
  void _onReady(MapBackend map) {
    if (!mounted) return;
    _map = map;
    _startIntro();
    _onController();
    _scheduleLabels();
  }

  PlacedPin? _pin(PinRole role, MapPin? p) =>
      p == null || !p.point.isFinite ? null : PlacedPin(role: role, point: p.point, floor: p.floor, name: role == PinRole.me ? null : p.name);

  void _onController() {
    if (!mounted) return;
    // 埋め込み先が build や ref.listen の途中で setMe 等を呼んでも落ちないよう、組み立て中なら次の拍に回す。
    if (SchedulerBinding.instance.schedulerPhase == SchedulerPhase.persistentCallbacks) {
      if (_controllerPending) return;
      _controllerPending = true;
      SchedulerBinding.instance.addPostFrameCallback((_) {
        _controllerPending = false;
        _onController();
      });
      return;
    }
    setState(() {}); // ラベルの文字・色を先に変える
    unawaited(_apply());
  }

  bool _controllerPending = false;

  /// controller の状態を地図に反映する（重ならないよう1本ずつ。途中で変われば最後にもう一度）。
  Future<void> _apply() async {
    final map = _map;
    if (map == null) return;
    if (_applying) {
      _applyAgain = true;
      return;
    }
    _applying = true;
    try {
      do {
        _applyAgain = false;
        await _applyOnce(map);
      } while (_applyAgain && mounted && identical(_map, map));
    } catch (_) {
      // 地図が閉じる途中など。次の変化でやり直す。
    } finally {
      _applying = false;
    }
  }

  Future<void> _applyOnce(MapBackend map) async {
    final c = widget.controller;
    final me = _pin(PinRole.me, c.me);
    final partner = _pin(PinRole.partner, c.partner);

    if (me != _appliedMe || partner != _appliedPartner) {
      // 実データが来たら回り込みを止める（Web 版の upsertPin）。
      if ((me != null && me != _appliedMe) || (partner != null && partner != _appliedPartner)) _stopIntro();
      _appliedMe = me;
      _appliedPartner = partner;
      final s = pinSources(me, partner);
      await map.setGeoJson(MapIds.pinsSource, s.pins);
      await map.setGeoJson(MapIds.pinsGlowSource, s.glow);
      await map.setGeoJson(MapIds.pinsLineSource, s.line);
      _scheduleLabels();
    }

    final route = c.route;
    if (!_routeApplied || !identical(route, _appliedRoute)) {
      _routeApplied = true;
      _appliedRoute = route;
      await map.setGeoJson(MapIds.routeLineSource, routeSource(route));
      await map.setLayerVisibility(MapIds.pinsLineLayer, route == null);
      if (c.fitRoute && route != null) {
        final cam = routeFitCamera(route, size: _size, bearing: _currentBearing(map));
        if (cam != null) {
          _stopIntro();
          await map.animateTo(cam, duration: const Duration(milliseconds: 800));
        }
      }
    }

    if (c.focusRequest != _appliedFocus) {
      // 待っている間にピンが変わっていたら、新しいピンを描いてから寄せる（古い位置に寄せない）。
      if (_pin(PinRole.me, c.me) != me || _pin(PinRole.partner, c.partner) != partner) {
        _applyAgain = true;
        return;
      }
      _appliedFocus = c.focusRequest;
      _stopIntro();
      final pins = [?me, ?partner];
      final cam = focusCamera(
        [for (final p in pins) p.point],
        size: _size,
        labelTexts: [for (final p in pins) p.labelText],
        bearing: _currentBearing(map),
      );
      await map.animateTo(cam, duration: pins.length >= 2 ? const Duration(milliseconds: 800) : null);
    }
  }

  double _currentBearing(MapBackend map) => map.camera?.bearing ?? _introBearing;

  // ---- ラベルの位置 ----
  void _scheduleLabels() {
    if (_map == null) return;
    if (_labelsBusy) {
      _labelsAgain = true;
      return;
    }
    unawaited(_updateLabels());
  }

  Future<void> _updateLabels() async {
    _labelsBusy = true;
    try {
      do {
        _labelsAgain = false;
        final map = _map;
        if (map == null || !mounted) return;
        final cam = map.camera;
        final me = _appliedMe;
        final partner = _appliedPartner;
        final pts = [for (final l in kLandmarks) l.point, if (me != null) me.point, if (partner != null) partner.point];
        final screen = await map.toScreen(pts);
        if (!mounted || screen.length != pts.length) return;
        var i = kLandmarks.length;
        setState(() {
          _landmarkPos = screen.take(kLandmarks.length).toList();
          _mePos = me != null ? screen[i++] : null;
          _partnerPos = partner != null ? screen[i++] : null;
          _labelCam = cam;
        });
      } while (_labelsAgain);
    } catch (_) {
      // 地図が閉じる途中など。
    } finally {
      _labelsBusy = false;
    }
  }

  bool _onScreen(Offset p) => p.dx > -120 && p.dx < _size.width + 120 && p.dy > -60 && p.dy < _size.height + 200;

  List<Widget> _labelWidgets() {
    final cam = _labelCam;
    if (cam == null) return const [];
    final out = <Widget>[];
    for (var i = 0; i < kLandmarks.length; i++) {
      final pos = i < _landmarkPos.length ? _landmarkPos[i] : null;
      if (pos == null || !_onScreen(pos)) continue;
      final lm = kLandmarks[i];
      final lift = labelLiftPx(lm.heightM, lm.lat, cam);
      out.add(_anchored(pos.dx, pos.dy - lift, _LandmarkLabel(lm.name)));
    }
    final stack = labelStackLift(_mePos, _partnerPos);
    void addPin(PlacedPin? pin, Offset? pos, double extra) {
      if (pin == null || pos == null || !_onScreen(pos)) return;
      final lift = labelLiftPx(pin.look.heightM, pin.point.lat, cam) + extra;
      out.add(_anchored(pos.dx, pos.dy - lift, _PinLabel(text: pin.labelText, color: pin.color, pulse: _pulse)));
    }

    // 相手を先に描き、自分を最前面にする。
    addPin(_appliedPartner, _partnerPos, stack.partner);
    addPin(_appliedMe, _mePos, stack.me);
    return out;
  }

  static Widget _anchored(double x, double y, Widget child) => Positioned(
        left: x,
        top: y,
        child: FractionalTranslation(translation: const Offset(-0.5, -1), child: child),
      );

  String _semanticsValue() {
    final c = widget.controller;
    final parts = <String>[
      if (c.me != null) '自分 ${pinLook(c.me!.floor).label}',
      if (c.partner != null) '${c.partner!.name ?? '相手'} ${pinLook(c.partner!.floor).label}',
      if (c.route != null) '道順の線あり',
    ];
    return parts.join('、');
  }

  @override
  Widget build(BuildContext context) {
    final style = _styleJson;
    return Semantics(
      container: true,
      label: '3D渋谷の地図',
      value: _semanticsValue(),
      child: SizedBox(
        height: widget.height,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: ColoredBox(
            color: AppColors.mapBg,
            child: LayoutBuilder(builder: (context, constraints) {
              _size = constraints.biggest;
              return Stack(clipBehavior: Clip.hardEdge, children: [
                if (style != null)
                  Positioned.fill(
                    child: ExcludeSemantics(
                      child: Listener(
                        // 触ったら回り込みを止める（Web 版はユーザー操作の開始イベントで止める）。
                        onPointerDown: (_) => _stopIntro(),
                        child: map3dPlatformBuilder(
                          styleJson: style,
                          initialCamera: _intro ? kInitialCamera.copyWith(pitch: kIntroPitch) : kInitialCamera,
                          onReady: _onReady,
                          onCameraMove: _scheduleLabels,
                        ),
                      ),
                    ),
                  )
                else
                  Center(
                    child: Text(_styleFailed ? '3D地図を読み込めませんでした。' : '3D地図を読み込んでいます…', style: AppText.hint),
                  ),
                // 空（Native は sky 非対応なので、上端に薄い空色を重ねる）。
                const Positioned(
                  left: 0,
                  right: 0,
                  top: 0,
                  height: 36,
                  child: IgnorePointer(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [Color(0x8CBFE1F5), Color(0x00BFE1F5)],
                        ),
                      ),
                    ),
                  ),
                ),
                Positioned.fill(
                  child: IgnorePointer(
                    child: ExcludeSemantics(
                      child: MediaQuery.withClampedTextScaling(
                        maxScaleFactor: 1.3,
                        child: Stack(clipBehavior: Clip.hardEdge, children: _labelWidgets()),
                      ),
                    ),
                  ),
                ),
              ]);
            }),
          ),
        ),
      ),
    );
  }
}

/// ランドマークのラベル（人物ピンより控えめ）。
class _LandmarkLabel extends StatelessWidget {
  const _LandmarkLabel(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(
          color: const Color(0xE0FFFFFF),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: const Color(0x0F000000)),
          boxShadow: const [BoxShadow(color: Color(0x40000000), blurRadius: 3, offset: Offset(0, 1))],
        ),
        child: Text(
          text,
          maxLines: 1,
          softWrap: false,
          style: const TextStyle(fontSize: 10.5, fontWeight: FontWeight.w700, color: Color(0xFF4A4038), height: 1.3),
        ),
      );
}

/// 自分/相手のラベル（ピンの色の札・下向きの三角・先端の光）。足元（下端の中央）が柱の頂点に来る。
class _PinLabel extends StatelessWidget {
  const _PinLabel({required this.text, required this.color, required this.pulse});
  final String text;
  final Color color;
  final Animation<double> pulse;

  @override
  Widget build(BuildContext context) => Stack(clipBehavior: Clip.none, alignment: Alignment.bottomCenter, children: [
        Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            constraints: const BoxConstraints(maxWidth: 180),
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(7),
              boxShadow: [
                const BoxShadow(color: Color(0x73000000), blurRadius: 5, offset: Offset(0, 1)),
                BoxShadow(color: color.withValues(alpha: 0.55), blurRadius: 10, spreadRadius: 1),
              ],
            ),
            child: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis, softWrap: false, style: kPinLabelTextStyle),
          ),
          CustomPaint(size: const Size(10, 6), painter: _TailPainter(color)),
        ]),
        Positioned(
          bottom: -4,
          child: FadeTransition(
            opacity: Tween(begin: 0.6, end: 1.0).animate(pulse),
            child: ScaleTransition(
              scale: Tween(begin: 1.0, end: 1.3).animate(pulse),
              child: Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  color: color,
                  shape: BoxShape.circle,
                  boxShadow: [BoxShadow(color: color, blurRadius: 8, spreadRadius: 3)],
                ),
              ),
            ),
          ),
        ),
      ]);
}

class _TailPainter extends CustomPainter {
  const _TailPainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..moveTo(0, 0)
      ..lineTo(size.width, 0)
      ..lineTo(size.width / 2, size.height)
      ..close();
    canvas.drawShadow(path, color, 4, false);
    canvas.drawPath(path, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_TailPainter old) => old.color != color;
}

// =====================================================================================
// 近くのお店
// =====================================================================================

/// 近くのお店3件（shibuya3d.mjs の nearestShops と app.js の updateShopsList）。
/// center を省くと相手の推定位置（partnerEstimateProvider）のまわりを出す。どこにも送らない。
/// 相手の位置が無い・お店が無いときは「相手の位置と階が分かると表示されます。」、
/// お店のデータが読めないときは何も出さない（待ち合わせ本体は続けられるように）。
class NearbyShopsList extends ConsumerWidget {
  const NearbyShopsList({super.key, this.center});
  final GeoPoint? center;

  static const emptyText = '相手の位置と階が分かると表示されます。';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = center ?? ref.watch(partnerEstimateProvider);
    final pois = ref.watch(poisProvider);
    if (pois.hasError) return const SizedBox.shrink();
    if (c == null || !c.isFinite) return const HintText(emptyText);
    final list = pois.value;
    if (list == null) return const SizedBox.shrink();
    final shops = nearestShops(list, c.lat, c.lng);
    if (shops.isEmpty) return const HintText(emptyText);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      for (var i = 0; i < shops.length; i++) _ShopRow(shop: shops[i], last: i == shops.length - 1),
    ]);
  }
}

class _ShopRow extends StatelessWidget {
  const _ShopRow({required this.shop, required this.last});
  final NearbyShop shop;
  final bool last;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 2),
        decoration: BoxDecoration(border: last ? null : const Border(bottom: BorderSide(color: AppColors.divider))),
        child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
          Expanded(
            child: Text(shop.name, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: AppColors.ink)),
          ),
          const SizedBox(width: 8),
          Text('${shop.distanceM}m', style: AppText.small),
          if (shop.level != null && shop.level!.isNotEmpty) ...[
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
              decoration: BoxDecoration(color: AppColors.brandOrangeSoftBg, borderRadius: BorderRadius.circular(999)),
              // 意図的な簡略化: OSM の level は自由記法（"-1;0" 等）なので変換せずそのまま出す（Web 版と同じ）。
              child: Text('${shop.level}階', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: AppColors.brandOrangeOnSoft)),
            ),
          ],
        ]),
      );
}

// =====================================================================================
// 高画質3D
// =====================================================================================

/// WebView に渡すピン（値が変わったときだけ送る）。
class _HqPin {
  const _HqPin(this.lat, this.lng, this.floor, [this.name]);
  final double lat;
  final double lng;
  final int floor;
  final String? name;

  @override
  bool operator ==(Object other) => other is _HqPin && other.lat == lat && other.lng == lng && other.floor == floor && other.name == name;

  @override
  int get hashCode => Object.hash(lat, lng, floor, name);
}

const Color _hqBg = Color(0xFF0B1114);

/// `/hq`: 高画質3D（全画面）。自分の位置（positionProvider）・相手の推定位置（partnerEstimateProvider）・
/// 階（roomControllerProvider の self.floor / other.floor）をプロバイダから読む。閉じたら WebView ごと破棄する。
/// 省メモリ設定（駅から半径500m・テクスチャ 1024/512px・キャッシュ 220/150MB・ダウンロード4・展開2・
/// draco Worker 2）は同梱の assets/hq/shibuya3d-hq.js が必ず使う。
class HqViewerScreen extends ConsumerStatefulWidget {
  const HqViewerScreen({super.key});

  @override
  ConsumerState<HqViewerScreen> createState() => _HqViewerScreenState();
}

class _HqViewerScreenState extends ConsumerState<HqViewerScreen> {
  HqWebHost? _host;
  bool _ready = false;
  bool _loaded = false;
  int _pct = 0;
  String? _errorCode;
  bool _webAlive = true;
  bool _closing = false;
  bool _destroySent = false;

  _HqPin? _wantMe;
  _HqPin? _wantPartner;
  _HqPin? _sentMe;
  _HqPin? _sentPartner;

  void _onMessage(HqMessage m) {
    if (!mounted || _closing) return;
    switch (m) {
      case HqReady():
        setState(() => _ready = true);
        _push();
      case HqProgress(:final pct):
        if (pct != _pct) setState(() => _pct = pct);
      case HqLoaded():
        setState(() => _loaded = true);
      case HqError(:final code):
        _fail(code);
    }
  }

  void _fail(String code) {
    if (!mounted || _closing) return;
    setState(() {
      _errorCode ??= code;
      // 中身が落ちた・GPU を失ったときは WebView ごと外す（抱えたままにしない）。
      if (code == 'crashed' || code == 'context_lost') _webAlive = false;
    });
  }

  Future<void> _push() async {
    final host = _host;
    if (host == null || !_ready || !_webAlive || _closing) return;
    final me = _wantMe;
    final partner = _wantPartner;
    try {
      if (me != null && me != _sentMe) {
        _sentMe = me;
        await host.call('setMe', {'lat': me.lat, 'lng': me.lng, 'floor': me.floor});
      }
      if (partner != null && partner != _sentPartner) {
        _sentPartner = partner;
        await host.call('setPartner', {'lat': partner.lat, 'lng': partner.lng, 'floor': partner.floor, 'name': partner.name ?? '相手'});
      }
    } catch (_) {
      // WebView が閉じる途中など。
    }
  }

  Future<void> _destroyJs() async {
    if (_destroySent) return;
    _destroySent = true;
    final host = _host;
    if (host == null || !_webAlive) return;
    try {
      await host.call('destroy', const {}).timeout(const Duration(milliseconds: 800));
    } catch (_) {
      // 返事が無くても WebView ごと外すので、描画とメモリはそこで止まる。
    }
  }

  /// 閉じる: JS の destroy() → WebView を木から外す（ネイティブの WebView が破棄される）→ 前の画面へ。
  Future<void> _close() async {
    if (_closing) return;
    _closing = true;
    await _destroyJs();
    if (!mounted) return;
    setState(() => _webAlive = false);
    final nav = Navigator.of(context);
    if (nav.canPop()) {
      nav.pop();
    } else {
      GoRouter.maybeOf(context)?.go('/');
    }
  }

  @override
  Widget build(BuildContext context) {
    // 待ち合わせが終わったら（active でなくなったら）自分で閉じる。
    ref.listen<bool>(roomControllerProvider.select((v) => v.server?.isActive ?? false), (prev, next) {
      if (prev == true && !next) unawaited(_close());
    });

    final pos = ref.watch(positionProvider).value;
    final partner = ref.watch(partnerEstimateProvider);
    final server = ref.watch(roomControllerProvider.select((v) => v.server));
    final ownFloor = ref.watch(ownFloorProvider);
    _wantMe = pos == null ? null : _HqPin(pos.lat, pos.lng, floorLabelToInt(server?.self?.floor ?? ownFloor) ?? 1);
    _wantPartner = partner == null
        ? null
        : _HqPin(partner.lat, partner.lng, floorLabelToInt(server?.other?.floor) ?? 1, server?.other?.nickname);
    if (_ready) WidgetsBinding.instance.addPostFrameCallback((_) => _push());

    final error = _errorCode;
    return PopScope(
      // 戻るジェスチャーでも閉じられるようにする（そのときも destroy を送る）。
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) unawaited(_destroyJs());
      },
      child: Scaffold(
        backgroundColor: _hqBg,
        body: Stack(children: [
          if (_webAlive)
            Positioned.fill(
              child: Semantics(
                label: '高画質の3D渋谷',
                child: hqWebViewBuilder(
                  onCreated: (h) => _host = h,
                  onMessage: _onMessage,
                  onFailed: _fail,
                ),
              ),
            ),
          if (error == null && !_loaded) Positioned.fill(child: _HqProgressOverlay(pct: _pct)),
          if (error != null) Positioned.fill(child: _HqErrorOverlay(text: hqErrorText(error))),
          Positioned(
            right: 14,
            top: MediaQuery.paddingOf(context).top + 12,
            child: SizedBox(
              width: 44,
              height: 44,
              child: IconButton(
                tooltip: '閉じる',
                style: IconButton.styleFrom(backgroundColor: const Color(0x8C000000), foregroundColor: Colors.white),
                onPressed: _close,
                icon: const Icon(Icons.close, size: 20),
              ),
            ),
          ),
          Positioned(
            left: 12,
            right: 12,
            bottom: MediaQuery.paddingOf(context).bottom + 2,
            child: const IgnorePointer(
              child: AttributionText(Attributions.hq, color: Color(0xBFFFFFFF)),
            ),
          ),
        ]),
      ),
    );
  }
}

class _HqProgressOverlay extends StatelessWidget {
  const _HqProgressOverlay({required this.pct});
  final int pct;

  @override
  Widget build(BuildContext context) => IgnorePointer(
        child: ColoredBox(
          color: const Color(0xD114181C),
          child: Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                const Text('高画質モデルを読み込み中…', style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w700)),
                const SizedBox(height: 10),
                Semantics(
                  label: '読み込み',
                  value: '$pct%',
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(3),
                    child: SizedBox(
                      width: 220,
                      height: 6,
                      child: LinearProgressIndicator(
                        value: pct / 100,
                        backgroundColor: const Color(0x40FFFFFF),
                        color: AppColors.brandOrange,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                ExcludeSemantics(child: Text('$pct%', style: const TextStyle(color: Color(0xD9FFFFFF), fontSize: 12))),
                const SizedBox(height: 10),
                const SizedBox(
                  width: 240,
                  child: PhraseText(
                    'テクスチャ付きの／3D建物データ(数十MB)を／読み込みます。モバイル回線では／時間がかかることが／あるため、Wi-Fi推奨です。',
                    alignment: WrapAlignment.center,
                    style: TextStyle(color: Color(0xBFFFFFFF), fontSize: 11, height: 1.5),
                  ),
                ),
              ]),
            ),
          ),
        ),
      );
}

class _HqErrorOverlay extends StatelessWidget {
  const _HqErrorOverlay({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) => ColoredBox(
        color: _hqBg,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Semantics(
              liveRegion: true,
              child: PhraseText(
                text,
                alignment: WrapAlignment.center,
                style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w700, height: 1.6),
              ),
            ),
          ),
        ),
      );
}
