// ホームの「続きを開く」: 端末に保存した待ち合わせがあれば出し、押すとその部屋へ。無ければ出さない。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shibuya_machimachi/core/core.dart';
import 'package:shibuya_machimachi/features/ar_home/ar_home_screen.dart';

Future<void> pump(WidgetTester tester, SessionStore store) async {
  await tester.binding.setSurfaceSize(const Size(390, 844));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final router = GoRouter(routes: [
    GoRoute(path: '/', builder: (_, _) => const HomeScreen()),
    GoRoute(path: '/r/:id', builder: (_, s) => Scaffold(body: Text('部屋 ${s.pathParameters['id']}'))),
  ]);
  addTearDown(router.dispose);
  await tester.pumpWidget(ProviderScope(
    overrides: [sessionStoreProvider.overrideWithValue(store)],
    child: MaterialApp.router(theme: buildAppTheme(), routerConfig: router),
  ));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('保存した待ち合わせがあれば「続きを開く」で部屋へ戻れる', (tester) async {
    final store = MemorySessionStore();
    await store.save(RoomSession(roomId: 'a' * 32, role: Role.guest, secret: 'b' * 32, stopPending: true));
    await pump(tester, store);
    expect(find.text('続きを開く'), findsOneWidget);
    expect(find.textContaining('まだ相手に'), findsOneWidget);
    await tester.tap(find.text('続きを開く'));
    await tester.pumpAndSettle();
    expect(find.text('部屋 ${'a' * 32}'), findsOneWidget);
  });

  testWidgets('保存が無ければ出さない', (tester) async {
    await pump(tester, MemorySessionStore());
    expect(find.text('続きを開く'), findsNothing);
  });
}
