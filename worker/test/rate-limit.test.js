// H3セキュリティ対応: 部屋作成(POST /api/rooms)のレート制限の単体テスト。
// 実際のCloudflare Rate Limiting bindingはローカルNode実行では使えないため、
// env.ROOM_CREATE_LIMITER をフェイクして isRateLimited() / hashClientIp() /
// handleCreateRoom経由の429応答を検証する。
import { test } from "node:test";
import assert from "node:assert/strict";
import { hashClientIp, isRateLimited } from "../src/index.js";
import worker from "../src/index.js";

test("hashClientIp: 同じIPは常に同じハッシュ、違うIPは違うハッシュ(SHA-256 hex 64文字)", async () => {
  const a1 = await hashClientIp("203.0.113.1");
  const a2 = await hashClientIp("203.0.113.1");
  const b = await hashClientIp("203.0.113.2");
  assert.equal(a1, a2);
  assert.notEqual(a1, b);
  assert.match(a1, /^[0-9a-f]{64}$/, "SHA-256の16進数64文字");
  assert.ok(!a1.includes("203.0.113.1"), "ハッシュ値に生IPの文字列が現れない");
});

test("isRateLimited: bindingがsuccess:falseを返せば制限中と判定する", async () => {
  const env = { ROOM_CREATE_LIMITER: { limit: async () => ({ success: false }) } };
  assert.equal(await isRateLimited(env, "some-key"), true);
});

test("isRateLimited: bindingがsuccess:trueを返せば制限されていない", async () => {
  const env = { ROOM_CREATE_LIMITER: { limit: async () => ({ success: true }) } };
  assert.equal(await isRateLimited(env, "some-key"), false);
});

// 意図的な簡略化: bindingが存在しない環境(ローカル実行の一部構成等)ではレート制限を素通しする。
test("isRateLimited: bindingが無い環境ではfalse(素通し)を返す", async () => {
  assert.equal(await isRateLimited({}, "some-key"), false);
});

test("POST /api/rooms: レート制限中は429と日本語メッセージを返し、部屋は作られない", async () => {
  let limitCalls = 0;
  const env = {
    ROOM_CREATE_LIMITER: {
      limit: async () => {
        limitCalls += 1;
        return { success: false };
      },
    },
    // ROOM_DOに触れないことを確認するため、呼ばれたら失敗させる
    ROOM_DO: {
      idFromName: () => {
        throw new Error("ROOM_DOに到達してはいけない(レート制限で弾かれるはず)");
      },
    },
  };
  const request = new Request("https://shibuya-machimachi.example/api/rooms", {
    method: "POST",
    headers: { "content-type": "application/json", "cf-connecting-ip": "203.0.113.9" },
    body: JSON.stringify({ nickname: "テスト太郎" }),
  });

  const res = await worker.fetch(request, env);
  assert.equal(res.status, 429);
  const body = await res.json();
  assert.equal(body.ok, false);
  assert.equal(body.reason, "rate_limited");
  assert.match(body.message, /しばらく時間をおいて/);
  assert.equal(limitCalls, 1);
});

test("POST /api/rooms: レート制限に掛からなければ通常どおり作成に進む", async () => {
  const env = {
    ROOM_CREATE_LIMITER: { limit: async () => ({ success: true }) },
    ROOM_DO: {
      idFromName: (name) => ({ name }),
      get: (id) => ({
        fetch: async () =>
          new Response(JSON.stringify({ ok: true, roomId: "abc", hostSecret: "s", inviteToken: "t" }), {
            headers: { "content-type": "application/json" },
          }),
      }),
    },
  };
  const request = new Request("https://shibuya-machimachi.example/api/rooms", {
    method: "POST",
    headers: { "content-type": "application/json", "cf-connecting-ip": "203.0.113.10" },
    body: JSON.stringify({ nickname: "テスト花子" }),
  });

  const res = await worker.fetch(request, env);
  assert.equal(res.status, 200);
  const body = await res.json();
  assert.equal(body.ok, true);
});
