// ホーム: 文言（lp.js）・入口3つの遷移・このアプリについて（リンク・ライセンス）・文字 200% で崩れない。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shibuya_machimachi/core/core.dart';
import 'package:shibuya_machimachi/features/ar_home/ar_home_screen.dart';
import 'package:shibuya_machimachi/features/ar_home/home_view.dart';

class Opened {
  final calls = <(Uri, bool)>[];
  bool result = true;
}

Future<Opened> pumpHome(WidgetTester tester, {double textScale = 1, bool openResult = true}) async {
  await tester.binding.setSurfaceSize(const Size(390, 844));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final opened = Opened()..result = openResult;
  final router = GoRouter(
    routes: [
      GoRoute(path: '/', builder: (_, _) => const HomeScreen()),
      GoRoute(
        path: '/new',
        builder: (_, s) => Scaffold(body: Text('作成画面 demo=${s.uri.queryParameters['demo']}')),
      ),
      GoRoute(
        path: '/go',
        builder: (_, _) => const Scaffold(body: Text('場所モード')),
      ),
    ],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        homeLinkOpenerProvider.overrideWithValue((uri, {required external}) async {
          opened.calls.add((uri, external));
          return opened.result;
        }),
      ],
      child: MaterialApp.router(
        theme: buildAppTheme(),
        routerConfig: router,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return opened;
}

Future<void> scrollTo(WidgetTester tester, Finder f) async {
  await tester.scrollUntilVisible(f, 200, scrollable: find.byType(Scrollable).first);
  await tester.ensureVisible(f);
  await tester.pumpAndSettle();
}

/// 見える所まで動かしてから押す。
Future<void> tapVisible(WidgetTester tester, Finder f) async {
  await scrollTo(tester, f);
  await tester.tap(f);
  await tester.pump();
}

void main() {
  testWidgets('ヒーローの文言（lp.js）', (tester) async {
    final semantics = tester.ensureSemantics();
    await pumpHome(tester);
    expect(find.text('渋谷駅から1.5km限定・無料'), findsOneWidget);
    expect(find.bySemanticsLabel('今日、渋谷の待ち合わせで困ったから作りました。'), findsOneWidget);
    expect(find.bySemanticsLabel('渋谷マチマチ — お互いに承認した2人だけで、渋谷で迷わず会える'), findsOneWidget);
    expect(find.text('待ち合わせを作る'), findsOneWidget);
    expect(find.text('（無料・登録なし）'), findsOneWidget);
    expect(find.bySemanticsLabel('ニックネームだけで今すぐ使えます。アカウント登録は不要です。'), findsOneWidget);
    expect(find.text('1人で使う：場所へ行く（道順で案内）'), findsOneWidget);
    expect(find.text('デモで試す（1台で体験）'), findsOneWidget);
    semantics.dispose();
  });

  testWidgets('「待ち合わせを作る」→ /new', (tester) async {
    await pumpHome(tester);
    await tester.tap(find.byKey(const ValueKey('home-create')));
    await tester.pumpAndSettle();
    expect(find.text('作成画面 demo=null'), findsOneWidget);
  });

  testWidgets('「場所へ行く」→ /go', (tester) async {
    await pumpHome(tester);
    await tester.tap(find.byKey(const ValueKey('home-go')));
    await tester.pumpAndSettle();
    expect(find.text('場所モード'), findsOneWidget);
  });

  testWidgets('「デモで試す」→ /new?demo=1', (tester) async {
    await pumpHome(tester);
    await tapVisible(tester, find.byKey(const ValueKey('home-demo')));
    await tester.pumpAndSettle();
    expect(find.text('作成画面 demo=1'), findsOneWidget);
  });

  testWidgets('3ステップ・安心の設計6項目・できること7項目（折りたたみ）', (tester) async {
    final semantics = tester.ensureSemantics();
    await pumpHome(tester);
    expect(kHomeSteps, hasLength(3));
    expect(kHomeTrust, hasLength(6));
    expect(kHomeFeatures, hasLength(7));
    await scrollTo(tester, find.byKey(const ValueKey('home-trust')));
    for (final t in kHomeTrust) {
      expect(find.bySemanticsLabel(t.replaceAll('／', '')), findsOneWidget, reason: t);
    }
    expect(find.bySemanticsLabel('位置情報はサーバーのログに残さない'), findsOneWidget);

    await scrollTo(tester, find.byKey(const ValueKey('home-features')));
    expect(find.text('カメラ越しに相手の人影（AR）'), findsNothing);
    await tapVisible(tester, find.text('渋谷マチマチができること'));
    await tester.pumpAndSettle();
    for (final f in kHomeFeatures) {
      expect(find.text(f.title), findsOneWidget, reason: f.title);
    }
    semantics.dispose();
  });

  testWidgets('このアプリについて: GitHub は外部、プライバシー/サポートはアプリ内ブラウザ', (tester) async {
    final opened = await pumpHome(tester);
    await tapVisible(tester, find.byKey(const ValueKey('about-github')));
    await tapVisible(tester, find.byKey(const ValueKey('about-privacy')));
    await tapVisible(tester, find.byKey(const ValueKey('about-support')));
    expect(opened.calls, [
      (Uri.parse('https://github.com/Ryoseiimai/shibuya-machimachi'), true),
      (Uri.parse('$kProdBaseUrl/privacy'), false),
      (Uri.parse('$kProdBaseUrl/support'), false),
    ]);
    expect(kPrivacyUri.toString(), 'https://shibuya-machimachi.kaeru3160.workers.dev/privacy');
  });

  testWidgets('開けなかったら「ページを開けませんでした」', (tester) async {
    await pumpHome(tester, openResult: false);
    await tapVisible(tester, find.byKey(const ValueKey('about-privacy')));
    expect(find.text('ページを開けませんでした'), findsOneWidget);
  });

  testWidgets('ライセンス画面と出典', (tester) async {
    await pumpHome(tester);
    await scrollTo(tester, find.text(Attributions.all));
    expect(find.text(Attributions.all), findsOneWidget);
    await tapVisible(tester, find.byKey(const ValueKey('about-licenses')));
    await tester.pumpAndSettle();
    expect(find.byType(LicensePage), findsOneWidget);
  });

  testWidgets('文字サイズ 200% でもはみ出さない（最後まで表示できる）', (tester) async {
    await pumpHome(tester, textScale: 2);
    expect(tester.takeException(), isNull);
    await tapVisible(tester, find.text('渋谷マチマチができること'));
    await tester.pumpAndSettle();
    await scrollTo(tester, find.text(Attributions.all));
    expect(tester.takeException(), isNull);
  });

  testWidgets('アプリのマークが描ける', (tester) async {
    await pumpHome(tester);
    expect(find.byType(AppMark), findsOneWidget);
    expect(tester.getSize(find.byType(AppMark)), const Size(48, 48));
  });
}
