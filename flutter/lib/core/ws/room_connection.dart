// 再接続つきの WebSocket セッション（SPEC.md §3.4）。
// - 指数バックオフ 1s→2s→…上限15s。open か state を受けたら回数を戻す
// - 再接続しない: close 4001(duplicate_connection) / close 1000(expired) / 終端 phase / 401・400 / 404 が2回続いた
import 'dart:async';
import 'dart:convert';

import '../models/room_models.dart';
import 'room_socket.dart';

enum ConnectionEnd {
  /// 同じ role で別の端末・画面が接続した（4001）。取り合いを避けるため再接続しない。
  duplicate,

  /// 期限切れ（close 1000 "expired" か 404 が続いた＝部屋が消えた）。
  expired,

  /// secret が合わない（401）・role が不正（400）。
  unauthorized,

  /// 終端 phase（stopped/expired）を受けた。
  terminal,

  /// こちらから閉じた。
  closedByClient,
}

sealed class ConnectionStatus {
  const ConnectionStatus();
}

class Connecting extends ConnectionStatus {
  const Connecting(this.attempt);
  final int attempt;
}

class Connected extends ConnectionStatus {
  const Connected();
}

class WaitingRetry extends ConnectionStatus {
  const WaitingRetry(this.attempt, this.delay);
  final int attempt;
  final Duration delay;
}

class Ended extends ConnectionStatus {
  const Ended(this.reason);
  final ConnectionEnd reason;
}

/// attempt 回目（0始まり）の待ち時間。
Duration reconnectDelay(int attempt) {
  final s = attempt >= 4 ? 15 : (1 << attempt);
  return Duration(seconds: s > 15 ? 15 : s);
}

class RoomConnection {
  RoomConnection({
    required this.uri,
    required this.connector,
    required this.onEvent,
    required this.onStatus,
  });

  final Uri uri;
  final RoomSocketConnector connector;
  final void Function(ServerEvent event) onEvent;
  final void Function(ConnectionStatus status) onStatus;

  RoomSocket? _socket;
  StreamSubscription<String>? _sub;
  Timer? _retry;
  int _attempt = 0;
  int _notFoundStreak = 0;
  bool _terminal = false;
  bool _disposed = false;
  ConnectionStatus _status = const Connecting(0);

  ConnectionStatus get status => _status;
  bool get isOpen => _socket != null && _status is Connected;

  void _set(ConnectionStatus s) {
    if (_disposed) return;
    _status = s;
    onStatus(s);
  }

  void start() => _connect();

  /// 終端 phase を受けたら呼ぶ（以後は再接続しない。接続は開いたまま残す）。
  void markTerminal() => _terminal = true;

  /// 送れたら true。閉じているときは false（キューしない。位置は次の更新で送り直される）。
  bool send(String text) {
    final s = _socket;
    if (s == null || _status is! Connected) return false;
    try {
      s.send(text);
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _connect() async {
    if (_disposed) return;
    _set(Connecting(_attempt));
    RoomSocket socket;
    try {
      socket = await connector(uri);
    } on WsHandshakeException catch (e) {
      if (_disposed) return;
      if (e.statusCode == 401 || e.statusCode == 400) return _end(ConnectionEnd.unauthorized);
      if (e.statusCode == 404) {
        _notFoundStreak++;
        if (_notFoundStreak >= 2) return _end(ConnectionEnd.expired);
      }
      return _scheduleRetry();
    } catch (_) {
      if (_disposed) return;
      return _scheduleRetry();
    }
    if (_disposed) {
      unawaited(socket.close(1000));
      return;
    }
    _socket = socket;
    _notFoundStreak = 0;
    _attempt = 0;
    _set(const Connected());
    _sub = socket.messages.listen(
      _onText,
      onDone: () => _onClosed(socket),
      onError: (_) => _onClosed(socket),
      cancelOnError: true,
    );
  }

  void _onText(String text) {
    Object? json;
    try {
      json = jsonDecode(text);
    } catch (_) {
      return;
    }
    final ev = ServerEvent.fromJson(json);
    if (ev == null) return;
    if (ev is StateEvent) {
      _attempt = 0;
      if (ev.state.phase.isTerminal) _terminal = true;
    }
    onEvent(ev);
  }

  void _onClosed(RoomSocket socket) {
    if (!identical(socket, _socket)) return;
    _socket = null;
    _sub = null;
    if (_disposed) return;
    final code = socket.closeCode;
    if (code == 4001) return _end(ConnectionEnd.duplicate);
    if (code == 1000 && socket.closeReason == 'expired') return _end(ConnectionEnd.expired);
    if (_terminal) return _end(ConnectionEnd.terminal);
    _scheduleRetry();
  }

  void _scheduleRetry() {
    if (_disposed) return;
    if (_terminal) return _end(ConnectionEnd.terminal);
    final delay = reconnectDelay(_attempt);
    _attempt++;
    _set(WaitingRetry(_attempt, delay));
    _retry?.cancel();
    _retry = Timer(delay, _connect);
  }

  void _end(ConnectionEnd reason) {
    _retry?.cancel();
    _set(Ended(reason));
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _retry?.cancel();
    await _sub?.cancel();
    final s = _socket;
    _socket = null;
    _status = const Ended(ConnectionEnd.closedByClient); // こちらから閉じたときは通知しない
    if (s != null) await s.close(1000);
  }
}
