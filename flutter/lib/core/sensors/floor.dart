// 「今いる階」のプロバイダ。room（階ピッカー）と route（階チップ・「◯階に着いた」）が同じ値を共有する。
// ユーザーが変えたら、部屋が開いていればサーバーへ floor を送る（画面ラベルだけ。座標は送らない）。
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../constants.dart';
import '../floors.dart';
import '../session/room_controller.dart';

class OwnFloorNotifier extends Notifier<String?> {
  int? _userSetAtMs;

  @override
  String? build() => null;

  /// ユーザーが選んだ（チップ・セレクト・「着いた」ボタン）。部屋が開いていれば送る。
  void setByUser(String label) {
    if (!isValidFloor(label)) return;
    _userSetAtMs = DateTime.now().millisecondsSinceEpoch;
    state = label;
    ref.read(roomControllerProvider.notifier).sendFloor(label);
  }

  /// サーバーの self.floor を反映する。ユーザーが変えてから5秒以内で、まだ追いついていなければ上書きしない。
  void syncFromServer(String? label) {
    if (!isValidFloor(label)) return;
    final at = _userSetAtMs;
    if (at != null && label != state && DateTime.now().millisecondsSinceEpoch - at < kFloorOverrideMs) return;
    _userSetAtMs = null;
    if (state != label) state = label;
  }

  /// 部屋を出たとき等。
  void clear() {
    _userSetAtMs = null;
    state = null;
  }
}

/// 今いる階（"B5"〜"10F"）。未選択は null。
final ownFloorProvider = NotifierProvider<OwnFloorNotifier, String?>(OwnFloorNotifier.new);
