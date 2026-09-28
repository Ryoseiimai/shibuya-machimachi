// 階の表記の変換。3種類あるので取り違えないこと。
// - 画面ラベル（サーバーの floor の値）: "1F" "B1"
// - app の階整数（3D 地図用）: 1F=1, B1=-1（0 は無い）
// - OSM の level（道順エンジンの内部）: 1F=0, B1=-1
import 'constants.dart';
import 'geo.dart' show jsRound;

bool isValidFloor(String? label) => label != null && kFloors.contains(label);

/// "B3"→-3、"3F"→3。不正なら null（worker/src/floors.js の floorLabelToInt）。
int? floorLabelToInt(String? label) {
  if (!isValidFloor(label)) return null;
  final l = label!;
  return l.startsWith('B') ? -int.parse(l.substring(1)) : int.parse(l.substring(0, l.length - 1));
}

/// app の階整数 → 画面ラベル（1以上は "nF"、それ以外は "B|n|"）。geo.js の formatFloor。
String formatFloor(int floor) => floor >= 1 ? '${floor}F' : 'B${floor.abs()}';

/// 相手が何階上/下か（サーバーの floorDiffLabel と同じ文言）。
String floorDiffLabel(String? myFloor, String? otherFloor) {
  if (!isValidFloor(myFloor) || !isValidFloor(otherFloor)) return '相手のフロアは未設定です';
  final diff = kFloors.indexOf(otherFloor!) - kFloors.indexOf(myFloor!);
  if (diff == 0) return '相手は同じ階にいます';
  if (diff > 0) return '相手は$diffつ上の階にいます';
  return '相手は${diff.abs()}つ下の階にいます';
}

/// "1F"→0、"10F"→9、"B3"→-3。"0F" や不正は null（route.js の floorLabelToLevel）。
int? floorLabelToLevel(String? label) {
  if (label == null) return null;
  final b = RegExp(r'^B(\d+)$').firstMatch(label);
  if (b != null) return -int.parse(b.group(1)!);
  final f = RegExp(r'^(\d+)F$').firstMatch(label);
  if (f != null) {
    final n = int.parse(f.group(1)!);
    return n >= 1 ? n - 1 : null;
  }
  return null;
}

/// OSM level → 画面ラベル（0→"1F"、-2→"B2"）。
String levelToFloorLabel(num level) {
  final l = jsRound(level.isFinite ? level : 0);
  return l >= 0 ? '${l + 1}F' : 'B${-l}';
}

/// OSM level → 「1階」「地下1階」。
String levelLabel(num level) {
  final l = jsRound(level.isFinite ? level : 0);
  return l >= 0 ? '${l + 1}階' : '地下${-l}階';
}

/// app の階整数 → OSM level。
num? appFloorIntToLevel(int? f) {
  if (f == null) return null;
  return f >= 1 ? f - 1 : f;
}

/// OSM level → app の階整数（null なら 1）。
int levelToAppFloorInt(num? level) {
  if (level == null || !level.isFinite) return 1;
  final l = jsRound(level);
  return l >= 0 ? l + 1 : l;
}
