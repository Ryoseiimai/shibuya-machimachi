// 送信前の関所: 2048バイト上限と、location の間引き（1.2秒に1回）。
import 'dart:convert';

import '../constants.dart';

class OutboundGuard {
  OutboundGuard({this.maxBytes = kWsMaxMessageBytes, this.locationMinIntervalMs = kLocationMinIntervalMs});

  final int maxBytes;
  final int locationMinIntervalMs;
  int? _lastLocationAtMs;

  /// JSON にして上限以内なら文字列、超えたら null（サーバーは黙って捨てるので送らない）。
  String? encode(Map<String, Object?> msg) {
    final text = jsonEncode(msg);
    if (utf8.encode(text).length > maxBytes) return null;
    return text;
  }

  /// location を今送ってよいか。まだなら、あと何ミリ秒待てばよいかを返す（0 なら今送れる）。
  int locationWaitMs(int nowMs) {
    final last = _lastLocationAtMs;
    if (last == null) return 0;
    final wait = last + locationMinIntervalMs - nowMs;
    return wait > 0 ? wait : 0;
  }

  void markLocationSent(int nowMs) => _lastLocationAtMs = nowMs;

  void reset() => _lastLocationAtMs = null;
}
