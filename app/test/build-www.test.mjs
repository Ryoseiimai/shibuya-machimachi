// アプリ同梱の index.html を組み立てる処理(app/scripts/build-www.mjs)の単体テスト。
import { test } from "node:test";
import assert from "node:assert/strict";
import { buildIndexHtml, API_BASE } from "../scripts/build-www.mjs";

const html = buildIndexHtml();

test("通信先は本番Worker(https)で、招待リンクもそのオリジンになる", () => {
  assert.equal(API_BASE, "https://shibuya-machimachi.kaeru3160.workers.dev");
  assert.ok(html.includes(`<meta name="api-base" content="${API_BASE}">`));
});

test("CSP: script-srcに'unsafe-inline'/'unsafe-eval'を入れず、通信先は本番Workerと地図の配信元だけ", () => {
  const m = html.match(/<meta http-equiv="Content-Security-Policy" content="([^"]+)">/);
  assert.ok(m, "CSPのmetaがある");
  const csp = m[1];
  const scriptSrc = csp.match(/script-src ([^;]+)/)[1].trim().split(/\s+/);
  assert.ok(!scriptSrc.includes("'unsafe-inline'"));
  assert.ok(!scriptSrc.includes("'unsafe-eval'"));
  const connect = csp.match(/connect-src ([^;]+)/)[1].trim().split(/\s+/);
  assert.deepEqual(connect.sort(), [
    "'self'", "blob:", API_BASE, API_BASE.replace("https:", "wss:"),
    "https://cyberjapandata.gsi.go.jp", "https://assets.cms.plateau.reearth.io",
  ].sort());
});

test("native-bridge.js を app.js より前に同期で読み、demo.js も読み込む", () => {
  const bridge = html.indexOf('<script src="/app/native-bridge.js"></script>');
  const demo = html.indexOf('<script src="/app/demo.js" defer></script>');
  const app = html.indexOf('<script src="/assets/js/app.js" defer></script>');
  assert.ok(bridge > 0 && demo > bridge && app > demo);
});

test("アプリ用CSSは元の<style>より後(body{padding:0}に負けない位置)", () => {
  assert.ok(html.indexOf('<link rel="stylesheet" href="/app/app.css">') > html.indexOf("</style>"));
});

test("作成画面に「デモで試す」ボタンがある", () => {
  assert.ok(html.includes('id="demo-btn"'));
});
