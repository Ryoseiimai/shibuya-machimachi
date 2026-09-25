/**
 * iOSアプリ(Capacitor, repoの app/ 配下)向けの最小限の受け口。
 *
 * 1. CORS: アプリの画面はアプリ内に同梱したHTMLを capacitor://localhost から読み込むため、
 *    本番の /api/* を呼ぶと別オリジン扱いになる。許可するのは APP_ORIGINS に列挙した
 *    アプリのオリジンだけ(ワイルドカード"*"は使わない)。Webブラウザのページが
 *    capacitor:// オリジンを名乗ることはできないので、Web版の安全性は変わらない。
 *    WebSocket(/api/rooms/:id/ws)はCORSの対象外で、認証は従来どおりrole+secretで行う。
 * 2. ユニバーサルリンク: 招待リンク(/r/:roomId?invite=...)をアプリが入っている端末では
 *    アプリで開けるよう、/.well-known/apple-app-site-association を返す。
 */

// 許可するアプリのオリジン。Capacitor iOSの既定(iosScheme="capacitor", hostname="localhost")。
export const APP_ORIGINS = Object.freeze(["capacitor://localhost"]);

// App Store Connectのチーム(個人名義)とBundle ID。apple-app-site-associationのappIDに使う。
export const APPLE_TEAM_ID = "X72629Z4T6";
export const IOS_BUNDLE_ID = "jp.co.ryoseiworld.shibuyamachimachi";

// ユニバーサルリンクでアプリに渡すパス(招待リンクのみ。LPや/newはブラウザのまま)。
export const APP_LINK_PATHS = Object.freeze(["/r/*"]);

const CORS_ALLOW_METHODS = "GET, POST, OPTIONS";
const CORS_ALLOW_HEADERS = "Content-Type";
const CORS_MAX_AGE_SECONDS = "600";
const API_PATH_PREFIX = "/api/";

export function isAllowedAppOrigin(origin) {
  return typeof origin === "string" && APP_ORIGINS.includes(origin);
}

function isApiPath(pathname) {
  return pathname.startsWith(API_PATH_PREFIX);
}

// アプリからの /api/* のプリフライト(OPTIONS)。許可オリジン以外は null を返し、
// 呼び出し側は従来どおりの処理(404)に進む。
export function appPreflightResponse(request) {
  if (request.method !== "OPTIONS") return null;
  const url = new URL(request.url);
  if (!isApiPath(url.pathname)) return null;
  const origin = request.headers.get("Origin");
  if (!isAllowedAppOrigin(origin)) return null;
  return new Response(null, {
    status: 204,
    headers: {
      "Access-Control-Allow-Origin": origin,
      "Access-Control-Allow-Methods": CORS_ALLOW_METHODS,
      "Access-Control-Allow-Headers": CORS_ALLOW_HEADERS,
      "Access-Control-Max-Age": CORS_MAX_AGE_SECONDS,
      Vary: "Origin",
    },
  });
}

// 許可オリジンからの /api/* の応答にだけ Access-Control-Allow-Origin を付ける。
// WebSocketアップグレード(101)は security-headers.js と同じ理由で作り直さずに素通しする。
export function withAppCors(request, response) {
  if (!response || response.status === 101) return response;
  const url = new URL(request.url);
  if (!isApiPath(url.pathname)) return response;
  const origin = request.headers.get("Origin");
  if (!isAllowedAppOrigin(origin)) return response;
  const headers = new Headers(response.headers);
  headers.set("Access-Control-Allow-Origin", origin);
  headers.append("Vary", "Origin");
  return new Response(response.body, { status: response.status, statusText: response.statusText, headers });
}

// https://developer.apple.com/documentation/xcode/supporting-associated-domains
export function appleAppSiteAssociation() {
  const appId = `${APPLE_TEAM_ID}.${IOS_BUNDLE_ID}`;
  return {
    applinks: {
      details: [
        {
          appIDs: [appId],
          components: APP_LINK_PATHS.map((path) => ({ "/": path, comment: "招待リンク" })),
        },
      ],
    },
  };
}
