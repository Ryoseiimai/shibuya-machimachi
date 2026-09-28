import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';
import 'core/models/room_models.dart';
import 'core/router.dart';
import 'core/session/session_store.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  // OS に終了させられた待ち合わせがあれば、その部屋から開く（期限切れの保存はここで消える）。
  // 読めない・遅いときはホームから（ホームの「続きを開く」でも戻れる）。
  RoomSession? saved;
  try {
    saved = await SecureSessionStore().latest().timeout(const Duration(seconds: 2));
  } catch (_) {
    saved = null;
  }
  runApp(ProviderScope(
    overrides: [initialLocationProvider.overrideWithValue(initialLocationFor(saved))],
    child: const MachimachiApp(),
  ));
}
