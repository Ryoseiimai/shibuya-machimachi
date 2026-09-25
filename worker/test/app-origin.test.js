// iOSアプリ向けの受け口(CORSの許可オリジン・ユニバーサルリンク)と、App Store掲載用の
// /privacy・/support ページの単体テスト。
import { test } from "node:test";
import assert from "node:assert/strict";
import worker from "../src/index.js";
import {
  APP_ORIGINS,
  isAllowedAppOrigin,
  withAppCors,
  appleAppSiteAssociation,
} from "../src/app-origin.js";
import { CONTENT_SECURITY_POLICY } from "../src/security-headers.js";

const BASE = "https://shibuya-machimachi.example";
const APP_ORIGIN = "capacitor://localhost";
const OTHER_ORIGIN = "https://evil.example";

// ROOM_DOに到達したら結果が分かるようにする(作成成功のダミー応答を返す)。
function fakeEnv() {
  return {
    ROOM_CREATE_LIMITER: { limit: async () => ({ success: true }) },
    ROOM_DO: {
      idFromName: (name) => ({ name }),
      get: () => ({
        fetch: async () =>
          new Response(JSON.stringify({ ok: true, roomId: "abc", hostSecret: "s", inviteToken: "t" }), {
            headers: { "content-type": "application/json" },
          }),
      }),
    },
  };
}

test("許可オリジンはアプリのcapacitor://localhostだけ(ワイルドカードや任意のhttpsは不可)", () => {
  assert.deepEqual([...APP_ORIGINS], [APP_ORIGIN]);
  assert.equal(isAllowedAppOrigin(APP_ORIGIN), true);
  assert.equal(isAllowedAppOrigin(OTHER_ORIGIN), false);
  assert.equal(isAllowedAppOrigin("*"), false);
  assert.equal(isAllowedAppOrigin(null), false);
  assert.equal(isAllowedAppOrigin("capacitor://localhost.evil.example"), false);
});

test("OPTIONS /api/rooms: アプリのオリジンには204とCORSヘッダを返す", async () => {
  const req = new Request(`${BASE}/api/rooms`, {
    method: "OPTIONS",
    headers: { Origin: APP_ORIGIN, "Access-Control-Request-Method": "POST", "Access-Control-Request-Headers": "content-type" },
  });
  const res = await worker.fetch(req, fakeEnv());
  assert.equal(res.status, 204);
  assert.equal(res.headers.get("Access-Control-Allow-Origin"), APP_ORIGIN);
  assert.match(res.headers.get("Access-Control-Allow-Methods"), /POST/);
  assert.match(res.headers.get("Access-Control-Allow-Headers"), /Content-Type/i);
  assert.equal(res.headers.get("Vary"), "Origin", "Vary: Origin は1回だけ");
});

test("OPTIONS /api/rooms: 許可外のオリジンには従来どおり404でCORSヘッダを付けない", async () => {
  const req = new Request(`${BASE}/api/rooms`, { method: "OPTIONS", headers: { Origin: OTHER_ORIGIN } });
  const res = await worker.fetch(req, fakeEnv());
  assert.equal(res.status, 404);
  assert.equal(res.headers.get("Access-Control-Allow-Origin"), null);
});

test("POST /api/rooms: アプリのオリジンの応答にだけAccess-Control-Allow-Originが付く", async () => {
  const make = (origin) =>
    new Request(`${BASE}/api/rooms`, {
      method: "POST",
      headers: { "content-type": "application/json", Origin: origin, "cf-connecting-ip": "203.0.113.5" },
      body: JSON.stringify({ nickname: "テスト" }),
    });
  const fromApp = await worker.fetch(make(APP_ORIGIN), fakeEnv());
  assert.equal(fromApp.status, 200);
  assert.equal(fromApp.headers.get("Access-Control-Allow-Origin"), APP_ORIGIN);
  // セキュリティヘッダは従来どおり付いている(CORS追加でCSP等が落ちない)
  assert.equal(fromApp.headers.get("Content-Security-Policy"), CONTENT_SECURITY_POLICY);

  const fromOther = await worker.fetch(make(OTHER_ORIGIN), fakeEnv());
  assert.equal(fromOther.status, 200);
  assert.equal(fromOther.headers.get("Access-Control-Allow-Origin"), null);
});

test("/api以外(LPなど)にはアプリのオリジンでもCORSヘッダを付けない", async () => {
  const res = await worker.fetch(new Request(`${BASE}/`, { headers: { Origin: APP_ORIGIN } }), fakeEnv());
  assert.equal(res.status, 200);
  assert.equal(res.headers.get("Access-Control-Allow-Origin"), null);
});

test("withAppCors: status 101(WebSocketアップグレード)は作り直さずに素通しする", () => {
  const fakeUpgrade = { status: 101, headers: new Headers() };
  const req = new Request(`${BASE}/api/rooms/${"a".repeat(32)}/ws`, { headers: { Origin: APP_ORIGIN } });
  assert.equal(withAppCors(req, fakeUpgrade), fakeUpgrade);
});

test("GET /.well-known/apple-app-site-association: 招待リンク(/r/*)だけをアプリに渡すJSON", async () => {
  const res = await worker.fetch(new Request(`${BASE}/.well-known/apple-app-site-association`), fakeEnv());
  assert.equal(res.status, 200);
  assert.match(res.headers.get("content-type"), /application\/json/);
  const body = await res.json();
  assert.deepEqual(body, appleAppSiteAssociation());
  const detail = body.applinks.details[0];
  assert.deepEqual(detail.appIDs, ["X72629Z4T6.jp.co.ryoseiworld.shibuyamachimachi"]);
  assert.deepEqual(
    detail.components.map((c) => c["/"]),
    ["/r/*"],
  );
});

for (const [path, mustInclude] of [
  ["/privacy", ["プライバシーポリシー", "Privacy Policy", "3時間", "座標", "kaeru3160@gmail.com"]],
  ["/support", ["サポート", "Support", "デモで試す", "kaeru3160@gmail.com"]],
]) {
  test(`GET ${path}: 日本語+英語のHTMLを返し、scriptを含まずセキュリティヘッダが付く`, async () => {
    const res = await worker.fetch(new Request(`${BASE}${path}`), fakeEnv());
    assert.equal(res.status, 200);
    assert.match(res.headers.get("content-type"), /text\/html/);
    assert.equal(res.headers.get("Content-Security-Policy"), CONTENT_SECURITY_POLICY);
    const text = await res.text();
    for (const s of mustInclude) assert.ok(text.includes(s), `${path} に「${s}」が含まれる`);
    assert.ok(!/<script/i.test(text), `${path} は<script>を含まない`);
  });
}

test("プライバシーポリシーに座標の数値やAPIキーのような秘密が紛れ込んでいない", async () => {
  const res = await worker.fetch(new Request(`${BASE}/privacy`), fakeEnv());
  const text = await res.text();
  assert.ok(!/\b35\.\d{3,}/.test(text), "緯度らしき数値を含まない");
  assert.ok(!/\b139\.\d{3,}/.test(text), "経度らしき数値を含まない");
  assert.ok(!/JEV_API_KEY|sk-[A-Za-z0-9]{10,}/.test(text), "秘密情報を含まない");
});
