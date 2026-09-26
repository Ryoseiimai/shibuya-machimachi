# Security & Acceptable Use / セキュリティと利用条件

## 日本語

### 報告のしかた

脆弱性(認証秘密の漏えい・座標がレスポンスやログに混ざる・承認前に位置が届く不具合など)を
見つけた場合は、公開Issueではなく、
[GitHub Security Advisory](https://github.com/Ryoseiimai/shibuya-machimachi/security/advisories/new)
から非公開で報告してください。

### 受け付けない変更(必ず守ってください)

このプロジェクトの前提は「招待した2人が両方とも明示的に承認した場合にのみ、位置の送受信が
始まる」ことです。以下のようなPR・Issueは**受け付けません**。

- 片方だけの承認、あるいは承認なしで位置の送受信を始める機能
- 1部屋の定員(2人)を超えて第三者にも位置を見せる機能
- 渋谷エリア(渋谷駅から半径1.5km)の外でも位置を送信し続ける機能
- 共有停止を解除された後もキャッシュや別経路で位置を保持し続ける機能
- 座標そのものを管理者向け画面・分析・ログに出す機能

### 実装上のルール

- 座標(lat/lng)そのものを**サーバーのレスポンス・ログに一切出さない**(WebSocketメッセージ・
  APIレスポンス・ログのいずれにも含めない)。相手に渡してよいのは距離(m)・方角(度)・
  フロアの差・更新時刻・判定結果だけです(`worker/src/room.js` の `buildPublicState()` が
  この境界を一元管理しています)。3D渋谷の地図に出る「相手のピン」は、両者承認後
  (`isActive()`がtrue)に限り、**相手のアプリ側だけが**自分の実座標(GPS)にサーバーから
  届いた距離・方角を適用して画面内だけで近似計算した位置です(`worker/public/assets/js/app.js`
  の `refreshExtras()` / AR部品の `geo.js` の `destinationPoint()`)。サーバー自身は
  この近似位置を計算も保持もログ出力もしません。
- 承認前(`isActive()`がfalseの間)は `updateLocation()` が位置を一切保存しません。
  「合意なく位置を溜め込まない」を優先する設計です。
- 渋谷エリア外の座標は保存も転送もしません(`worker/src/room.js` の `updateLocation()`)。
- Jev判定(`worker/src/jev.js`)に送る内容は距離(m)・同階かどうか・経過時間のみで、
  座標やニックネームは送りません。
- `wrangler secret put JEV_API_KEY` で登録するAPIキーをリポジトリ・ログ・画面に出さない。
- 部屋は3時間で自動終了し、位置データを含め Durable Object のストレージを丸ごと削除します
  (`worker/src/room-do.js` の `alarm()`)。
- 道順案内(`worker/public/assets/js/route.js` / `route-panel.js`)は**端末の中だけで**経路を計算します。
  現在地・行き先・経路をサーバーに送る処理(fetch・WebSocketメッセージ)を追加しないでください。
  読み込むのは公開の道データ(`/route/graph.json`・`/route/places.json`)だけです。
- 待ち合わせ場所として部屋に保存・配信するのは**スポットのID**だけです(`worker/src/room.js` の
  `setMeetSpot()`。英小文字・数字・ハイフンのみ受け付け、座標は受け取りません)。

## English

### Reporting a vulnerability

If you find a security issue (secret leakage, coordinates leaking into a
response/log, or a bug that lets location through before mutual approval),
please report it privately via
[GitHub Security Advisories](https://github.com/Ryoseiimai/shibuya-machimachi/security/advisories/new)
instead of opening a public issue.

### Changes we will not accept

This project only works when **both** invited people have explicitly approved
sharing. The following will **not** be accepted:

- Starting location send/receive with only one side approved, or with no approval at all
- Showing a room's location data to more than the 2 matched participants
- Continuing to send location outside the Shibuya area (1.5km radius from Shibuya Station)
- Keeping serving a person's location (via cache or another path) after sharing is stopped
- Exposing raw coordinates on an admin/analytics screen or in logs

### Implementation rules

- Never put raw coordinates (lat/lng) **in a server response or a log line** (WebSocket
  message, API response, or log — none of them). Only distance (m), bearing (degrees),
  floor difference, update timestamps, and the judgment result may be shared with the
  other participant (`worker/src/room.js`'s `buildPublicState()` is the single choke
  point for this). The "partner pin" shown on the 3D Shibuya map only exists after
  **both** sides have approved (`isActive()` is true), and is computed **client-side by
  the other participant's own app**, by applying the server-provided distance/bearing to
  that participant's own real GPS position (`worker/public/assets/js/app.js`'s
  `refreshExtras()` / the AR component's `geo.js`'s `destinationPoint()`). The server
  itself never computes, stores, or logs this approximate position.
- Before mutual approval (`isActive()` is false), `updateLocation()` must not store any
  location at all — this project prefers storing nothing over storing something without
  consent.
- Coordinates outside the Shibuya area are never stored or forwarded
  (see `updateLocation()` in `worker/src/room.js`).
- The Jev judgment call (`worker/src/jev.js`) only ever sends distance (m), same-floor
  status, and elapsed time — never coordinates or nicknames.
- Never commit or print the `JEV_API_KEY` secret (set via `wrangler secret put JEV_API_KEY`).
- Rooms auto-expire after 3 hours and the entire Durable Object storage (including any
  location data) is deleted (`alarm()` in `worker/src/room-do.js`).
- Walking directions (`worker/public/assets/js/route.js` / `route-panel.js`) are computed
  **on-device only**. Do not add any request (fetch or WebSocket message) that sends the
  user's position, destination, or route to the server; only the public walkway data
  (`/route/graph.json`, `/route/places.json`) is downloaded.
- A shared meeting spot is stored and relayed as **a spot ID only** (`setMeetSpot()` in
  `worker/src/room.js` accepts lowercase letters/digits/hyphens and never coordinates).
