/**
 * shibuya-machimachi worker
 *
 * ルーティング:
 *   POST /api/rooms                          待ち合わせを作る(ニックネームのみ)
 *   GET  /api/rooms/:roomId/preview?invite=  招待リンクのプレビュー(参加前)
 *   POST /api/rooms/:roomId/join             招待トークンで参加する
 *   GET  /api/rooms/:roomId/ws?role=&secret= WebSocket接続(以降のやり取りは全てこれ経由)
 *   GET  /                                    紹介LP(トップページ。作成画面ではない)
 *   GET  /new , GET /r/:roomId                スマホ用HTML画面(作成/参加。1枚をパスに関わらず配信)
 *   GET  /privacy , GET /support             プライバシーポリシー・サポート(App Store掲載用)
 *   GET  /.well-known/apple-app-site-association  iOSアプリのユニバーサルリンク設定(招待リンク)
 *   OPTIONS /api/*                           iOSアプリ(capacitor://localhost)からのCORSプリフライト
 *
 * 実体のルーム管理は Durable Object(RoomDO, room-do.js)に委譲する。roomIdはこのWorker側で
 * crypto.randomUUID()由来のランダムな32桁16進文字列として発行し、
 * env.ROOM_DO.idFromName(roomId) で常に同じDOインスタンスに解決する。
 */
import { RoomDO } from "./room-do.js";
import { randomToken } from "./room.js";
import { APP_HTML } from "./html.js";
import { LP_HTML } from "./lp.js";
import { withSecurityHeaders } from "./security-headers.js";
import { PRIVACY_HTML, SUPPORT_HTML } from "./legal.js";
import { appPreflightResponse, withAppCors, appleAppSiteAssociation } from "./app-origin.js";

export { RoomDO };

const ROOM_ID_PATTERN = "[a-f0-9]{32}";
const ROOM_ACTION_RE = new RegExp(`^/api/rooms/(${ROOM_ID_PATTERN})(/(?:preview|join|ws))$`);
const ROOM_PAGE_RE = new RegExp(`^/r/(${ROOM_ID_PATTERN})$`);

// 部屋作成のレート制限(H3): 同一IP(をハッシュ化した値)につき1分5回まで。
// wrangler.tomlの[[ratelimits]](binding名 ROOM_CREATE_LIMITER)で設定する。
const ROOM_CREATE_RATE_LIMIT_MESSAGE = "しばらく時間をおいてから、もう一度お試しください。";

// cf-connecting-ipそのものをレートリミッタのキーやログに残さないようにSHA-256でハッシュ化する。
// Workers Runtime・Node.js 20+のどちらもWeb Crypto(globalThis.crypto.subtle)を持つ。
export async function hashClientIp(ip) {
  const data = new TextEncoder().encode(ip || "unknown");
  const digest = await crypto.subtle.digest("SHA-256", data);
  return Array.from(new Uint8Array(digest))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

// 意図的な簡略化: env.ROOM_CREATE_LIMITER(Rate Limiting binding)が存在しない環境
// (bindingを構成していないローカル実行・単体テストのfake env等)ではレート制限を素通しする。
// 本番のwrangler.tomlには必ずbindingを定義してあるので、ここに来るのは開発/テスト時のみ。
export async function isRateLimited(env, key) {
  if (!env.ROOM_CREATE_LIMITER || typeof env.ROOM_CREATE_LIMITER.limit !== "function") return false;
  const { success } = await env.ROOM_CREATE_LIMITER.limit({ key });
  return !success;
}

function json(data, status = 200) {
  return new Response(JSON.stringify(data), {
    status,
    headers: { "content-type": "application/json; charset=utf-8" },
  });
}

function getStub(env, roomId) {
  return env.ROOM_DO.get(env.ROOM_DO.idFromName(roomId));
}

async function forwardToRoom(env, roomId, path, request) {
  const stub = getStub(env, roomId);
  const url = new URL(request.url);
  const target = new URL(path + url.search, "https://room.internal");
  const init = { method: request.method, headers: request.headers };
  if (request.method !== "GET" && request.method !== "HEAD") init.body = request.body;
  return stub.fetch(new Request(target, init));
}

async function handleCreateRoom(request, env) {
  const ip = request.headers.get("cf-connecting-ip") || "unknown";
  const key = await hashClientIp(ip);
  if (await isRateLimited(env, key)) {
    return json({ ok: false, reason: "rate_limited", message: ROOM_CREATE_RATE_LIMIT_MESSAGE }, 429);
  }

  const body = await request.json().catch(() => null);
  if (!body || typeof body.nickname !== "string" || !body.nickname.trim()) {
    return json({ ok: false, reason: "invalid_nickname" }, 400);
  }
  const roomId = randomToken();
  const stub = getStub(env, roomId);
  const initRequest = new Request("https://room.internal/init", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ roomId, hostNickname: body.nickname }),
  });
  return stub.fetch(initRequest);
}

function html(body) {
  return new Response(body, { headers: { "content-type": "text/html; charset=utf-8" } });
}

// 静的なHTMLページ(GETのみ)。App Storeの掲載情報から参照される。
const STATIC_PAGES = Object.freeze({ "/privacy": PRIVACY_HTML, "/support": SUPPORT_HTML });

async function route(request, env) {
  const url = new URL(request.url);

  // iOSアプリ(許可オリジンのみ)からの /api/* プリフライト。許可外は従来どおり404へ進む。
  const preflight = appPreflightResponse(request);
  if (preflight) return preflight;

  if (url.pathname === "/api/rooms" && request.method === "POST") {
    return handleCreateRoom(request, env);
  }

  const roomMatch = url.pathname.match(ROOM_ACTION_RE);
  if (roomMatch) {
    const roomId = roomMatch[1];
    const action = roomMatch[2];
    return forwardToRoom(env, roomId, action, request);
  }

  if (request.method === "GET" && (url.pathname === "/new" || ROOM_PAGE_RE.test(url.pathname))) {
    return html(APP_HTML);
  }

  if (request.method === "GET" && Object.hasOwn(STATIC_PAGES, url.pathname)) {
    return html(STATIC_PAGES[url.pathname]);
  }

  if (request.method === "GET" && url.pathname === "/.well-known/apple-app-site-association") {
    return json(appleAppSiteAssociation());
  }

  // トップページ("/")は作成画面ではなく紹介LP。「待ち合わせを作る」ボタンから/newへ誘導する。
  if (request.method === "GET" && url.pathname === "/") {
    return html(LP_HTML);
  }

  return json({ error: "not found" }, 404);
}

export default {
  // セキュリティヘッダ(H1/M5)はここで一元的に付与する。WebSocketアップグレード(101)は
  // withSecurityHeaders内部で素通しされる。iOSアプリ(許可オリジンのみ)向けのCORSヘッダは
  // /api/* の応答にだけ withAppCors で追加する(101はこちらも素通し)。
  async fetch(request, env) {
    const response = await route(request, env);
    return withAppCors(request, withSecurityHeaders(response));
  },
};
