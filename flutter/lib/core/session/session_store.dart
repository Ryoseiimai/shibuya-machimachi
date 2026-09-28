// roomId・role・secret（host は招待 URL も）を端末の secure storage に保存する（Web 版の sessionStorage の代わり）。
// アプリが途中で終了しても待ち合わせに戻れるように、アプリを閉じても残す。そのかわり:
//   - stop / expired / 部屋を出たら消す
//   - 保存から 3 時間（部屋の寿命 kRoomTtlMs）を過ぎたものは、読むときに消す（起動時にも読む）
//   - iOS はキーチェーンを「この端末のみ・初回ロック解除後」にして、バックアップ・機種変更の移行に載せない
//     （Android は AndroidManifest の allowBackup=false で同じ）
// 意図的な簡略化: iOS のキーチェーンはアプリを削除しても残るが、再インストールの検出はしていない。
// 残った保存も上の 3 時間の期限で次の起動時に消える。厳密にするなら、初回起動フラグを
// 削除で消える場所（NSUserDefaults 等）に置き、無ければ deleteAll する。
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../constants.dart';
import '../models/room_models.dart';

abstract interface class SessionStore {
  /// 保存済みのセッション（無い・期限切れなら null。期限切れはこのとき消す）。
  Future<RoomSession?> load(String roomId);

  /// 保存する。savedAtMs が無ければ今の時刻を入れる。
  Future<void> save(RoomSession session);

  Future<void> clear(String roomId);

  /// 保存済みのうちいちばん新しいもの（起動時の復帰・ホームの「続きを開く」用）。期限切れは消して返さない。
  Future<RoomSession?> latest();
}

/// 保存から部屋の寿命（3時間）を過ぎたか。保存時刻が無いものも期限切れ扱い。
bool isSavedSessionExpired(RoomSession s, int nowMs) {
  final at = s.savedAtMs;
  return at == null || nowMs - at >= kRoomTtlMs || at - nowMs > 60000;
}

int _now() => DateTime.now().millisecondsSinceEpoch;

class SecureSessionStore implements SessionStore {
  SecureSessionStore([FlutterSecureStorage? storage, int Function()? nowMs])
      : _s = storage ?? const FlutterSecureStorage(iOptions: kSessionKeychainOptions),
        _nowMs = nowMs ?? _now;
  final FlutterSecureStorage _s;
  final int Function() _nowMs;

  static const _prefix = 'sm:';
  String _key(String roomId) => '$_prefix$roomId';

  @override
  Future<RoomSession?> load(String roomId) async {
    try {
      final raw = await _s.read(key: _key(roomId));
      if (raw == null) return null;
      final s = RoomSession.fromJson(jsonDecode(raw));
      if (s == null || s.roomId != roomId || isSavedSessionExpired(s, _nowMs())) {
        await clear(roomId);
        return null;
      }
      return s;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> save(RoomSession session) async {
    try {
      final s = session.savedAtMs == null ? session.copyWith(savedAtMs: _nowMs()) : session;
      await _s.write(key: _key(s.roomId), value: jsonEncode(s.toJson()));
    } catch (_) {
      // 保存できなくても今の接続は続けられる（開き直したときに招待プレビューからになるだけ）。
    }
  }

  @override
  Future<void> clear(String roomId) async {
    try {
      await _s.delete(key: _key(roomId));
    } catch (_) {}
  }

  @override
  Future<RoomSession?> latest() async {
    Map<String, String> all;
    try {
      all = await _s.readAll();
    } catch (_) {
      return null;
    }
    final now = _nowMs();
    RoomSession? best;
    for (final e in all.entries.toList()) {
      if (!e.key.startsWith(_prefix)) continue;
      RoomSession? s;
      try {
        s = RoomSession.fromJson(jsonDecode(e.value));
      } catch (_) {
        s = null;
      }
      if (s == null || _key(s.roomId) != e.key || isSavedSessionExpired(s, now)) {
        try {
          await _s.delete(key: e.key);
        } catch (_) {}
        continue;
      }
      if (best == null || s.savedAtMs! > best.savedAtMs!) best = s;
    }
    return best;
  }
}

/// iOS: この端末だけ・初回ロック解除後（バックアップ・機種変更の移行に載せない）。
const IOSOptions kSessionKeychainOptions = IOSOptions(accessibility: KeychainAccessibility.first_unlock_this_device);

/// テスト・デモ用（端末に何も残さない）。
class MemorySessionStore implements SessionStore {
  MemorySessionStore([int Function()? nowMs]) : _nowMs = nowMs ?? _now;
  final int Function() _nowMs;
  final Map<String, RoomSession> _m = {};

  @override
  Future<RoomSession?> load(String roomId) async {
    final s = _m[roomId];
    if (s != null && isSavedSessionExpired(s, _nowMs())) {
      _m.remove(roomId);
      return null;
    }
    return s;
  }

  @override
  Future<void> save(RoomSession session) async =>
      _m[session.roomId] = session.savedAtMs == null ? session.copyWith(savedAtMs: _nowMs()) : session;

  @override
  Future<void> clear(String roomId) async => _m.remove(roomId);

  @override
  Future<RoomSession?> latest() async {
    final now = _nowMs();
    _m.removeWhere((_, s) => isSavedSessionExpired(s, now));
    RoomSession? best;
    for (final s in _m.values) {
      if (best == null || s.savedAtMs! > best.savedAtMs!) best = s;
    }
    return best;
  }
}

final sessionStoreProvider = Provider<SessionStore>((ref) => SecureSessionStore());

/// 端末に保存してある待ち合わせ（デモは含まない）。ホームの「続きを開く」に使う。
final savedRoomProvider = FutureProvider.autoDispose<RoomSession?>((ref) => ref.watch(sessionStoreProvider).latest());
