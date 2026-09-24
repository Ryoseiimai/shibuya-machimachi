/**
 * スマホ向け画面一式(HTML/CSS/JS)を1つの文字列として配信する。
 * ojisan-sagashi(worker/src/index.js の HTML_PAGE)と同じ「Workerがテンプレート文字列を
 * 直接返す」方式を踏襲し、ビルドステップなしで `wrangler dev` からそのまま確認できるように
 * している。フレームワークは使わない(Vanilla JS)。
 *
 * 画面は全て1枚のHTMLに同居させ、`.screen`要素の表示/非表示だけで切り替える
 * (create / preview / full / waiting-guest / waiting-approval-guest / approve / meet /
 *  stopped / expired / error)。ルーティングは location.pathname("/" か "/r/<roomId>") と
 * サーバーから届く phase で決める。
 */
import { FLOORS, SHIBUYA_RADIUS_M, MEET_DISTANCE_M } from "./constants.js";

const FLOOR_OPTIONS = FLOORS.map((f) => `<option value="${f}">${f}</option>`).join("");
const RADIUS_KM = (SHIBUYA_RADIUS_M / 1000).toFixed(1);

export const APP_HTML = String.raw`<!DOCTYPE html>
<html lang="ja">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, viewport-fit=cover">
<meta name="app-config" content="${MEET_DISTANCE_M}">
<title>渋谷マチマチ</title>
<style>
  :root { color-scheme: light; }
  * { box-sizing: border-box; -webkit-tap-highlight-color: transparent; }
  html, body { margin: 0; padding: 0; }
  body {
    min-height: 100vh; font-family: -apple-system, "Hiragino Sans", "Yu Gothic", sans-serif;
    background: #fff7f0; color: #2a2222; line-height: 1.6;
    display: flex; flex-direction: column; align-items: stretch;
  }
  header {
    padding: 18px 20px 10px; text-align: center;
  }
  header h1 { margin: 0; font-size: 24px; letter-spacing: 0.04em; color: #ff5a3c; }
  header p { margin: 4px 0 0; font-size: 13px; color: #8a7a70; }
  main { flex: 1; padding: 12px 18px 40px; max-width: 480px; margin: 0 auto; width: 100%; }
  .screen { display: none; }
  .screen.visible { display: block; }
  .card {
    background: #fff; border-radius: 18px; padding: 22px 20px; margin-bottom: 16px;
    box-shadow: 0 2px 14px rgba(0,0,0,0.06);
  }
  label { display: block; font-size: 15px; font-weight: 700; margin-bottom: 8px; }
  input[type=text], select {
    width: 100%; font-size: 18px; padding: 12px 14px; border-radius: 12px;
    border: 2px solid #f0d9cc; margin-bottom: 14px; background: #fffdfb;
  }
  input[readonly] { background: #f6f1ec; color: #55483f; }
  button {
    font-size: 17px; font-weight: 800; padding: 14px 18px; border-radius: 14px; border: none;
    background: #ff5a3c; color: #fff; width: 100%; cursor: pointer;
  }
  button.secondary { background: #efe4da; color: #5b4c42; }
  button.share { margin-bottom: 10px; }
  button:disabled { opacity: 0.5; }
  .hint { font-size: 13px; color: #9a8b80; margin-top: 4px; }
  .big-distance { font-size: 52px; font-weight: 900; text-align: center; color: #ff5a3c; }
  .big-distance small { font-size: 20px; font-weight: 600; color: #9a8b80; }
  #arrow-wrap {
    width: 180px; height: 180px; margin: 10px auto; border-radius: 50%;
    background: radial-gradient(circle, rgba(255,90,60,0.12), transparent 70%);
    border: 2px solid rgba(255,90,60,0.35); display: flex; align-items: center; justify-content: center;
  }
  #arrow { font-size: 90px; transition: transform 0.25s ease; color: #ff5a3c; }
  .row { display: flex; gap: 10px; }
  .row > * { flex: 1; }
  .badge {
    display: inline-block; font-size: 12px; font-weight: 700; padding: 4px 10px;
    border-radius: 999px; background: #ffe6db; color: #ff5a3c; margin-bottom: 10px;
  }
  .warn-banner {
    background: #fff1cc; color: #7a5b00; padding: 12px 14px; border-radius: 12px;
    font-size: 14px; font-weight: 700; margin-bottom: 14px;
  }
  .block-label { font-weight: 800; font-size: 14px; color: #8a7a70; margin-bottom: 10px; }
  #judge-box { text-align: center; margin: 14px 0; }
  #judge-status { font-size: 20px; font-weight: 800; padding: 10px; border-radius: 12px; background: #f4ede6; }
  #judge-status.found { background: #ff5a3c; color: #fff; }
  #judge-note { font-size: 13px; color: #9a8b80; margin-top: 6px; }
  .floor-diff { text-align: center; font-size: 15px; font-weight: 700; margin-top: 6px; }
  .updated-at { text-align: center; font-size: 12px; color: #9a8b80; margin-top: 4px; }
  .shops-list { list-style: none; margin: 0; padding: 0; }
  .shops-list li {
    display: flex; justify-content: space-between; align-items: baseline; gap: 8px;
    padding: 9px 2px; border-bottom: 1px solid #f0e6dc; font-size: 14px;
  }
  .shops-list li:last-child { border-bottom: none; }
  .shop-name { font-weight: 700; color: #2a2222; }
  .shop-meta { color: #9a8b80; font-size: 12px; white-space: nowrap; }
  .floor-tag {
    display: inline-block; background: #ffe6db; color: #ff5a3c; border-radius: 999px;
    padding: 1px 7px; font-size: 11px; font-weight: 700; margin-left: 6px;
  }
  .map3d { width: 100%; height: 280px; border-radius: 14px; overflow: hidden; background: #e9eef1; position: relative; }
  .attribution-footer { font-size: 11px; color: #b3a296; text-align: center; margin: 4px 0 14px; line-height: 1.5; }
  .ar-fullscreen { position: fixed; inset: 0; background: #000; z-index: 1000; }
  .ar-fullscreen[hidden] { display: none; }
  #ar-mount { position: absolute; inset: 0; }
  .ar-close-btn {
    position: absolute; top: calc(env(safe-area-inset-top, 0px) + 12px); right: 14px;
    width: 40px; height: 40px; border-radius: 50%; background: rgba(0,0,0,0.55);
    color: #fff; font-size: 18px; border: none; z-index: 20;
  }
  .ar-vr-btn {
    position: absolute; left: 14px; right: 14px; bottom: calc(env(safe-area-inset-bottom, 0px) + 14px);
    background: rgba(30,30,34,0.85); color: #fff; border: none; border-radius: 12px;
    padding: 12px; font-size: 13px; font-weight: 700; z-index: 20;
  }
</style>
</head>
<body>
<header>
  <h1>渋谷マチマチ</h1>
  <p>渋谷駅から半径${RADIUS_KM}km限定の1対1待ち合わせ</p>
</header>
<main id="app">

  <section id="screen-loading" class="screen">
    <div class="card"><p>読み込んでいます…</p></div>
  </section>

  <section id="screen-create" class="screen">
    <div class="card">
      <label for="create-nickname">ニックネーム(相手に表示されます)</label>
      <input type="text" id="create-nickname" maxlength="20" placeholder="例: りょうせい">
      <button id="create-btn">待ち合わせを作る</button>
      <p class="hint">アカウント登録は不要です。作った待ち合わせは3時間で自動的に終了します。</p>
    </div>
  </section>

  <section id="screen-preview" class="screen">
    <div class="card">
      <p><strong id="preview-host-name"></strong>さんから招待されました。</p>
      <label for="preview-nickname">あなたのニックネーム</label>
      <input type="text" id="preview-nickname" maxlength="20" placeholder="例: すず">
      <p class="hint">承認すると、相手の画面の3D地図にあなたのおおよその位置と近くのお店が表示されます。</p>
      <button id="preview-join-btn">承認して参加</button>
      <p class="hint">参加すると、位置情報の共有についてお互いが承認するまで位置は送られません。</p>
    </div>
  </section>

  <section id="screen-full" class="screen">
    <div class="card">
      <p id="full-message">この招待リンクはすでに使われているか、満員です。</p>
    </div>
  </section>

  <section id="screen-error" class="screen">
    <div class="card"><p id="error-message">エラーが発生しました。</p></div>
  </section>

  <section id="screen-expired" class="screen">
    <div class="card"><p>この待ち合わせは終了しました(3時間経過)。位置情報のデータは削除されています。</p></div>
  </section>

  <section id="screen-waiting-guest" class="screen">
    <div class="card">
      <span class="badge">招待リンクを送ってください</span>
      <label for="invite-url-input">招待リンク(1回だけ使えます)</label>
      <input type="text" id="invite-url-input" readonly>
      <p class="hint">このリンクは1回だけ使えます。公開の場には貼らないでください。</p>
      <button id="share-invite-btn" class="share secondary">共有する</button>
      <a id="line-share-btn" class="share" style="display:block;text-decoration:none;">
        <button type="button" class="secondary">LINEで送る</button>
      </a>
      <button id="copy-invite-btn" class="share secondary">コピー</button>
      <p class="hint">相手がリンクを開いて参加するまでお待ちください。</p>
    </div>
  </section>

  <section id="screen-approve" class="screen">
    <div class="card">
      <p><strong id="approve-guest-name"></strong>さんが参加しました。</p>
      <p class="hint">承認すると、相手の画面の3D地図にあなたのおおよその位置と近くのお店が表示されます。</p>
      <button id="approve-btn">この人と位置を共有する</button>
      <p class="hint">押すまで、あなたの位置は相手に送られません。</p>
    </div>
  </section>

  <section id="screen-waiting-approval-guest" class="screen">
    <div class="card">
      <p>参加しました。<strong id="waiting-host-name"></strong>さんの承認をお待ちください。</p>
    </div>
  </section>

  <section id="screen-stopped" class="screen">
    <div class="card"><p id="stopped-message">位置の共有は停止されました。</p></div>
  </section>

  <section id="screen-meet" class="screen">
    <div class="card" id="out-of-area-banner-wrap" style="display:none;">
      <div class="warn-banner" id="out-of-area-banner">渋谷エリアの外なので共有を止めています</div>
    </div>
    <div class="card">
      <p style="text-align:center;margin:0 0 4px;">相手: <strong id="meet-other-name"></strong></p>
      <div id="arrow-wrap"><div id="arrow">⬆️</div></div>
      <div class="big-distance"><span id="meet-distance">--</span><small> m</small></div>
      <div class="updated-at" id="meet-updated-at"></div>
      <button id="orientation-permission-btn" class="secondary" style="display:none;margin-top:10px;">向きの許可をON</button>
    </div>
    <div class="card">
      <label for="floor-select">今いる階</label>
      <select id="floor-select">
        <option value="">選択してください</option>
        ${FLOOR_OPTIONS}
      </select>
      <div class="floor-diff" id="floor-diff-text"></div>
    </div>
    <div class="card" id="slot-shops">
      <div class="block-label">近くのお店</div>
      <ul class="shops-list" id="shops-list"></ul>
      <p class="hint" id="shops-empty">相手の位置と階が分かると表示されます。</p>
    </div>
    <div class="card" id="slot-3d">
      <div class="block-label">3D渋谷</div>
      <div class="map3d" id="map3d"></div>
      <button type="button" id="ar-open-btn" class="secondary" style="margin-top:10px;" disabled>ARで探す(読み込み中…)</button>
    </div>
    <div class="attribution-footer">建物: 出典 国土交通省 3D都市モデルPLATEAU（渋谷区, CC BY 4.0）／地図: 地理院タイル／店舗: © OpenStreetMap contributors (ODbL)</div>
    <div class="card">
      <div id="judge-box">
        <div id="judge-status">未確認</div>
        <div id="judge-note"></div>
      </div>
      <button id="judge-btn">会えた！</button>
    </div>
    <div class="card">
      <button id="stop-btn" class="secondary">共有をやめる</button>
    </div>
  </section>

</main>

<div class="ar-fullscreen" id="ar-fullscreen" hidden>
  <div id="ar-mount"></div>
  <button type="button" class="ar-close-btn" id="ar-close-btn" aria-label="閉じる">✕</button>
  <button type="button" class="ar-vr-btn" id="ar-vr-btn" style="display:none;">VRメガネで見る(実験的・対応端末のみ)</button>
</div>

<script src="/assets/js/app.js" defer></script>
</body>
</html>`;
