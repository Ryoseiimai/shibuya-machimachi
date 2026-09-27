// シミュレータで主要画面を撮るための小道具。
// 撮影は外側（ホストの simctl io screenshot）で行う: ここは「SHOT:<名前>」を出して、撮り終わるまで待つだけ。
// 地図（MapLibre）や高画質3D（WebView）はプラットフォームビューなので、画面そのものを撮る方が確実。
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shibuya_machimachi/app.dart';

/// 実時間で待つ（地図の読み込み・デモの相手の動きを進める）。
Future<void> wait(WidgetTester tester, Duration d) async {
  final sw = Stopwatch()..start();
  while (sw.elapsed < d) {
    await tester.pump(const Duration(milliseconds: 100));
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
}

/// finder が見つかるまで待つ（見つからなければ失敗）。
Future<void> waitFor(WidgetTester tester, Finder finder, {Duration timeout = const Duration(seconds: 30)}) async {
  final sw = Stopwatch()..start();
  while (finder.evaluate().isEmpty) {
    if (sw.elapsed > timeout) fail('見つかりません: $finder');
    await wait(tester, const Duration(milliseconds: 300));
  }
}

/// finder が消えるまで待つ（消えなくても timeout で先へ進む）。
Future<bool> waitGone(WidgetTester tester, Finder finder, {Duration timeout = const Duration(seconds: 90)}) async {
  final sw = Stopwatch()..start();
  while (finder.evaluate().isNotEmpty) {
    if (sw.elapsed > timeout) return false;
    await wait(tester, const Duration(milliseconds: 500));
  }
  return true;
}

/// ホスト側に撮影を頼み、撮り終わるまで待つ。
Future<void> shot(WidgetTester tester, String name) async {
  await wait(tester, const Duration(milliseconds: 800));
  // ignore: avoid_print
  print('SHOT:$name');
  await wait(tester, const Duration(seconds: 4));
}

Future<void> tapAndWait(WidgetTester tester, Finder finder, {Duration after = const Duration(seconds: 1)}) async {
  await tester.ensureVisible(finder);
  await wait(tester, const Duration(milliseconds: 400));
  await tester.tap(finder);
  await wait(tester, after);
}

/// finder の要素を画面の上端に寄せる。
Future<void> scrollToTop(WidgetTester tester, Finder finder) async {
  await Scrollable.ensureVisible(tester.element(finder), alignment: 0.02);
  await wait(tester, const Duration(milliseconds: 600));
}

/// いちばん外側のスクロールを先頭に戻す。
Future<void> scrollToStart(WidgetTester tester) async {
  final st = tester.state<ScrollableState>(find.byType(Scrollable).first);
  st.position.jumpTo(0);
  await wait(tester, const Duration(milliseconds: 600));
}

Future<ProviderContainer> launchApp(WidgetTester tester) async {
  await tester.pumpWidget(const ProviderScope(child: MachimachiApp()));
  await wait(tester, const Duration(seconds: 2));
  return ProviderScope.containerOf(tester.element(find.byType(MachimachiApp)));
}
