// AR部品(元リポジトリ: shibuya-machimachi-ar, src/geo.test.js)のユニットテストを、
// 統合先のこの本体repoでも回すために移植したもの。テスト対象は
// worker/public/assets/js/geo.js (実際に配信される、AR部品(ar.js)が依存するファイルそのもの)。
// DOM/ブラウザAPI非依存の純粋関数のみを検証する(node:testでそのまま実行できる)。
import { test } from "node:test";
import assert from "node:assert/strict";
import {
  bearingDegrees,
  distanceMeters,
  normalizeAngleDiff,
  destinationPoint,
  destinationFromOffset,
  formatDistance,
  formatFloor,
  floorIndicatorText,
} from "../public/assets/js/geo.js";

test("bearingDegrees: 真東・真西・真南・真北が期待どおり", () => {
  assert.ok(Math.abs(bearingDegrees(0, 0, 0, 1) - 90) < 0.01, "真東は90度");
  assert.ok(Math.abs(bearingDegrees(0, 0, 0, -1) - 270) < 0.01, "真西は270度");
  assert.ok(Math.abs(bearingDegrees(0, 0, 1, 0) - 0) < 0.01, "真北は0度");
  assert.ok(Math.abs(bearingDegrees(0, 0, -1, 0) - 180) < 0.01, "真南は180度");
});

test("bearingDegrees: 渋谷駅付近の実座標での方向感覚(北東方向)", () => {
  const b = bearingDegrees(35.658, 139.7016, 35.659, 139.7026);
  assert.ok(b > 0 && b < 90, `北東寄りなので0〜90度の範囲のはず: got ${b}`);
});

test("distanceMeters: 赤道上で経度1度はおよそ111km", () => {
  const d = distanceMeters(0, 0, 0, 1);
  assert.ok(Math.abs(d - 111195) < 1000, `got ${d}`);
});

test("distanceMeters: 同じ地点は0m", () => {
  assert.equal(distanceMeters(35.658, 139.7016, 35.658, 139.7016), 0);
});

test("normalizeAngleDiff: 正規化と符号(正=右、負=左)", () => {
  assert.equal(normalizeAngleDiff(0, 90), 90);
  assert.equal(normalizeAngleDiff(0, -90), -90);
  assert.equal(normalizeAngleDiff(350, 10), 20); // 350度→10度は+20度(またぎ)
  assert.equal(normalizeAngleDiff(10, 350), -20);
  assert.equal(normalizeAngleDiff(0, 200), -160); // 200度は-160度側が近い
});

test("destinationPoint → bearingDegrees の往復整合性", () => {
  const start = { lat: 35.658, lng: 139.7016 };
  for (const bearing of [0, 45, 90, 135, 180, 225, 270, 315]) {
    const dest = destinationPoint(start.lat, start.lng, bearing, 200);
    const backBearing = bearingDegrees(start.lat, start.lng, dest.lat, dest.lng);
    const diff = Math.abs(normalizeAngleDiff(bearing, backBearing));
    assert.ok(diff < 0.1, `bearing=${bearing} got back=${backBearing}`);
    const dist = distanceMeters(start.lat, start.lng, dest.lat, dest.lng);
    assert.ok(Math.abs(dist - 200) < 0.5, `distance mismatch for bearing=${bearing}: ${dist}`);
  }
});

// 渋谷マチマチ本体への統合で追加した観点: destinationPoint はサーバーがWebSocketで送る
// distance_m/bearing_deg(相手の生座標そのものではない)から相手の推定座標を画面内だけで
// 復元するために使う(worker/src/html.js の refreshExtras 参照)。ここではその使い方どおり、
// 「AがBを見た距離・方位」から作った推定座標が実際のBの座標とほぼ一致することを確認する。
test("destinationPoint: 距離+方位からの推定座標は実際の相手の座標とほぼ一致する(3D/AR統合の前提)", () => {
  const hostReal = { lat: 35.658, lng: 139.7016 };
  const guestReal = { lat: 35.6595, lng: 139.7031 }; // hostから見て北東・約210m
  const brng = bearingDegrees(hostReal.lat, hostReal.lng, guestReal.lat, guestReal.lng);
  const dist = distanceMeters(hostReal.lat, hostReal.lng, guestReal.lat, guestReal.lng);
  const estimatedGuest = destinationPoint(hostReal.lat, hostReal.lng, brng, dist);
  assert.ok(Math.abs(estimatedGuest.lat - guestReal.lat) < 0.0001, `lat mismatch: ${estimatedGuest.lat}`);
  assert.ok(Math.abs(estimatedGuest.lng - guestReal.lng) < 0.0001, `lng mismatch: ${estimatedGuest.lng}`);
});

test("destinationFromOffset: 北50m・東0mは真北50m相当", () => {
  const start = { lat: 35.658, lng: 139.7016 };
  const dest = destinationFromOffset(start.lat, start.lng, 50, 0);
  const b = bearingDegrees(start.lat, start.lng, dest.lat, dest.lng);
  const d = distanceMeters(start.lat, start.lng, dest.lat, dest.lng);
  const wrapDiff = Math.min(Math.abs(b - 0), Math.abs(b - 360)); // 0度は359.999...との浮動小数誤差も許容
  assert.ok(wrapDiff < 0.1, `got bearing ${b}`);
  assert.ok(Math.abs(d - 50) < 0.5, `got distance ${d}`);
});

test("destinationFromOffset: オフセット0は同じ地点", () => {
  const dest = destinationFromOffset(35.658, 139.7016, 0, 0);
  assert.equal(dest.lat, 35.658);
  assert.equal(dest.lng, 139.7016);
});

test("formatDistance: m/km切り替え", () => {
  assert.equal(formatDistance(120), "あと120m");
  assert.equal(formatDistance(999), "あと999m");
  assert.equal(formatDistance(1200), "あと1.2km");
});

test("formatFloor: 地上/地下表記", () => {
  assert.equal(formatFloor(1), "1F");
  assert.equal(formatFloor(3), "3F");
  assert.equal(formatFloor(-1), "B1");
  assert.equal(formatFloor(-2), "B2");
});

test("floorIndicatorText: 上/下/同じ階", () => {
  assert.deepEqual(floorIndicatorText(1, 3), { dir: "up", text: "↑2階上" });
  assert.deepEqual(floorIndicatorText(1, -1), { dir: "down", text: "↓B1" });
  assert.equal(floorIndicatorText(2, 2), null);
});
