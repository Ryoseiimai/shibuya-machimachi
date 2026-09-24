// H1/M5セキュリティ対応: セキュリティヘッダの単体テスト。
import { test } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { SECURITY_HEADERS, CONTENT_SECURITY_POLICY, withSecurityHeaders } from "../src/security-headers.js";
import worker from "../src/index.js";

const __dirname = path.dirname(fileURLToPath(import.meta.url));

test("SECURITY_HEADERS: 必須ヘッダが正しい値で揃っている", () => {
  assert.equal(SECURITY_HEADERS["X-Frame-Options"], "DENY");
  assert.equal(SECURITY_HEADERS["X-Content-Type-Options"], "nosniff");
  assert.equal(SECURITY_HEADERS["Referrer-Policy"], "no-referrer");
  assert.equal(SECURITY_HEADERS["Permissions-Policy"], "geolocation=(self), camera=(self)");
  assert.match(SECURITY_HEADERS["Strict-Transport-Security"], /max-age=\d+/);
});

test("CSP: frame-ancestors 'none' を含み、script-srcに'unsafe-inline'を含まない", () => {
  assert.match(CONTENT_SECURITY_POLICY, /frame-ancestors 'none'/);
  const scriptSrcMatch = CONTENT_SECURITY_POLICY.match(/script-src ([^;]+)/);
  assert.ok(scriptSrcMatch, "script-srcディレクティブが存在する");
  assert.ok(!scriptSrcMatch[1].includes("unsafe-inline"), "script-srcにunsafe-inlineを含んではいけない");
  assert.ok(!scriptSrcMatch[1].includes("unsafe-eval"), "script-srcにunsafe-evalを含んではいけない");
});

test("CSP: 3D渋谷/ARに必要な許可先(地理院タイル・blob worker)が入っている", () => {
  assert.match(CONTENT_SECURITY_POLICY, /img-src[^;]*https:\/\/cyberjapandata\.gsi\.go\.jp/);
  assert.match(CONTENT_SECURITY_POLICY, /connect-src[^;]*https:\/\/cyberjapandata\.gsi\.go\.jp/);
  assert.match(CONTENT_SECURITY_POLICY, /worker-src[^;]*blob:/);
});

test("withSecurityHeaders: 通常のレスポンスには全ヘッダが付与される", () => {
  const original = new Response("hello", { status: 200 });
  const wrapped = withSecurityHeaders(original);
  for (const [key, value] of Object.entries(SECURITY_HEADERS)) {
    assert.equal(wrapped.headers.get(key), value, `header ${key}`);
  }
});

test("withSecurityHeaders: status 101(WebSocketアップグレード)は素通しして加工しない", () => {
  // Node標準のResponseはstatus 101を許可しないため、withSecurityHeaders内部が
  // new Response()を呼ばずに早期returnしていることを、渡したオブジェクトそのものが
  // 変更されずに返る(===で同一)ことで確認する。
  const fakeUpgradeResponse = { status: 101, headers: new Headers() };
  const result = withSecurityHeaders(fakeUpgradeResponse);
  assert.equal(result, fakeUpgradeResponse, "101はオブジェクトをそのまま返す(作り直さない)");
});

test("worker/public/_headers のCSPは security-headers.js のCONTENT_SECURITY_POLICYと完全一致する", () => {
  const headersPath = path.join(__dirname, "..", "public", "_headers");
  const content = fs.readFileSync(headersPath, "utf8");
  const cspLines = content
    .split("\n")
    .filter((line) => line.trim().startsWith("Content-Security-Policy:"))
    .map((line) => line.trim().slice("Content-Security-Policy:".length).trim());
  assert.ok(cspLines.length >= 1, "_headersにContent-Security-Policy行が存在する");
  for (const line of cspLines) {
    assert.equal(line, CONTENT_SECURITY_POLICY, "_headersのCSPとJS側のCSPがズレている");
  }
});

test("GET / の実レスポンスにセキュリティヘッダが付いている(index.jsのfetch統合)", async () => {
  const request = new Request("https://shibuya-machimachi.example/");
  const res = await worker.fetch(request, {});
  assert.equal(res.status, 200);
  assert.equal(res.headers.get("X-Frame-Options"), "DENY");
  assert.equal(res.headers.get("Content-Security-Policy"), CONTENT_SECURITY_POLICY);
});

test("存在しないパス(404)にもセキュリティヘッダが付いている", async () => {
  const request = new Request("https://shibuya-machimachi.example/no-such-path");
  const res = await worker.fetch(request, {});
  assert.equal(res.status, 404);
  assert.equal(res.headers.get("X-Content-Type-Options"), "nosniff");
});
