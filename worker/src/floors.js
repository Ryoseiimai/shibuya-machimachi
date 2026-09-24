/**
 * フロア(階)の純粋関数ユーティリティ。
 * 「3D渋谷」「近くのお店」枠を除き、今は自分でB5〜10Fを選ぶピッカーのみを実装する
 * (意図的な簡略化: 建物ごとの実フロア情報は持たず、渋谷全体で共通の1本のフロア軸として
 * 扱う。実在ビルのフロア対応が要る本格対応では、建物IDごとにFLOORSを持つ形に拡張する)。
 */
import { FLOORS } from "./constants.js";

export { FLOORS };

export function isValidFloor(floor) {
  return typeof floor === "string" && FLOORS.includes(floor);
}

// 相手のフロアが自分から見て何階分・どちら向きに離れているか
export function floorDiff(myFloor, otherFloor) {
  if (!isValidFloor(myFloor) || !isValidFloor(otherFloor)) return null;
  return FLOORS.indexOf(otherFloor) - FLOORS.indexOf(myFloor);
}

// floorDiffの結果を日本語ラベルにする(UIとJev判定の文脈作成の両方から使う)
export function floorDiffLabel(myFloor, otherFloor) {
  const diff = floorDiff(myFloor, otherFloor);
  if (diff === null) return "相手のフロアは未設定です";
  if (diff === 0) return "相手は同じ階にいます";
  if (diff > 0) return `相手は${diff}つ上の階にいます`;
  return `相手は${Math.abs(diff)}つ下の階にいます`;
}

export function sameFloor(myFloor, otherFloor) {
  return floorDiff(myFloor, otherFloor) === 0;
}

// "B5"〜"10F"のフロア表記を整数(-5〜10, 0は無し)に変換する。3D渋谷・AR部品(共に
// worker/public/assets/js/配下の別リポジトリ由来コード)が「階」を整数で受け取る
// API(setMe/setPartner の floor 引数)になっているためのブリッジ。
// クライアント側(html.jsのインラインscript)はサーバー側モジュールをimportできないため、
// 同じロジックを client 側にも複製している(html.js の floorLabelToInt を参照)。
export function floorLabelToInt(floorLabel) {
  if (!isValidFloor(floorLabel)) return null;
  return floorLabel.charAt(0) === "B" ? -Number(floorLabel.slice(1)) : Number(floorLabel.slice(0, -1));
}
