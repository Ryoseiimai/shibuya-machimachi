// 道順パネルの状態機械（worker/public/assets/js/route-panel.js の mountRoutePanel の中身の移植）。
// 画面に依存しない純 Dart にして、ウィジェット無しで単体テストできるようにしている（描画は route_screen.dart）。
//
// 位置情報の扱い: 自分の位置・目的地・経路はこの端末の中だけで使い、ネットワークには送らない。
// 送るのは「今いる階」の画面ラベルだけ（onLevelChange → ownFloorProvider.setByUser。部屋が開いているときだけ core が送る）。
import '../../core/floors.dart' show isValidFloor, levelLabel, levelToFloorLabel;
import '../../core/geo.dart' show GeoPoint, distanceMeters, isInShibuyaArea, jsRound;
import 'engine/route_engine.dart';

/// 再計算は最短でも3秒おき（GPSのぶれで毎秒計算し直さない）。
const int kReplanMinIntervalMs = 3000;

/// 「◯階に着いた」を押した後は、GPSがこれ以上動くまで「階の移動が終わった地点」にいるものとして案内する
/// （地下や館内ではGPSがほぼ更新されないため。動いたら本物のGPSに戻す）。
const double kVirtualPositionReleaseM = 15;

/// 目的地（相手）がこれ以上動いたら計算し直す。
const double kTargetMoveReplanM = 20;

const Map<RouteFailure, String> kRouteFailureText = {
  RouteFailure.noStart: '近くに歩ける道が見つかりません(渋谷駅から1.5km以内で使えます)',
  RouteFailure.noGoal: '目的地の近くに歩ける道が見つかりません',
  RouteFailure.unreachable: '道順が見つかりませんでした',
};

/// パネルの行き先（route-panel.js の setTarget に渡す {lat, lng, level, name}）。
class PanelTarget {
  const PanelTarget({required this.lat, required this.lng, this.level, this.name = ''});
  final double lat;
  final double lng;
  final num? level;
  final String name;

  @override
  String toString() => 'PanelTarget(<redacted>)';
}

/// 描画に必要なものだけを並べた表示の中身。
class RoutePanelView {
  const RoutePanelView({
    required this.destName,
    required this.destFloor,
    required this.instruction,
    required this.remaining,
    required this.arrived,
    required this.floorChange,
    required this.confirmLabel,
    required this.bearingDeg,
  });

  /// 行き先の名前（行き先なしは空）。
  final String destName;

  /// 行き先の階（" 地下1階" のように先頭に空白。不明なら空）。
  final String destFloor;

  /// 案内文（状態の文言を含む）。
  final String instruction;

  /// 「残り{x}・約{n}分」（案内中だけ）。
  final String remaining;
  final bool arrived;

  /// 階の移動の案内中（地の色を変える）。
  final bool floorChange;

  /// 「◯階に着いた」ボタンの文言（出さないときは null）。
  final String? confirmLabel;

  /// 矢印が指す向き（真方位）。案内が無い・到着したときは null（矢印を薄くする）。
  final double? bearingDeg;
}

class RoutePanelLogic {
  RoutePanelLogic({
    required this.emptyText,
    this.onLevelChange,
    this.onRoute,
    this.onArrive,
    this.onChanged,
    int Function()? nowMs,
  }) : _nowMs = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch);

  /// 行き先が無いときの文言（場所モード「行き先を選んでください」・人モード「相手の位置を待っています…」）。
  final String emptyText;

  /// ユーザーが階を変えた（チップは ownFloorProvider が直接受けるので、ここに来るのは「着いた」ボタンだけ）。
  final void Function(int level)? onLevelChange;

  /// 経路を計算するたび（null は経路なし）。
  final void Function(WalkRoute? route)? onRoute;

  /// 到着した瞬間に1回。
  final void Function()? onArrive;

  /// 表示が変わったかもしれないとき（ウィジェットの setState 用）。
  final void Function()? onChanged;
  final int Function() _nowMs;

  ({double lat, double lng})? _self;
  num _level = 0;
  PanelTarget? _target;
  ({double lat, double lng, double gpsLat, double gpsLng})? _virtualSelf;
  RouteGraph? _graph;
  bool _loadError = false;
  WalkRoute? _route;
  PanelTarget? _planTarget;
  num? _planLevel;
  int _lastPlanAt = 0;
  RouteFailure? _reason;
  int _progressIndex = 0;
  Guidance? _guidance;
  bool _arrivedNotified = false;
  bool _disposed = false;

  WalkRoute? get route => _route;
  Guidance? get guidance => _guidance;
  num get level => _level;
  PanelTarget? get target => _target;

  /// 道のデータが読めた。
  void setGraph(RouteGraph graph) {
    _graph = graph;
    _loadError = false;
    _update(true);
  }

  /// 道のデータが読めなかった（再試行中も含む）。読めたら setGraph が呼ばれる。
  void setLoadError() {
    if (_graph != null) return;
    _loadError = true;
    _render();
  }

  void setSelf(double lat, double lng) {
    if (!lat.isFinite || !lng.isFinite) return;
    _self = (lat: lat, lng: lng);
    _update(false);
  }

  /// 外から階が変わった（チップ・部屋の同期）。
  void setLevel(num level) {
    if (!level.isFinite || level == _level) return;
    _level = level;
    _update(true);
  }

  void setTarget(PanelTarget? target) {
    final changedDest = _target == null || target == null || _target!.name != target.name;
    _target = target != null && target.lat.isFinite && target.lng.isFinite ? target : null;
    if (changedDest) {
      // 行き先を外したときは、3D の線も消す（Web 版は線を残していた。行き先の無い線は紛らわしいので消す）。
      if (_target == null && _route != null) onRoute?.call(null);
      _route = null;
      _arrivedNotified = false;
      _virtualSelf = null;
    }
    _update(changedDest);
  }

  /// 「◯階に着いた」ボタン。
  void confirmFloor() {
    final g = _guidance;
    final fp = g?.floorPrompt;
    if (g == null || fp == null) return;
    final self = _self;
    if (self != null) _virtualSelf = (lat: fp.endLat, lng: fp.endLng, gpsLat: self.lat, gpsLng: self.lng);
    _setLevelInternal(jsRound(fp.toLevel), fromUser: true);
  }

  void dispose() => _disposed = true;

  void _setLevelInternal(int level, {required bool fromUser}) {
    if (level == _level) return;
    _level = level;
    if (fromUser) onLevelChange?.call(level);
    _update(true); // 階が変わったら、その階から計算し直す
  }

  // 案内に使う「今の位置」: 着いたボタンの直後はGPSが動くまで階の移動の終点、それ以外はGPS
  ({double lat, double lng})? _currentPosition() {
    final v = _virtualSelf;
    final self = _self;
    if (v != null && self != null && distanceMeters(v.gpsLat, v.gpsLng, self.lat, self.lng) < kVirtualPositionReleaseM) {
      return (lat: v.lat, lng: v.lng);
    }
    _virtualSelf = null;
    return self;
  }

  bool _outsideArea() {
    final self = _self;
    return self != null && !isInShibuyaArea(self.lat, self.lng);
  }

  bool _targetMoved() {
    final a = _planTarget;
    final b = _target;
    if (a == null || b == null) return true;
    if (a.level != b.level) return true;
    return distanceMeters(a.lat, a.lng, b.lat, b.lng) > kTargetMoveReplanM;
  }

  bool _plan(bool force) {
    final now = _nowMs();
    if (!force && now - _lastPlanAt < kReplanMinIntervalMs) return false;
    _lastPlanAt = now;
    final here = _currentPosition()!;
    final t = _target!;
    final result = findRoute(
      _graph!,
      RouteEndpoint(lat: here.lat, lng: here.lng, level: _level),
      RouteEndpoint(lat: t.lat, lng: t.lng, level: t.level, name: t.name),
    );
    _planTarget = t;
    _planLevel = _level;
    _progressIndex = 0;
    _route = result.route;
    _reason = result.reason;
    onRoute?.call(_route);
    return true;
  }

  void _update(bool forcePlan) {
    if (_disposed) return;
    _guidance = null;
    if (_graph == null || _self == null || _target == null || _outsideArea()) {
      _render();
      return;
    }
    final levelChanged = _planLevel != _level;
    if (_route == null || levelChanged || _targetMoved()) _plan(forcePlan || _route == null || levelChanged);
    var route = _route;
    if (route == null) {
      _render();
      return;
    }
    var pos = _currentPosition()!;
    var g = guide(route, pos.lat, pos.lng, level: _level, progressIndex: _progressIndex);
    if (g.offRoute && !g.arrived && _plan(false) && _route != null) {
      route = _route!;
      pos = _currentPosition()!;
      g = guide(route, pos.lat, pos.lng, level: _level, progressIndex: 0);
    }
    _progressIndex = g.progressIndex;
    _guidance = g;
    if (g.arrived && !_arrivedNotified) {
      _arrivedNotified = true;
      onArrive?.call();
    }
    if (!g.arrived) _arrivedNotified = false;
    _render();
  }

  void _render() {
    if (_disposed) return;
    onChanged?.call();
  }

  /// 今の表示（route-panel.js の render の文言の優先順どおり）。
  RoutePanelView view() {
    final t = _target;
    final destName = t == null ? '' : (t.name.isEmpty ? '目的地' : t.name);
    final tl = t?.level;
    final destFloor = t != null && tl != null && tl.isFinite ? ' ${levelLabel(tl)}' : '';
    String text;
    var sub = '';
    var arrived = false;
    var floorChange = false;
    String? confirm;
    double? bearing;
    if (_loadError) {
      text = '道のデータを読み込めませんでした。通信を確かめて開き直してください';
    } else if (_graph == null) {
      text = '道のデータを読み込んでいます…';
    } else if (_self == null) {
      text = '現在地を取得しています…(位置情報を許可してください)';
    } else if (_outsideArea()) {
      text = '渋谷エリア(駅から1.5km)の外なので、道順は出せません';
    } else if (t == null) {
      text = emptyText;
    } else if (_route == null || _guidance == null) {
      text = kRouteFailureText[_reason] ?? '道順を計算しています…';
    } else {
      final g = _guidance!;
      arrived = g.arrived;
      text = g.arrived ? '到着しました！' : g.instruction.text;
      sub = g.arrived ? '' : remainingText(g.remainingM);
      floorChange = !g.arrived && g.instruction.kind == ManeuverKind.floor;
      if (!g.arrived && g.floorPrompt != null) confirm = '${levelLabel(g.floorPrompt!.toLevel)}に着いた';
      if (!g.arrived) bearing = g.bearingDeg;
    }
    return RoutePanelView(
      destName: destName,
      destFloor: destFloor,
      instruction: text,
      remaining: sub,
      arrived: arrived,
      floorChange: floorChange,
      confirmLabel: confirm,
      bearingDeg: bearing,
    );
  }
}

/// 経路 → 3D 地図の線（GeoPoint 列）。
List<GeoPoint>? routeLine(WalkRoute? route) => route == null ? null : routeLineCoordinates(route);

/// OSM level → 「今いる階」ボタンの画面ラベル。範囲外（B6 以下・11F 以上）は null。
String? levelToValidFloorLabel(num level) {
  final label = levelToFloorLabel(level);
  return isValidFloor(label) ? label : null;
}
