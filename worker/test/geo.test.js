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
