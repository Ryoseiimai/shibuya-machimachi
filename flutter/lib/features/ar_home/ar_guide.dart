// AR に「道順の次の曲がり角」を指させるための受け渡し口。
// room（人モードの道順）や route（場所モード）が、端末の中で計算した道順の線をここに置くと、
// AR は相手の方向ではなく「次に向かう点」を指す。何も置かれていなければ相手（partnerEstimateProvider）を指す。
// 道順・行き先はどこにも送らない（SPEC §1.3）。
// 意図的な簡略化: 機能フォルダ内の仮置き。統合時に core へ移す（統合担当への依頼に記載）。
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/core.dart';

/// AR に指させる道順。
class ArGuide {
  const ArGuide({required this.route, required this.destinationName, this.destinationLevel});

  /// 道順の線（自分の近く → 行き先）。RoutePanel の onRoute で受け取る座標列をそのまま渡せばよい。
  final List<GeoPoint> route;

  /// 行き先の名前（「ハチ公像」・相手のニックネーム等）。
  final String destinationName;

  /// 行き先の階（OSM の level: 1F=0, B1=-1）。分からなければ null。
  final num? destinationLevel;

  @override
  String toString() => 'ArGuide(<redacted>)';
}

class ArGuideNotifier extends Notifier<ArGuide?> {
  @override
  ArGuide? build() => null;

  /// 道順が出たら置く（空の線や null なら外す）。
  void set(ArGuide? guide) => state = (guide == null || guide.route.isEmpty) ? null : guide;

  /// 道順を消した・部屋を出たときに必ず呼ぶ（古い道順を AR が指し続けないように）。
  void clear() => state = null;
}

/// 今 AR に指させる道順。null なら AR は相手を指す。
final arGuideProvider = NotifierProvider<ArGuideNotifier, ArGuide?>(ArGuideNotifier.new);
