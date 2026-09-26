// roomId・role・secret を端末の secure storage に保存する（Web 版の sessionStorage の代わり）。
// stop / expired / 部屋を出たら消す。
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../models/room_models.dart';

abstract interface class SessionStore {
  Future<RoomSession?> load(String roomId);
  Future<void> save(RoomSession session);
  Future<void> clear(String roomId);
}

class SecureSessionStore implements SessionStore {
  SecureSessionStore([FlutterSecureStorage? storage]) : _s = storage ?? const FlutterSecureStorage();
  final FlutterSecureStorage _s;

  String _key(String roomId) => 'sm:$roomId';

  @override
  Future<RoomSession?> load(String roomId) async {
    try {
      final raw = await _s.read(key: _key(roomId));
      if (raw == null) return null;
      return RoomSession.fromJson(jsonDecode(raw));
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> save(RoomSession session) async {
    try {
      await _s.write(key: _key(session.roomId), value: jsonEncode(session.toJson()));
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
}

/// テスト・デモ用（端末に何も残さない）。
class MemorySessionStore implements SessionStore {
  final Map<String, RoomSession> _m = {};

  @override
  Future<RoomSession?> load(String roomId) async => _m[roomId];

  @override
  Future<void> save(RoomSession session) async => _m[session.roomId] = session;

  @override
  Future<void> clear(String roomId) async => _m.remove(roomId);
}

final sessionStoreProvider = Provider<SessionStore>((ref) => SecureSessionStore());
