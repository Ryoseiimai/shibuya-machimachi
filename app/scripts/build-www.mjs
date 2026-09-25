// iOSアプリに同梱する画面一式(app/www)を worker/ の正本から組み立てる。
//   - index.html: worker/src/html.js の APP_HTML に、アプリ用の設定(通信先・CSP)と
//                 アプリ専用スクリプト(native-bridge.js / demo.js)を差し込んだもの
//   - assets/, vendor/: worker/public/ の3D渋谷・AR・地図データ・ライブラリをそのままコピー
//   - app/: app/src/ のアプリ専用ファイル
// 画面はすべてアプリ内から読み込み、通信(API/WebSocket)だけ本番Workerへ行く。
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { APP_HTML } from "../../worker/src/html.js";

const APP_DIR = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const WORKER_PUBLIC = path.join(APP_DIR, "..", "worker", "public");
const OUT = path.join(APP_DIR, "www");

// 本番Worker(通信先)。招待リンクもこのオリジンのURLで作る(アプリが無い相手もブラウザで開ける)。
export const API_BASE = "https://shibuya-machimachi.kaeru3160.workers.dev";
const API_WS = API_BASE.replace(/^https:/, "wss:");

// 同梱ページのCSP。worker/src/security-headers.js の方針を踏襲し、通信先に本番Workerを足しただけ
// (frame-ancestors は <meta> では無効なので載せない)。
const APP_CSP = [
  "default-src 'self'",
  "script-src 'self' 'wasm-unsafe-eval'",
  "style-src 'self' 'unsafe-inline'",
  "img-src 'self' data: blob: https://cyberjapandata.gsi.go.jp",
  `connect-src 'self' blob: ${API_BASE} ${API_WS} https://cyberjapandata.gsi.go.jp https://assets.cms.plateau.reearth.io`,
  "worker-src 'self' blob:",
  "font-src 'self'",
  "object-src 'none'",
  "base-uri 'self'",
  "form-action 'self'",
].join("; ");

function replaceOnce(html, from, to) {
  if (!html.includes(from)) throw new Error(`build-www: 置換元が見つかりません: ${from.slice(0, 80)}`);
  return html.replace(from, to);
}

export function buildIndexHtml(appHtml = APP_HTML) {
  let html = appHtml;
  html = replaceOnce(
    html,
    '<meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, viewport-fit=cover">',
    '<meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, viewport-fit=cover, user-scalable=no">\n' +
      `<meta http-equiv="Content-Security-Policy" content="${APP_CSP}">\n` +
      `<meta name="api-base" content="${API_BASE}">`,
  );
  // アプリ用CSSは元の<style>より後に置く(同じ詳細度のbody{padding:0}に上書きされないように)
  html = replaceOnce(html, "</head>", '<link rel="stylesheet" href="/app/app.css">\n</head>');
  // 作成画面に「デモで試す」(1台で相手の動きを模擬して体験する。審査・初見の人向け)
  html = replaceOnce(
    html,
    '<p class="hint">アカウント登録は不要です。作った待ち合わせは3時間で自動的に終了します。</p>',
    '<p class="hint">アカウント登録は不要です。作った待ち合わせは3時間で自動的に終了します。</p>\n' +
      '      <button type="button" id="demo-btn" class="secondary demo-btn">デモで試す（1台で体験）</button>\n' +
      '      <p class="hint">デモでは、模擬の相手が渋谷駅前であなたに近づいてきます。位置情報は使わず、何も送信しません。</p>',
  );
  // app.js の前に native-bridge.js(同期)と demo.js を読む。版の印(?v=)はアプリ同梱なので不要。
  html = html.replace(
    /<script src="\/assets\/js\/app\.js\?v=[^"]*" defer><\/script>/,
    '<script src="/app/native-bridge.js"></script>\n<script src="/app/demo.js" defer></script>\n<script src="/assets/js/app.js" defer></script>',
  );
  if (!html.includes('src="/app/native-bridge.js"')) throw new Error("build-www: app.js の script タグを差し替えられませんでした");
  return html;
}

function copyDir(src, dest) {
  fs.cpSync(src, dest, { recursive: true, dereference: true });
}

function main() {
  fs.rmSync(OUT, { recursive: true, force: true });
  fs.mkdirSync(OUT, { recursive: true });
  copyDir(path.join(WORKER_PUBLIC, "assets"), path.join(OUT, "assets"));
  copyDir(path.join(WORKER_PUBLIC, "vendor"), path.join(OUT, "vendor"));
  copyDir(path.join(APP_DIR, "src"), path.join(OUT, "app"));
  fs.writeFileSync(path.join(OUT, "index.html"), buildIndexHtml());
  console.log(`build-www: ${OUT} を生成しました`);
}

if (process.argv[1] && fileURLToPath(import.meta.url) === path.resolve(process.argv[1])) main();
