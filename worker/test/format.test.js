import { test } from "node:test";
import assert from "node:assert/strict";
import { formatRelativeTime } from "../src/format.js";

test("formatRelativeTime: 秒・分・時間・日の相対表示", () => {
  const now = 1_000_000;
  assert.equal(formatRelativeTime(now - 3_000, now), "3秒前");
  assert.equal(formatRelativeTime(now - 60_000, now), "1分前");
  assert.equal(formatRelativeTime(now - 3_600_000, now), "1時間前");
  assert.equal(formatRelativeTime(now - 86_400_000, now), "1日前");
});

test("formatRelativeTime: 未来時刻は0秒前、不正な時刻は不明", () => {
  assert.equal(formatRelativeTime(2_000, 1_000), "0秒前");
  assert.equal(formatRelativeTime("not a timestamp", 1_000), "不明");
});
