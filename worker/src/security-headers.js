/**
 * 全レスポンス(WebSocketアップグレードの101を除く)に付与するセキュリティヘッダ。
 * 静的アセット(/assets/*)側は Workers Static Assets の _headers ファイル
 * (worker/public/_headers)で同じ値を別途設定している。CSP文字列は2箇所で
 * 完全一致させる必要があり、test/security-headers.test.js がそのズレを検出する。
 *
 * CSPの各許可はすべて3D渋谷(MapLibre GL, worker/public/vendor/に自ホスト)・
 * AR(three.js, 同じくvendor自ホスト)・地理院タイルのために最小限だけ広げている:
 *   - script-src 'self'のみ('unsafe-inline'なし。旧インラインスクリプトは
 *     worker/public/assets/js/app.js に外部ファイル化済み)
 *   - style-src 'unsafe-inline'は、MapLibre GL本体がマーカー位置・canvas変形を
 *     常にインラインstyleで書き換える実装のため必須(ライブラリ側の既知の制約。
 *     script-srcとは異なりstyle-srcのXSSリスクは低いため許容する)
 *   - worker-src blob: は MapLibre GL がタイル解析用Web WorkerをBlob URLから
 *     生成するために必要
 *   - img-src/connect-src に https://cyberjapandata.gsi.go.jp を追加(地理院タイル)
 *   - connect-src の 'self' はws/wss相互(同一オリジンの待ち合わせ用WebSocket)も
 *     カバーする(CSP仕様上 'self' はws<->http, wss<->httpsのスキームを同一視する)
 */
const CSP_DIRECTIVES = [
  "default-src 'self'",
  "script-src 'self'",
  "style-src 'self' 'unsafe-inline'",
  "img-src 'self' data: blob: https://cyberjapandata.gsi.go.jp",
  "connect-src 'self' https://cyberjapandata.gsi.go.jp",
  "worker-src 'self' blob:",
  "font-src 'self'",
  "object-src 'none'",
  "base-uri 'self'",
  "form-action 'self'",
  "frame-ancestors 'none'",
];

export const CONTENT_SECURITY_POLICY = CSP_DIRECTIVES.join("; ");

export const SECURITY_HEADERS = Object.freeze({
  "X-Frame-Options": "DENY",
  "X-Content-Type-Options": "nosniff",
  "Referrer-Policy": "no-referrer",
  "Permissions-Policy": "geolocation=(self), camera=(self)",
  "Strict-Transport-Security": "max-age=63072000; includeSubDomains; preload",
  "Content-Security-Policy": CONTENT_SECURITY_POLICY,
});

// WebSocketアップグレード応答(status 101)は素通しする。CFのWorkers RuntimeはWebSocketPair用の
// Response(status:101, webSocket:client)を特別扱いしており、new Response()で作り直すと
// webSocketプロパティが失われて接続が成立しなくなるため、このケースだけは何もせず返す。
export function withSecurityHeaders(response) {
  if (!response || response.status === 101) return response;
  const headers = new Headers(response.headers);
  for (const [key, value] of Object.entries(SECURITY_HEADERS)) headers.set(key, value);
  return new Response(response.body, { status: response.status, statusText: response.statusText, headers });
}
