/**
 * プライバシーポリシー(/privacy)とサポート(/support)のページ。App Storeの掲載情報
 * (プライバシーポリシーURL・サポートURL)から参照される。日本語を先に、英語を後に置く。
 *
 * 内容は実装どおりに書くこと(誇張も過小申告もしない)。根拠になる実装:
 *   - 承認前は位置を保存しない / エリア外は保存しない: worker/src/room.js updateLocation()
 *   - 相手に渡すのは距離・方角・階の差だけ: worker/src/room.js buildPublicState()
 *   - 共有停止で座標を削除 / 3時間で部屋ごと削除: room.js stopSharing() / room-do.js alarm()
 *   - Jevに送る項目: worker/src/jev.js buildMeetContext()
 *   - レート制限はIPのSHA-256ハッシュをキーにする: worker/src/index.js hashClientIp()
 * <script>は使わない(CSPのscript-src 'self'のまま表示できる静的HTML)。
 */
import { Parser, jaModel } from "budoux";
import { SHIBUYA_RADIUS_M, ROOM_TTL_MS } from "./constants.js";

// 日本語の文節の途中で改行しないよう、文節の区切りに<wbr>を入れる(lp.js と同じBudouX)。
// タグの中身(属性)と日本語を含まない部分(英語・URL・メール)には触らない。
const jaParser = new Parser(jaModel);
const JA_CHAR_RE = /[\u3040-\u30ff\u3400-\u9fff]/;
function wbrHtml(html) {
  return html
    .split(/(<[^>]+>)/)
    .map((part) => (part.startsWith("<") || !JA_CHAR_RE.test(part) ? part : jaParser.parse(part).join("<wbr>")))
    .join("");
}

const RADIUS_KM = (SHIBUYA_RADIUS_M / 1000).toFixed(1);
const TTL_HOURS = ROOM_TTL_MS / (60 * 60 * 1000);
const CONTACT_EMAIL = "kaeru3160@gmail.com";
const REPO_URL = "https://github.com/Ryoseiimai/shibuya-machimachi";
const PUBLISHER_JA = "今井涼晴（個人開発者）";
const PUBLISHER_EN = "Ryosei Imai (individual developer, Japan)";
const UPDATED_JA = "2026年9月27日";
const UPDATED_EN = "September 27, 2026";

const PAGE_STYLE = `
  :root { --brand-orange: #c8431f; --brand-orange-on-soft: #8a2a10; --muted-text: #6b5d53; }
  * { box-sizing: border-box; }
  html, body { margin: 0; padding: 0; }
  body {
    font-family: -apple-system, "Hiragino Sans", "Hiragino Kaku Gothic ProN", "Yu Gothic", sans-serif;
    background: #fff7f0; color: #2a2222; line-height: 1.85;
  }
  .wrap { max-width: 720px; margin: 0 auto; padding: 0 20px; }
  header { padding: 22px 0 14px; border-bottom: 1px solid #f0d9cc; }
  header a { color: var(--brand-orange-on-soft); font-weight: 700; text-decoration: none; font-size: 14px; }
  h1 { font-size: 26px; color: var(--brand-orange); margin: 28px 0 6px; line-height: 1.4; }
  .updated { font-size: 13px; color: var(--muted-text); margin: 0 0 22px; }
  h2 { font-size: 18px; margin: 30px 0 8px; line-height: 1.5; }
  h3 { font-size: 16px; margin: 20px 0 6px; }
  p, li { font-size: 15px; }
  /* 文節の途中では改行しない(区切りは<wbr>)。それでも収まらない時だけ折り返す(lp.jsと同じ) */
  h1, h2, h3, p, li { word-break: keep-all; overflow-wrap: anywhere; }
  ul { padding-left: 22px; }
  .card { background: #fff; border-radius: 16px; padding: 18px 20px; box-shadow: 0 2px 12px rgba(0,0,0,0.05); margin: 14px 0; }
  .lang-sep { margin: 48px 0 0; padding-top: 8px; border-top: 2px solid #f0d9cc; }
  a { color: var(--brand-orange-on-soft); }
  footer { padding: 26px 0 44px; margin-top: 40px; border-top: 1px solid #f0d9cc; font-size: 13px; color: var(--muted-text); }
  footer a { margin-right: 14px; }
`;

function page({ title, lang = "ja", body }) {
  return `<!DOCTYPE html>
<html lang="${lang}">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<title>${title}</title>
<style>${PAGE_STYLE}</style>
</head>
<body>
<header><div class="wrap"><a href="/">← 渋谷マチマチ トップへ</a></div></header>
<main class="wrap">
${wbrHtml(body)}
</main>
<footer><div class="wrap">
  <a href="/">トップ</a><a href="/privacy">プライバシーポリシー / Privacy</a><a href="/support">サポート / Support</a>
  <p>© 2026 ${PUBLISHER_EN}</p>
</div></footer>
</body>
</html>`;
}

const PRIVACY_BODY = `
<h1>渋谷マチマチ プライバシーポリシー</h1>
<p class="updated">最終更新日: ${UPDATED_JA} ／ 発行者: ${PUBLISHER_JA}</p>

<div class="card">
<p><strong>要点</strong></p>
<ul>
  <li>アカウント登録はありません。入力するのはニックネームだけです。</li>
  <li>位置情報は、<strong>お互いが承認したあと</strong>、渋谷駅から半径${RADIUS_KM}km以内にいる間だけ、相手との距離と方角を計算するために送ります。</li>
  <li>相手に届くのは<strong>距離・方角・階の差だけ</strong>です。あなたの座標そのものは相手にもほかの誰にも届きません。</li>
  <li>サーバーは待ち合わせ中の最新の位置1点だけを一時的に保持し、<strong>共有をやめた時点で削除</strong>、作成から<strong>${TTL_HOURS}時間で部屋ごと自動削除</strong>します。位置の履歴は残さず、座標をログに書き出すこともありません。</li>
  <li>カメラ映像（AR表示）と端末の向きは端末の中だけで使い、送信も保存もしません。</li>
  <li>道順案内（「場所へ行く」「道順で案内」）は端末の中だけで計算し、現在地・行き先・経路を送信しません。</li>
  <li>広告、アクセス解析、トラッキングの仕組みは入っていません。情報を販売したり、広告目的で第三者に渡したりすることはありません。</li>
</ul>
</div>

<h2>1. 取得する情報と使い道</h2>
<h3>(1) ニックネーム</h3>
<p>待ち合わせの相手の画面に表示するために使います（最大20文字）。本名である必要はありません。待ち合わせの部屋のデータとして保持し、作成から${TTL_HOURS}時間で自動的に削除します。</p>
<h3>(2) 位置情報（正確な位置）</h3>
<p>待ち合わせの2人がお互いに承認するまでは、位置情報を一切送信しません。承認がそろったあとも、渋谷駅から半径${RADIUS_KM}kmの外では送信せず、サーバーも保存しません。</p>
<p>サーバー（Cloudflare Workers / Durable Objects）は、2人の距離と方角を計算するために、それぞれの最新の位置1点（緯度・経度・精度・更新時刻）だけを保持します。新しい位置が届くと上書きされ、履歴は残りません。どちらかが「共有をやめる」を押すと、その場で2人分の位置を削除します。作成から${TTL_HOURS}時間が経つと、部屋のデータはすべて削除されます。</p>
<p>相手の画面には距離・方角・階の差だけが表示されます。相手の画面の3D地図に出る「あなたのおおよその位置」は、相手のアプリが相手自身の位置とサーバーから届いた距離・方角をもとに、相手の端末の中で計算したものです。</p>
<h3>(3) 今いる階</h3>
<p>選んだ場合だけ、「相手は2つ上の階にいます」のような階の差の表示に使います。部屋のデータと一緒に削除されます。</p>
<h3>(4) 待ち合わせ場所（選んだ場合だけ）</h3>
<p>「待ち合わせ場所を決める」でスポットを選ぶと、その場所の名前（ハチ公像などの識別子）だけをサーバーに送り、2人の画面に表示します。座標は送りません。部屋のデータと一緒に削除されます。</p>
<h3>(5) 「会えた！」の判定</h3>
<p>「会えた！」を押したとき、判定サービス（TypeSafe AI Jev）に、距離（m）・同じ階かどうか・待ち合わせの経過時間・位置の精度・位置の更新からの秒数・2人ともボタンを押したかどうか、という数値だけを送ります。座標やニックネームは送りません。サービスが使えないときは、距離だけで判定します。</p>
<h3>(6) 通信に伴う情報</h3>
<p>アプリとサーバーの通信は Cloudflare を経由するため、IPアドレスなどの通信情報が Cloudflare で処理されます。待ち合わせの作成回数の制限（いたずら防止）のために、IPアドレスをハッシュ化した値を短時間だけ使います。開発者がIPアドレスを保存・閲覧することはありません。</p>
<h3>(7) カメラ・端末の向き</h3>
<p>「ARで探す」ではカメラ映像に相手の方向を重ねて表示し、矢印は端末の向き（コンパス）で回転させます。これらは端末の中だけで処理し、映像や向きのデータを送信・保存することはありません。</p>
<h3>(8) 道順案内</h3>
<p>「場所へ行く」（1人で定番スポットへ）と、待ち合わせ画面の「道順で案内」の道順は、端末の中だけで計算します。現在地・行き先・経路・選んだ階は送信も保存もしません（待ち合わせ画面で選んだ階は、上の(3)として相手に階の差を表示するためにだけ送ります）。</p>

<h2>2. 地図データの読み込み</h2>
<p>3D地図を表示するとき、アプリは国土地理院（地理院タイル）から地図画像を、「高画質で見る」ではPLATEAUの配信サーバーから建物データを直接読み込みます。そのとき、これらのサーバーには通常の通信情報（IPアドレスや、表示している範囲の地図の要求）が送られます。お店の情報（OpenStreetMap）と建物の簡易データはアプリに同梱しています。道順案内の道のデータ（OpenStreetMap）は、このサイトから公開ファイルとして読み込みます。</p>

<h2>3. 第三者への提供</h2>
<p>法令にもとづく場合を除き、取得した情報を第三者に提供しません。上に書いた Cloudflare（サーバー）と TypeSafe AI Jev（判定。座標やニックネームは送りません）は、アプリの機能を動かすためだけに使います。</p>

<h2>4. 端末の中に残る情報</h2>
<p>参加中の待ち合わせに再接続するための情報（部屋ごとの一時的な鍵）を、アプリを開いている間だけ端末の中に保持します。アプリを終了すると消えます。</p>

<h2>5. 利用する人について</h2>
<p>本アプリは、すでに知っている友人・知人と待ち合わせるためのものです。知らない人を探したり、知らない人と出会ったりする機能はありません。招待リンクは1回しか使えず、1つの待ち合わせに入れるのは2人までです。</p>

<h2>6. お問い合わせ</h2>
<p>本ポリシーとアプリについてのお問い合わせは、<a href="mailto:${CONTACT_EMAIL}">${CONTACT_EMAIL}</a> までお送りください。ソースコードは <a href="${REPO_URL}">GitHub</a> で公開しています。</p>
<p>発行者: ${PUBLISHER_JA}</p>

<h2>7. 改定</h2>
<p>機能の追加や法令の改正にあわせて本ポリシーを変更することがあります。変更したときはこのページを更新し、最終更新日を改めます。</p>

<div class="lang-sep" lang="en">
<h1>Shibuya Machimachi Privacy Policy</h1>
<p class="updated">Last updated: ${UPDATED_EN} · Published by ${PUBLISHER_EN}</p>
<div class="card">
<p><strong>Summary</strong></p>
<ul>
  <li>No account. The only thing you type in is a nickname.</li>
  <li>Your location is sent <strong>only after both people have approved each other</strong>, and only while you are within ${RADIUS_KM} km of Shibuya Station, to calculate the distance and direction between the two of you.</li>
  <li>The other person receives <strong>only the distance, direction, and floor difference</strong>. Your raw coordinates are never delivered to them or to anyone else.</li>
  <li>The server temporarily keeps only your latest position during the meetup. It is <strong>deleted as soon as sharing is stopped</strong>, and the whole room is <strong>deleted automatically ${TTL_HOURS} hours</strong> after it is created. No location history is kept, and coordinates are never written to logs.</li>
  <li>The camera image (AR view) and device orientation are processed on your device only and are never sent or stored.</li>
  <li>Walking directions ("場所へ行く" Go to a place / "道順で案内" Directions) are computed on your device only; your position, destination, and route are never sent.</li>
  <li>There are no ads, no analytics, and no tracking. We do not sell your data or share it with third parties for advertising.</li>
</ul>
</div>
<h2>1. Information we handle and why</h2>
<p><strong>Nickname</strong> — shown to the one person you meet (up to 20 characters; it does not need to be your real name). Deleted with the room after ${TTL_HOURS} hours.</p>
<p><strong>Precise location</strong> — never sent before mutual approval, and never sent or stored while you are outside the ${RADIUS_KM} km Shibuya area. The server (Cloudflare Workers / Durable Objects) keeps only each person's latest position (latitude, longitude, accuracy, timestamp) to compute distance and direction; each update overwrites the previous one. Tapping "Stop sharing" deletes both positions immediately, and all room data is deleted ${TTL_HOURS} hours after creation. The approximate pin shown on the other person's 3D map is computed on their own device from their own position plus the distance and direction.</p>
<p><strong>Current floor</strong> — optional; used only to show a floor difference. Deleted with the room.</p>
<p><strong>Meeting spot</strong> — optional; if either person picks a spot, only the spot's identifier (e.g. Hachiko statue) is sent to the server and shown to both people. No coordinates are sent. Deleted with the room.</p>
<p><strong>"We met!" judgment</strong> — only numbers (distance in meters, same-floor flag, elapsed time, location accuracy, seconds since the last update, whether both people tapped the button) are sent to the judgment service TypeSafe AI Jev. Coordinates and nicknames are never sent. If the service is unavailable, the app judges by distance only.</p>
<p><strong>Network information</strong> — traffic goes through Cloudflare, which processes network information such as IP addresses. To prevent abuse, the number of meetups created is rate-limited using a short-lived hashed value of the IP address. The developer does not store or view IP addresses.</p>
<p><strong>Camera and orientation</strong> — used on-device only for the AR view and the direction arrow; never sent or stored.</p>
<p><strong>Walking directions</strong> — computed on your device only. Your position, destination, route, and the floor you pick for directions are never sent or stored (in a meetup, the floor you select is sent only to show the floor difference, as described above).</p>
<h2>2. Map data</h2>
<p>When the 3D map is shown, the app loads map images directly from the Geospatial Information Authority of Japan (GSI tiles) and, in the high-quality view, building data from the PLATEAU distribution server. These servers receive ordinary network information (such as your IP address and the requested map area). Shop data (OpenStreetMap) and simplified building data are bundled in the app. The walkway data for directions (OpenStreetMap) is loaded from this site as a public file.</p>
<h2>3. Sharing with third parties</h2>
<p>We do not provide your information to third parties except as required by law. Cloudflare (server) and TypeSafe AI Jev (judgment; no coordinates or nicknames) are used only to run the app's features.</p>
<h2>4. Who the app is for</h2>
<p>The app is for meeting friends and acquaintances you already know. It has no feature for finding or meeting strangers. An invite link works only once, and each meetup is limited to two people.</p>
<h2>5. Contact</h2>
<p>Questions about this policy or the app: <a href="mailto:${CONTACT_EMAIL}">${CONTACT_EMAIL}</a>. The source code is public on <a href="${REPO_URL}">GitHub</a>.</p>
<h2>6. Changes</h2>
<p>We may update this policy when features or laws change. Updates will be posted on this page with a new "Last updated" date.</p>
</div>
`;

const SUPPORT_BODY = `
<h1>渋谷マチマチ サポート</h1>
<p class="updated">友だち・知り合いと渋谷で迷わず会うための、1対1の待ち合わせアプリです。</p>

<h2>使い方</h2>
<ol>
  <li>ニックネームを入れて「待ち合わせを作る」を押します（アカウント登録は不要）。</li>
  <li>表示された招待リンクを、会う相手に送ります（リンクは1回だけ使えます）。</li>
  <li>相手がリンクを開いて「承認して参加」を押し、あなたも「この人と位置を共有する」を押します。</li>
  <li>お互いの承認がそろうと、相手までの距離と方角の矢印が表示されます。3D地図・近くのお店・ARでも相手の方向が分かります。</li>
  <li>20m以内・同じ階まで来たら「会えた！」を押します。終わったら「共有をやめる」を押してください。</li>
</ol>
<p>1台で試したいときは、最初の画面の「デモで試す」を押すと、模擬の相手が近づいてくる待ち合わせを体験できます（アプリ版のみ）。</p>

<h2>よくある質問</h2>
<div class="card"><p><strong>Q. 距離が「--」のまま出ません。</strong><br>A. 2人とも承認が済んでいるか、位置情報の利用を「アプリの使用中は許可」にしているかを確認してください。渋谷駅から半径${RADIUS_KM}kmの外では、プライバシーのために位置の共有を止めています。</p></div>
<div class="card"><p><strong>Q. 矢印の向きが合いません。</strong><br>A. 矢印は端末のコンパスで回転します。周りに金属や磁石があるとずれることがあります。端末を8の字に動かすと改善することがあります。</p></div>
<div class="card"><p><strong>Q. 招待リンクが使えません。</strong><br>A. 招待リンクは1回だけ使えます。また、待ち合わせは作成から${TTL_HOURS}時間で自動的に終了します。新しく待ち合わせを作り直してください。</p></div>
<div class="card"><p><strong>Q. 相手に自分の居場所がそのまま知られますか？</strong><br>A. 相手に届くのは距離・方角・階の差だけです。座標そのものは届きません。詳しくは<a href="/privacy">プライバシーポリシー</a>をご覧ください。</p></div>
<div class="card"><p><strong>Q. データを消したいです。</strong><br>A. 「共有をやめる」を押すと、その場で2人分の位置を削除します。部屋のデータは作成から${TTL_HOURS}時間ですべて自動的に削除されます。アカウントはないので、退会の手続きもありません。</p></div>
<div class="card"><p><strong>Q. 料金はかかりますか？</strong><br>A. 無料です。アプリ内課金や広告はありません。</p></div>

<h2>お問い合わせ</h2>
<p>不具合やご要望は <a href="mailto:${CONTACT_EMAIL}">${CONTACT_EMAIL}</a> までお送りください。GitHubの<a href="${REPO_URL}/issues">Issues</a>でも受け付けています。</p>
<p>運営: ${PUBLISHER_JA}</p>

<div class="lang-sep" lang="en">
<h1>Shibuya Machimachi Support</h1>
<p class="updated">A 1-on-1 meetup app for finding a friend or acquaintance in Shibuya without getting lost.</p>
<h2>How to use</h2>
<ol>
  <li>Enter a nickname and tap "待ち合わせを作る" (Create a meetup). No account is needed.</li>
  <li>Send the invite link to the person you are meeting (it works only once).</li>
  <li>They open the link and tap "承認して参加" (Approve &amp; join); then you tap "この人と位置を共有する" (Share location with this person).</li>
  <li>Once both have approved, the distance and a direction arrow appear, along with a 3D map, nearby shops, and an AR view.</li>
  <li>When you are within 20 m and on the same floor, tap "会えた！" (We met!). Tap "共有をやめる" (Stop sharing) when you are done.</li>
</ol>
<p>To try it on a single device, tap "デモで試す" (Try the demo) on the first screen of the app to see a simulated partner walking toward you.</p>
<h2>FAQ</h2>
<p><strong>The distance stays at "--".</strong> Make sure both people have approved and that location access is set to "While Using the App". For privacy, sharing is paused outside the ${RADIUS_KM} km area around Shibuya Station.</p>
<p><strong>The invite link does not work.</strong> Invite links work only once, and meetups end automatically ${TTL_HOURS} hours after creation. Please create a new meetup.</p>
<p><strong>How do I delete my data?</strong> "Stop sharing" deletes both positions immediately, and all room data is deleted automatically after ${TTL_HOURS} hours. There is no account to delete.</p>
<p><strong>Is it free?</strong> Yes. There are no in-app purchases and no ads.</p>
<h2>Contact</h2>
<p>Bug reports and requests: <a href="mailto:${CONTACT_EMAIL}">${CONTACT_EMAIL}</a>, or <a href="${REPO_URL}/issues">GitHub Issues</a>.</p>
</div>
`;

export const PRIVACY_HTML = page({ title: "プライバシーポリシー | 渋谷マチマチ", body: PRIVACY_BODY });
export const SUPPORT_HTML = page({ title: "サポート | 渋谷マチマチ", body: SUPPORT_BODY });
