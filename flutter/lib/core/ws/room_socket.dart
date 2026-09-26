// WebSocket の土台。本物（dart:io）とデモ（端末内の模擬）を同じ形で差し替えられるようにする。
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

/// 1本の WebSocket 接続。
abstract interface class RoomSocket {
  /// 受信したテキスト（バイナリは UTF-8 として読む）。接続が閉じると done になる。
  Stream<String> get messages;

  void send(String text);

  Future<void> close([int? code, String? reason]);

  /// 閉じたあとの close code / reason（4001 duplicate_connection、1000 expired など）。
  int? get closeCode;
  String? get closeReason;
}

/// ハンドシェイクが 101 にならなかった。statusCode と、JSON 本文から読めれば reason。
class WsHandshakeException implements Exception {
  const WsHandshakeException(this.statusCode, [this.reason]);
  final int? statusCode;
  final String? reason;

  @override
  String toString() => 'WsHandshakeException($statusCode, $reason)';
}

typedef RoomSocketConnector = Future<RoomSocket> Function(Uri uri);

/// dart:io の実装。ハンドシェイクを自前で行い、失敗時の HTTP ステータス（404=部屋が消えた 等）を取れるようにしている。
/// Origin・Cookie・サブプロトコルは送らない（サーバーは role と secret だけで認証する）。
/// 意図的な簡略化: Sec-WebSocket-Accept の照合は省いている（TLS 前提）。厳密にするなら package:crypto で SHA-1 を照合する。
Future<RoomSocket> connectIoRoomSocket(Uri uri) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
  try {
    final httpUri = uri.replace(scheme: uri.scheme == 'wss' ? 'https' : 'http');
    final req = await client.getUrl(httpUri);
    final rnd = Random.secure();
    final key = base64.encode(List<int>.generate(16, (_) => rnd.nextInt(256)));
    req.headers
      ..set(HttpHeaders.connectionHeader, 'Upgrade')
      ..set(HttpHeaders.upgradeHeader, 'websocket') // サーバーは小文字の websocket だけを受ける
      ..set('Sec-WebSocket-Version', '13')
      ..set('Sec-WebSocket-Key', key);
    req.followRedirects = false;
    final res = await req.close().timeout(const Duration(seconds: 15));
    if (res.statusCode != HttpStatus.switchingProtocols) {
      String? reason;
      try {
        final body = jsonDecode(await utf8.decodeStream(res).timeout(const Duration(seconds: 5)));
        if (body is Map && body['reason'] is String) reason = body['reason'] as String;
      } catch (_) {}
      client.close(force: true);
      throw WsHandshakeException(res.statusCode, reason);
    }
    final socket = await res.detachSocket();
    final ws = WebSocket.fromUpgradedSocket(socket, serverSide: false);
    // WS プロトコルの ping（Cloudflare のランタイムが応答する）。アプリ層の ping は送らない。
    ws.pingInterval = const Duration(seconds: 25);
    return _IoRoomSocket(ws);
  } on WsHandshakeException {
    rethrow;
  } catch (_) {
    client.close(force: true);
    // 例外文言に URL（secret 入り）が入りうるので中身は捨てる。
    throw const WsHandshakeException(null, 'network');
  }
}

class _IoRoomSocket implements RoomSocket {
  _IoRoomSocket(this._ws);
  final WebSocket _ws;

  @override
  late final Stream<String> messages = _ws
      .map<String?>((d) => d is String ? d : (d is List<int> ? utf8.decode(d, allowMalformed: true) : null))
      .where((s) => s != null)
      .cast<String>()
      .asBroadcastStream();

  @override
  void send(String text) => _ws.add(text);

  @override
  Future<void> close([int? code, String? reason]) => _ws.close(code, reason);

  @override
  int? get closeCode => _ws.closeCode;

  @override
  String? get closeReason => _ws.closeReason;
}
