import { test } from "node:test";
import assert from "node:assert/strict";
import { FLOORS, isValidFloor, floorDiff, floorDiffLabel, sameFloor } from "../src/floors.js";

test("FLOORS: B5から10Fまで15段ある", () => {
  assert.equal(FLOORS.length, 15);
  assert.equal(FLOORS[0], "B5");
  assert.equal(FLOORS[FLOORS.length - 1], "10F");
});

test("isValidFloor: 一覧にあるものだけtrue", () => {
  assert.equal(isValidFloor("3F"), true);
  assert.equal(isValidFloor("B1"), true);
  assert.equal(isValidFloor("11F"), false);
  assert.equal(isValidFloor(""), false);
  assert.equal(isValidFloor(null), false);
});

test("floorDiff: 相手が2つ上なら+2", () => {
  assert.equal(floorDiff("1F", "3F"), 2);
});

test("floorDiff: 相手が2つ下なら-2", () => {
  assert.equal(floorDiff("3F", "1F"), -2);
});

test("floorDiff: 未設定ならnull", () => {
  assert.equal(floorDiff(null, "3F"), null);
  assert.equal(floorDiff("3F", undefined), null);
});

test("floorDiffLabel: 上下と同階の文言", () => {
  assert.equal(floorDiffLabel("1F", "3F"), "相手は2つ上の階にいます");
  assert.equal(floorDiffLabel("3F", "1F"), "相手は2つ下の階にいます");
  assert.equal(floorDiffLabel("3F", "3F"), "相手は同じ階にいます");
});

test("sameFloor: B1とB1はtrue、B1と1Fはfalse", () => {
  assert.equal(sameFloor("B1", "B1"), true);
  assert.equal(sameFloor("B1", "1F"), false);
});
