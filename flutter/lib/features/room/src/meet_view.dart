// 待ち合わせ画面（phase == active）。html.js の screen-meet と app.js の renderMeet / updateStatusBanner /
// renderMeetSpot / showJudgeNote / setMeetRoute / refreshExtras を1つにまとめたもの。SPEC §6.1.4〜6.1.5。
//
// プライバシー: 位置を送るのは core の RoomController だけ。この画面が送るのは approve 後の
// spot（ID だけ）・judge・stop・floor（ownFloorProvider 経由）のみ。相手の位置は partnerEstimateProvider
// （自分の GPS＋サーバーの距離・方角から端末の中で計算）を画面に出すだけで、どこにも送らない・ログに出さない。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:permission_handler/permission_handler.dart' show openAppSettings;

import '../../../core/core.dart';
import '../../map3d/map3d_screen.dart';
import '../../route/route_screen.dart';
import 'direction_arrow.dart';
import 'meet_slots.dart';
import 'room_texts.dart';
import 'room_views.dart' show kMsgNotSent;

/// 状態バナーを見直す間隔（app.js の STATUS_BANNER_POLL_MS）。
const Duration kStatusBannerPoll = Duration(seconds: 5);

class MeetView extends ConsumerStatefulWidget {
  const MeetView({super.key});

  @override
  ConsumerState<MeetView> createState() => _MeetViewState();
}

class _MeetViewState extends ConsumerState<MeetView> {
  /// 3D は active になってから作る（この画面ができたとき＝active）。
  final Map3dController _map = Map3dController();
  Timer? _poll;
  int _nowMs = DateTime.now().millisecondsSinceEpoch;

  bool _routeOn = false;
  bool _routeToSpot = false;
  bool _routeFitted = false;
  bool _focused = false;
  bool _foundNotified = false;
  String? _judgeNote;
  String? _spotChoice;

  final List<ProviderSubscription<Object?>> _subs = [];

  RoomController get _ctrl => ref.read(roomControllerProvider.notifier);

  @override
  void initState() {
    super.initState();
    // 通信が止まっていても「最終更新」「古い位置」の表示を進めるための定期見直し。
    _poll = Timer.periodic(kStatusBannerPoll, (_) {
      if (mounted) setState(() => _nowMs = DateTime.now().millisecondsSinceEpoch);
    });
    _subs
      ..add(ref.listenManual(positionProvider, (_, _) => _updateMe(), fireImmediately: true))
      ..add(ref.listenManual(ownFloorProvider, (_, _) => _updateMe()))
      ..add(ref.listenManual(partnerEstimateProvider, (_, _) => _updatePartner(), fireImmediately: true))
      ..add(ref.listenManual(roomControllerProvider.select((v) => (v.server?.other?.floor, v.server?.other?.nickname)),
          (_, _) => _updatePartner()))
      ..add(ref.listenManual<int>(roomControllerProvider.select((v) => v.judgeFailureSeq), (prev, next) {
        final e = ref.read(roomControllerProvider).lastJudgeFailure;
        if (prev != next && e != null) setState(() => _judgeNote = judgeFailureText(e));
      }))
      ..add(ref.listenManual<bool>(roomControllerProvider.select((v) => v.server?.judge?.found ?? false), (_, found) {
        if (found && !_foundNotified) {
          _foundNotified = true;
          unawaited(Haptics.success());
        }
      }, fireImmediately: true))
      ..add(ref.listenManual<String?>(roomControllerProvider.select((v) => v.server?.meetSpot?.id), (_, id) {
        // 待ち合わせ場所が消えたら、道順の行き先を相手に戻す。
        if (id == null && _routeToSpot) setState(() => _routeToSpot = false);
      }));
  }

  @override
  void dispose() {
    _poll?.cancel();
    for (final s in _subs) {
      s.close();
    }
    _map.dispose();
    super.dispose();
  }

  /// ウィジェットの build 中に地図へ通知しない（地図側の setState がぶつからないように）。
  void _afterBuild(VoidCallback f) {
    if (SchedulerBinding.instance.schedulerPhase == SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) f();
      });
    } else {
      f();
    }
  }

  void _updateMe() {
    final fix = ref.read(positionProvider).value;
    if (fix == null) return;
    final floor = floorLabelToInt(ref.read(ownFloorProvider)) ?? 1;
    _afterBuild(() => _map.setMe(MapPin(point: fix.point, floor: floor, name: '自分')));
  }

  void _updatePartner() {
    final p = ref.read(partnerEstimateProvider);
    if (p == null) return; // 一度届いた相手のピンは、距離が一時的に欠けても消さない（app.js と同じ）
    final other = ref.read(roomControllerProvider).server?.other;
    final pin = MapPin(point: p, floor: floorLabelToInt(other?.floor) ?? 1, name: other?.nickname ?? '相手');
    _afterBuild(() {
      _map.setPartner(pin);
      if (!_focused) {
        // 初回だけ2人が収まる距離へ（以後は手動操作を尊重）
        _focused = true;
        _map.focusBoth();
      }
    });
  }

  // ---- 道順 ----

  void _setRoute(bool on, {bool toSpot = false}) {
    setState(() {
      _routeOn = on;
      _routeToSpot = on && toSpot;
      _routeFitted = false;
    });
    if (!on) _afterBuild(() => _map.setRoute(null));
    unawaited(Haptics.light());
  }

  void _onRoute(List<GeoPoint>? line) {
    if (!_routeOn) return;
    // 「道順で案内」を押した直後の最初の道順だけ、経路全体が入る位置に寄せる。
    final fit = line != null && !_routeFitted;
    if (fit) _routeFitted = true;
    _afterBuild(() => _map.setRoute(line, fit: fit));
  }

  RouteTarget? _routeTarget(RoomState s, GeoPoint? partner, List<Place>? places) {
    if (_routeToSpot && places != null) {
      final spot = findPlace(places, s.meetSpot?.id);
      if (spot != null) return RouteTarget(point: spot.point, name: spot.name, level: spot.level);
    }
    if (partner == null) return null;
    final other = s.other;
    return RouteTarget(
      point: partner,
      name: other?.nickname ?? '相手',
      level: appFloorIntToLevel(floorLabelToInt(other?.floor)),
    );
  }

  // ---- 操作 ----

  void _judge() {
    setState(() => _judgeNote = null);
    _ctrl.clearJudgeFailure();
    unawaited(Haptics.light());
    if (!_ctrl.judge()) setState(() => _judgeNote = kMsgNotSent);
  }

  void _setSpot() {
    final id = _spotChoice;
    if (id == null) return;
    unawaited(Haptics.light());
    if (!_ctrl.setSpot(id)) showToast(context, kMsgNotSent);
  }

  Future<void> _stop() async {
    final ok = await showConfirm(context, message: '位置の共有をやめますか？', ok: 'やめる');
    if (!ok || !mounted) return;
    unawaited(Haptics.light());
    // 送れなくても端末からの位置の送信はすぐ止まり、つながったら stop が送り直される（core）。
    _ctrl.stop();
  }

  @override
  Widget build(BuildContext context) {
    final v = ref.watch(roomControllerProvider);
    final s = v.server!;
    final other = s.other;
    final partner = ref.watch(partnerEstimateProvider);
    final places = ref.watch(placesProvider);
    final pois = ref.watch(poisProvider).value;
    final slots = ref.watch(meetSlotsProvider);
    final locationOff = ref.watch(positionProvider.select((a) => a.hasError && !a.hasValue));
    final banner = meetBanner(v, nowMs: _nowMs);
    final dim = banner?.dimDistance ?? false;
    final placeList = places.value;

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      // 1. 状態バナー（1つだけ）
      if (banner != null) StatusBanner(kind: banner.kind, text: banner.text),
      if (v.stopRequested) const StatusBanner(kind: BannerKind.warn, text: '共有をやめました。通信がつながると相手にも伝わります。'),
      if (locationOff && !v.isDemo) _LocationOffCard(),

      // 2. 距離と矢印
      AppCard(
        child: Column(children: [
          Text.rich(
            TextSpan(style: AppText.body, children: [
              const TextSpan(text: '相手: '),
              TextSpan(text: other?.nickname ?? '相手', style: const TextStyle(fontWeight: FontWeight.w800)),
            ]),
            textAlign: TextAlign.center,
          ),
          AnimatedOpacity(
            opacity: dim ? 0.4 : 1,
            duration: const Duration(milliseconds: 300),
            child: Column(children: [
              // 道順の矢印を出している間は、直線の矢印は隠す（矢印が2つあると迷うため。距離の数字は残す）
              if (!_routeOn) DirectionArrow(bearingDeg: s.bearingDeg),
              Semantics(
                label: s.distanceM == null ? '距離はまだ分かりません' : '相手まで${s.distanceM}メートル',
                excludeSemantics: true,
                child: Text.rich(
                  TextSpan(children: [
                    TextSpan(text: s.distanceM?.toString() ?? '--', style: AppText.distance),
                    TextSpan(
                      text: ' m',
                      style: AppText.distanceUnit.copyWith(color: AppColors.mutedText, fontWeight: FontWeight.w600),
                    ),
                  ]),
                  textAlign: TextAlign.center,
                ),
              ),
            ]),
          ),
          Text(
            other?.lastUpdatedAt != null ? '相手の最終更新: ${formatClockHms(other!.lastUpdatedAt!)}' : '相手の位置を待っています…',
            style: AppText.small,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: SecondaryButton(
              label: _routeOn ? 'まっすぐの矢印に戻す' : '道順で案内（歩ける道に沿った矢印）',
              selected: _routeOn,
              onPressed: () => _setRoute(!_routeOn),
            ),
          ),
        ]),
      ),
      if (_routeOn)
        slots.routePanel(context, _routeTarget(s, partner, placeList), _onRoute, () => unawaited(Haptics.success())),

      // 3. 待ち合わせ場所（一覧が読めなければカードごと隠す）
      if (!places.hasError) _meetSpotCard(s, placeList),

      // 4. 会えた判定
      _judgeCard(s.judge),

      // 5. 共有をやめる
      AppCard(child: SecondaryButton(label: '共有をやめる', onPressed: _stop)),

      // 6. 今いる階
      AppCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const FloorChips(),
          if ((s.floorDiffText ?? '').isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Semantics(
                liveRegion: true,
                child: Text(s.floorDiffText!,
                    textAlign: TextAlign.center, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
              ),
            ),
        ]),
      ),

      // 7. 近くのお店（相手の推定位置のまわり）
      _shopsCard(partner, pois),

      // 8. 3D渋谷
      AppCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const _BlockLabel('3D渋谷'),
          ClipRRect(borderRadius: BorderRadius.circular(14), child: slots.map3d(context, _map)),
          const SizedBox(height: 10),
          SecondaryButton(label: 'ARで探す', onPressed: () => context.push('/ar')),
          const SizedBox(height: 8),
          SecondaryButton(label: '高画質で見る', onPressed: () => context.push('/hq')),
        ]),
      ),

      // 9. 出典
      const AttributionText(Attributions.all),
    ]);
  }

  Widget _meetSpotCard(RoomState s, List<Place>? places) {
    final spot = s.meetSpot;
    final decided = spot != null && places != null && findPlace(places, spot.id) != null;
    final choice = places != null && findPlace(places, _spotChoice) != null ? _spotChoice : null;
    return AppCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const _BlockLabel('待ち合わせ場所を決める'),
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Semantics(
            liveRegion: true,
            child: PhraseText(meetSpotText(spot, places), style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
          ),
        ),
        DropdownButtonFormField<String>(
          key: ValueKey('spot-${places?.length}'),
          initialValue: choice,
          isExpanded: true,
          hint: const Text('場所を選ぶ'),
          decoration: const InputDecoration(),
          items: [
            for (final p in places ?? const <Place>[])
              DropdownMenuItem(value: p.id, child: Text(p.name, overflow: TextOverflow.ellipsis)),
          ],
          onChanged: places == null ? null : (id) => setState(() => _spotChoice = id),
        ),
        const SizedBox(height: 10),
        SecondaryButton(label: 'ここで待ち合わせる', onPressed: choice == null ? null : _setSpot),
        if (decided) ...[
          const SizedBox(height: 8),
          PrimaryButton(label: '待ち合わせ場所へ道順で案内', onPressed: () => _setRoute(true, toSpot: true)),
        ],
        const HintText('どちらかが決めると2人に届きます。送るのは場所の名前だけです。'),
      ]),
    );
  }

  Widget _judgeCard(JudgeView? j) {
    final found = j?.found ?? false;
    final note = found ? judgeSourceText(j!) : _judgeNote;
    return AppCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Semantics(
          liveRegion: true,
          child: Container(
            margin: const EdgeInsets.only(bottom: 6),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: found ? AppColors.brandOrange : AppColors.judgeIdleBg,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(judgeStatusText(j),
                textAlign: TextAlign.center,
                style: AppText.judge.copyWith(color: found ? Colors.white : AppColors.ink)),
          ),
        ),
        if (note != null)
          Semantics(
            liveRegion: true,
            child: Text(note, textAlign: TextAlign.center, style: AppText.hint),
          ),
        const SizedBox(height: 14),
        PrimaryButton(label: '会えた！', onPressed: _judge),
      ]),
    );
  }

  Widget _shopsCard(GeoPoint? partner, List<Poi>? pois) {
    final shops = partner != null && pois != null ? nearestShops(pois, partner.lat, partner.lng) : const <NearbyShop>[];
    return AppCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const _BlockLabel('近くのお店'),
        if (shops.isEmpty)
          const HintText('相手の位置と階が分かると表示されます。')
        else
          for (var i = 0; i < shops.length; i++) _ShopRow(shop: shops[i], last: i == shops.length - 1),
      ]),
    );
  }
}

class _BlockLabel extends StatelessWidget {
  const _BlockLabel(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Semantics(
          header: true,
          child: Text(text, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 14, color: AppColors.mutedText)),
        ),
      );
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
            child: Text(shop.name, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14, color: AppColors.ink)),
          ),
          const SizedBox(width: 8),
          Text('${shop.distanceM}m', style: AppText.small),
          // 意図的な簡略化: OSM の level は自由記法（"-1;0" 等）なので変換せずそのまま出す（app.js と同じ）。
          if ((shop.level ?? '').isNotEmpty)
            Container(
              margin: const EdgeInsets.only(left: 6),
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
              decoration: BoxDecoration(color: AppColors.brandOrangeSoftBg, borderRadius: BorderRadius.circular(999)),
              child: Text('${shop.level}階',
                  style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: AppColors.brandOrangeOnSoft)),
            ),
        ]),
      );
}

/// 位置情報が使えない（許可なし・オフ）ときの中立表示＋設定を開く。
class _LocationOffCard extends StatelessWidget {
  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const StatusBanner(kind: BannerKind.warn, text: kMsgLocationOff),
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: SecondaryButton(label: '設定を開く', onPressed: () => unawaited(openAppSettings())),
        ),
      ]);
}
