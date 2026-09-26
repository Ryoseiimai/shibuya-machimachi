import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/deep_link.dart';
import 'core/router.dart';
import 'core/theme.dart';

class MachimachiApp extends ConsumerWidget {
  const MachimachiApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(routerProvider);
    return DeepLinkScope(
      router: router,
      child: MaterialApp.router(
        title: '渋谷マチマチ',
        debugShowCheckedModeBanner: false,
        theme: buildAppTheme(),
        routerConfig: router,
        locale: const Locale('ja', 'JP'),
        supportedLocales: const [Locale('ja', 'JP')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
      ),
    );
  }
}
