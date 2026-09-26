// 接続先・API・WebSocket の差し替え口。デモ中は模擬に替わる。
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'api/api_client.dart';
import 'constants.dart';
import 'demo/demo_mode.dart';
import 'session/session_store.dart';
import 'ws/room_socket.dart';

/// API のベース URL。ローカルの wrangler dev に向けるときは
/// `flutter run --dart-define=API_BASE=http://<Mac の IP>:<port>`（8787・8799 は他で使用中なので避ける）。
final baseUrlProvider = Provider<String>((ref) => const String.fromEnvironment('API_BASE', defaultValue: kProdBaseUrl));

final _httpApiProvider = Provider<ApiClient>((ref) => HttpApiClient(baseUrl: ref.watch(baseUrlProvider)));

/// 本物かデモの API。
final apiClientProvider = Provider<ApiClient>((ref) {
  return ref.watch(demoModeProvider) ? ref.watch(demoBackendProvider) : ref.watch(_httpApiProvider);
});

/// 本物かデモの WebSocket 接続。
final roomSocketConnectorProvider = Provider<RoomSocketConnector>((ref) {
  if (ref.watch(demoModeProvider)) return ref.watch(demoBackendProvider).connect;
  return connectIoRoomSocket;
});

final _memoryStoreProvider = Provider<SessionStore>((ref) => MemorySessionStore());

/// デモ中は端末に何も残さない。
final activeSessionStoreProvider = Provider<SessionStore>((ref) {
  return ref.watch(demoModeProvider) ? ref.watch(_memoryStoreProvider) : ref.watch(sessionStoreProvider);
});
