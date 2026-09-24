import { test } from "node:test";
import assert from "node:assert/strict";
import { distanceMeters, bearingDegrees, isWithinRadius } from "../src/geo.js";
import { SHIBUYA_STATION, SHIBUYA_RADIUS_M } from "../src/constants.js";

test("distanceMeters: 同じ地点なら距離は0", () => {
  const d = distanceMeters(35.6580, 139.7016, 35.6580, 139.7016);
  assert.equal(Math.round(d), 0);
});

test("distanceMeters: 渋谷駅-新宿駅は約3.3km", () => {
  const d = distanceMeters(35.6580, 139.7016, 35.6896, 139.7006);
  assert.ok(d > 3000 && d < 3700, `expected ~3-3.7km, got ${d}`);
});

test("distanceMeters: 緯度1度分はおよそ111.32km", () => {
  const d = distanceMeters(35.0, 139.0, 36.0, 139.0);
  assert.ok(Math.abs(d - 111320) < 1000, `expected ~111320m, got ${d}`);
});

test("bearingDegrees: 真北はおよそ0度", () => {
  const b = bearingDegrees(35.0, 139.0, 35.01, 139.0);
  assert.ok(b < 1 || b > 359, `expected ~0deg, got ${b}`);
});

test("bearingDegrees: 真東はおよそ90度", () => {
  const b = bearingDegrees(35.0, 139.0, 35.0, 139.01);
  assert.ok(Math.abs(b - 90) < 1, `expected ~90deg, got ${b}`);
});

test("bearingDegrees: 真南はおよそ180度", () => {
  const b = bearingDegrees(35.0, 139.0, 34.99, 139.0);
  assert.ok(Math.abs(b - 180) < 1, `expected ~180deg, got ${b}`);
});

test("bearingDegrees: 真西はおよそ270度", () => {
  const b = bearingDegrees(35.0, 139.0, 35.0, 138.99);
  assert.ok(Math.abs(b - 270) < 1, `expected ~270deg, got ${b}`);
});

test("isWithinRadius: 渋谷駅ちょうどはtrue", () => {
  assert.equal(isWithinRadius(SHIBUYA_STATION.lat, SHIBUYA_STATION.lng, SHIBUYA_STATION.lat, SHIBUYA_STATION.lng, SHIBUYA_RADIUS_M), true);
});

test("isWithinRadius: 新宿駅(渋谷から約3.3km)はfalse(半径1.5km)", () => {
  assert.equal(isWithinRadius(35.6896, 139.7006, SHIBUYA_STATION.lat, SHIBUYA_STATION.lng, SHIBUYA_RADIUS_M), false);
});

test("isWithinRadius: 渋谷駅から500m程度の地点はtrue", () => {
  // 緯度方向に約0.0045度(約500m)ずらした地点
  assert.equal(isWithinRadius(SHIBUYA_STATION.lat + 0.0045, SHIBUYA_STATION.lng, SHIBUYA_STATION.lat, SHIBUYA_STATION.lng, SHIBUYA_RADIUS_M), true);
});

// 3D渋谷/AR部品の統合で、AがBを指す矢印・ピンとBがAを指す矢印・ピンが正しく
// 逆向き(お互いを向き合う形)になっていることの前提を確認する。渋谷駅から半径1.5km圏内
// (最大でも直径3km程度)なら、往復方位のズレは球面の丸みによる誤差だけなので1度未満のはず。
test("bearingDegrees: AからB・BからAの方位は約180度反対(渋谷エリア内の距離感で)", () => {
  const A = { lat: SHIBUYA_STATION.lat, lng: SHIBUYA_STATION.lng }; // 渋谷駅(ホスト役)
  const B = { lat: SHIBUYA_STATION.lat + 0.012, lng: SHIBUYA_STATION.lng + 0.010 }; // 約1.4km北東(ゲスト役)
  const aToB = bearingDegrees(A.lat, A.lng, B.lat, B.lng);
  const bToA = bearingDegrees(B.lat, B.lng, A.lat, A.lng);
  // aToBとbToAの差を(-180, 180]に正規化してから、その絶対値が180にどれだけ近いかを見る
  // (差そのものが+180付近と-180付近のどちらに出ても同じ意味になるようにするため)。
  const normalizedDiff = ((aToB - bToA + 540) % 360) - 180;
  const diffFrom180 = Math.abs(Math.abs(normalizedDiff) - 180);
  assert.ok(diffFrom180 < 1, `expected ~180deg apart, got aToB=${aToB} bToA=${bToA} (diff from 180: ${diffFrom180})`);
});
