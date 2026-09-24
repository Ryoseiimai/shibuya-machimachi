import { test } from "node:test";
import assert from "node:assert/strict";
import {
  buildJevPayload,
  buildMeetContext,
  callJev,
  distanceOnlyJudge,
  JEV_API_ENDPOINT,
  JEV_MODEL,
} from "../src/jev.js";

test("buildMeetContext: 座標もニックネームも含まない", () => {
  const ctx = buildMeetContext({ distance_m: 12, floorMatch: true, waitingMinutes: 5 });
  assert.match(ctx, /約12m/);
  assert.match(ctx, /同じ階にいる: はい/);
  assert.doesNotMatch(ctx, /\d{2}\.\d+,\s*\d{3}\.\d+/); // 緯度経度らしき数値パターンが無いこと
});

test("buildJevPayload: SKILL.md仕様どおりのnoul質問を1つ組み立てる", () => {
  const payload = buildJevPayload("state-text");
  assert.equal(payload.model, JEV_MODEL);
  assert.equal(payload.state, "state-text");
  assert.equal(payload.questions.met.type, "noul");
  assert.equal(typeof payload.questions.met.instructions, "string");
});

test("callJev: noul>=0.5ならfound=true、APIキーはAuthorizationヘッダに乗る", async () => {
  let capturedInit = null;
  const fakeFetch = async (url, init) => {
    capturedInit = init;
    assert.equal(url, JEV_API_ENDPOINT);
    return {
      ok: true,
      json: async () => ({ answers: { met: { type: "noul", noul: 0.87 } } }),
    };
  };
  const result = await callJev("secret-key", "state-text", fakeFetch);
  assert.equal(result.found, true);
  assert.equal(result.probability, 0.87);
  assert.equal(result.source, "jev");
  assert.equal(capturedInit.headers.Authorization, "Bearer secret-key");
});

test("callJev: noul<0.5ならfound=false", async () => {
  const fakeFetch = async () => ({ ok: true, json: async () => ({ answers: { met: { type: "noul", noul: 0.2 } } }) });
  const result = await callJev("k", "s", fakeFetch);
  assert.equal(result.found, false);
});

test("callJev: HTTPエラーは例外になる", async () => {
  const fakeFetch = async () => ({ ok: false, status: 500, text: async () => "boom" });
  await assert.rejects(() => callJev("k", "s", fakeFetch));
});

test("distanceOnlyJudge: 20m以内かつ同じ階ならfound=true・probabilityはnull", () => {
  const r = distanceOnlyJudge({ distance_m: 15, floorMatch: true });
  assert.equal(r.found, true);
  assert.equal(r.probability, null);
  assert.equal(r.source, "distance_only");
});

test("distanceOnlyJudge: 階が違えばfound=false", () => {
  const r = distanceOnlyJudge({ distance_m: 5, floorMatch: false });
  assert.equal(r.found, false);
});
