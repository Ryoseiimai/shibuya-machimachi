// 道のデータ（同梱の assets/route/graph.json・約3MB）を1回だけ読み、別 isolate で計算用の配列にする。
// ネットワークは使わない（Web 版は /route/graph.json を fetch していた。Flutter 版は同梱物なので通信なし）。
import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/constants.dart' show kAssetGraph;
import 'route_engine.dart';

/// 計算用の道のグラフ。autoDispose にしない（画面を行き来しても読み直さない）。
/// 失敗したら Riverpod 3 の自動リトライで読み直す（その間パネルは「読み込めませんでした」を出す）。
final routeGraphProvider = FutureProvider<RouteGraph>((ref) async {
  final text = await rootBundle.loadString(kAssetGraph, cache: false);
  return compute(decodeGraphText, text, debugLabel: 'decodeRouteGraph');
});
