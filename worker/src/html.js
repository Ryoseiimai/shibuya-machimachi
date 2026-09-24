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
      <button id="copy-invite-btn" class="share secondary">リンクをコピー</button>
      <a id="line-share-btn" class="share" style="display:block;text-decoration:none;">
        <button type="button" class="secondary">LINEで送る</button>
      </a>
      <a id="x-share-btn" class="share" style="display:block;text-decoration:none;">
        <button type="button" class="secondary">Xで送る</button>
      </a>
      <p class="hint">相手がリンクを開いて参加するまでお待ちください。</p>
    </div>
  </section>

  <section id="screen-approve" class="screen">
    <div class="card">
      <p><strong id="approve-guest-name"></strong>さんが参加しました。</p>
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

<script>
(function () {
  "use strict";
  var MEET_DISTANCE_M = ${MEET_DISTANCE_M};
  var SCREENS = [
    "loading", "create", "preview", "full", "error", "expired",
    "waiting-guest", "approve", "waiting-approval-guest", "stopped", "meet",
  ];
  function showOnly(name) {
    for (var i = 0; i < SCREENS.length; i++) {
      var el = document.getElementById("screen-" + SCREENS[i]);
      if (!el) continue;
      el.classList.toggle("visible", SCREENS[i] === name);
    }
  }
  function showError(message) {
    document.getElementById("error-message").textContent = message;
    showOnly("error");
  }

  var wsScheme = location.protocol === "https:" ? "wss:" : "ws:";
  var ws = null;
  var lastState = null;
  var heading = 0;

  // --- 3D渋谷・近くのお店・AR(組み込み部品)---
  // 重要: 相手の生座標(lat/lng)はサーバーから一切送られてこない
  // (buildPublicState()が返すのはdistance_m/bearing_degだけ。AGENTS.md/SECURITY.mdの
  // 非交渉ルール)。3D地図の相手ピンとARの矢印・人影が使う「相手の推定座標」は、
  // 自分の実座標(selfPos, 自分のGPSから取得)にサーバーから届いたdistance_m/bearing_degを
  // destinationPoint(AR部品のgeo.js)で適用し、画面内だけで復元したもの。既にサーバーが
  // 送ってよいと決めている情報(距離・方位)だけから作っているので、この復元によって
  // サーバー側の非交渉ルールを回避しているわけではない。
  var ASSETS_JS_BASE = "/assets/js/";
  var selfPos = null;
  var extrasState = {
    shibuya3dModPromise: null, shibuya3dPromise: null, shibuya3d: null, nearestShops: null,
    arPromise: null, ar: null, focused: false, vrChecked: false,
  };

  // worker/src/floors.js の floorLabelToInt と同じロジック(クライアントはサーバー側の
  // モジュールをimportできないため、ここに複製している)。"B5"→-5, "1F"→1, "10F"→10。
  function floorLabelToInt(label) {
    if (typeof label !== "string" || !label) return null;
    if (label.charAt(0) === "B") return -parseInt(label.slice(1), 10);
    var n = parseInt(label, 10);
    return isNaN(n) ? null : n;
  }

  function storageKey(roomId, field) { return "sm:" + roomId + ":" + field; }
  function saveSession(roomId, role, secret) {
    sessionStorage.setItem(storageKey(roomId, "role"), role);
    sessionStorage.setItem(storageKey(roomId, "secret"), secret);
  }
  function loadSession(roomId) {
    var role = sessionStorage.getItem(storageKey(roomId, "role"));
    var secret = sessionStorage.getItem(storageKey(roomId, "secret"));
    if (!role || !secret) return null;
    return { role: role, secret: secret };
  }

  function connectWs(roomId, role, secret) {
    showOnly("loading");
    var url = wsScheme + "//" + location.host + "/api/rooms/" + roomId + "/ws?role=" + role + "&secret=" + encodeURIComponent(secret);
    ws = new WebSocket(url);
    ws.onmessage = function (evt) {
      var data;
      try { data = JSON.parse(evt.data); } catch (e) { return; }
      if (data.type === "state") { lastState = data; render(data); }
      else if (data.type === "judgeResult" && data.ok === false) { showJudgeNote(data); }
      else if (data.type === "error") { /* 個別のUIメッセージは各操作のUIで表示するため、ここでは黙って無視 */ }
    };
    ws.onclose = function () {
      if (lastState && (lastState.phase === "expired" || lastState.phase === "stopped")) return;
      // 意図的な簡略化: 自動再接続は行わない(MVP)。切れた場合はページ再読み込みを促す。
    };
    ws.onerror = function () {};
    startGeolocation();
    startOrientation();
  }

  function sendWs(msg) {
    if (ws && ws.readyState === WebSocket.OPEN) ws.send(JSON.stringify(msg));
  }

  function render(state) {
    if (state.phase === "expired") { showOnly("expired"); return; }
    if (state.phase === "stopped") {
      var who = state.stopped && state.stopped.by === state.role ? "あなた" : "相手";
      document.getElementById("stopped-message").textContent = who + "が共有をやめたため、位置の共有は停止しました。";
      showOnly("stopped");
      return;
    }
    if (state.phase === "waiting_guest") {
      showOnly("waiting-guest");
      return;
    }
    if (state.phase === "waiting_host_approval") {
      if (state.role === "host") {
        document.getElementById("approve-guest-name").textContent = state.other ? state.other.nickname : "";
        showOnly("approve");
      } else {
        document.getElementById("waiting-host-name").textContent = state.other ? state.other.nickname : "";
        showOnly("waiting-approval-guest");
      }
      return;
    }
    if (state.phase === "active") {
      renderMeet(state);
      showOnly("meet");
      return;
    }
  }

  var extrasBooted = false;
  function renderMeet(state) {
    document.getElementById("meet-other-name").textContent = state.other ? state.other.nickname : "相手";

    if (!extrasBooted) {
      // 3D/AR部品はサイズが大きい(地図データ含め数MB)ため、待ち合わせ画面(active)に
      // 入って初めて読み込む(create/preview画面では読み込まない)。
      extrasBooted = true;
      ensureShibuya3d();
      ensureAr();
    }

    var outOfAreaWrap = document.getElementById("out-of-area-banner-wrap");
    if (state.self && state.self.inArea === false) {
      document.getElementById("out-of-area-banner").textContent = "渋谷エリアの外なので共有を止めています";
      outOfAreaWrap.style.display = "block";
    } else if (state.other && state.other.inArea === false) {
      document.getElementById("out-of-area-banner").textContent = "相手が渋谷エリアの外にいるため、距離を計算できません";
      outOfAreaWrap.style.display = "block";
    } else {
      outOfAreaWrap.style.display = "none";
    }

    var distEl = document.getElementById("meet-distance");
    distEl.textContent = state.distance_m != null ? state.distance_m : "--";
    if (state.bearing_deg != null) applyArrowRotation(state.bearing_deg);

    var updatedEl = document.getElementById("meet-updated-at");
    if (state.other && state.other.lastUpdatedAt) {
      var t = new Date(state.other.lastUpdatedAt).toLocaleTimeString("ja-JP");
      updatedEl.textContent = "相手の最終更新: " + t;
    } else {
      updatedEl.textContent = "相手の位置を待っています…";
    }

    document.getElementById("floor-diff-text").textContent = state.floorDiffText || "";

    var judgeStatus = document.getElementById("judge-status");
    var judgeNote = document.getElementById("judge-note");
    if (state.judge && state.judge.found) {
      var pct = state.judge.probability != null ? Math.round(state.judge.probability * 100) + "%" : "";
      judgeStatus.textContent = "会えた! " + pct;
      judgeStatus.className = "found";
      judgeNote.textContent = state.judge.source === "jev" ? "Jev判定" : "距離による判定";
    } else {
      judgeStatus.textContent = "未確認";
      judgeStatus.className = "";
      judgeNote.textContent = "";
    }

    refreshExtras();
  }

  function showJudgeNote(data) {
    var note = document.getElementById("judge-note");
    var reasonText = {
      too_far: "まだ" + MEET_DISTANCE_M + "m以内に近づいていません" + (data.distance_m != null ? "(現在約" + data.distance_m + "m)" : ""),
      different_floor: "階が違います。同じ階に来てから押してください",
      missing_floor: "お互いに今いる階を選んでください",
      missing_location: "位置情報を取得中です。少し待ってからもう一度押してください",
      not_active: "まだお互いの承認が完了していません",
    };
    note.textContent = reasonText[data.reason] || "まだ判定できません";
  }

  function applyArrowRotation(bearingToTarget) {
    var arrow = document.getElementById("arrow");
    var rel = (bearingToTarget - heading + 360) % 360;
    arrow.style.transform = "rotate(" + rel + "deg)";
  }

  // shibuya3d.mjsモジュール自体の読み込み(import()のみ、地図のmountは含まない)。一度だけ実行し、
  // 以後は同じPromiseを返す。近くのお店(nearestShops)は地図(MapLibre GL、CDNから数百KB)を
  // 待たずに使いたいので、モジュール読み込みとマウントのPromiseを分けている
  // (以前はensureShibuya3d()の完了(=地図マウント完了)を待たないとnearestShopsが使えず、
  // geo.jsの読み込みの方が先に終わって「近くのお店」が空のまま固定される競合があった)。
  function ensureShibuya3dMod() {
    if (!extrasState.shibuya3dModPromise) {
      extrasState.shibuya3dModPromise = import(ASSETS_JS_BASE + "shibuya3d.mjs").then(function (mod) {
        extrasState.nearestShops = mod.nearestShops;
        return mod;
      });
    }
    return extrasState.shibuya3dModPromise;
  }

  // 3D渋谷をmap3d要素にmountする。一度だけ実行し、以後は同じPromiseを返す(mountShibuya3Dは
  // 1回きり。地図データは数MBあるため待ち合わせ画面(active)に入るまでは読み込まない)。
  function ensureShibuya3d() {
    if (!extrasState.shibuya3dPromise) {
      extrasState.shibuya3dPromise = ensureShibuya3dMod().then(function (mod) {
        return mod.mountShibuya3D(document.getElementById("map3d"), {});
      }).then(function (api) {
        extrasState.shibuya3d = api;
        return api;
      });
    }
    return extrasState.shibuya3dPromise;
  }

  // ar.js(AR部品)を読み込んでmountする。一度だけ実行する。mountAR()自体はカメラ・
  // センサーの許可を求めない(DOM構築のみ)ので、オーバーレイが非表示のうちに先読みしておき、
  // 「ARで探す」ボタンのクリックハンドラの中でar.start()を直接呼べるようにする
  // (iOSはユーザー操作コンテキストが切れると許可ダイアログを出さないため)。
  function ensureAr() {
    if (!extrasState.arPromise) {
      extrasState.arPromise = import(ASSETS_JS_BASE + "ar.js").then(function (mod) {
        var api = mod.mountAR(document.getElementById("ar-mount"));
        extrasState.ar = api;
        var btn = document.getElementById("ar-open-btn");
        btn.disabled = false;
        btn.textContent = "ARで探す";
        return api;
      });
    }
    return extrasState.arPromise;
  }

  // AR部品のgeo.js(destinationPoint/normalizeAngleDiffなどの純粋関数)を読み込む。
  // ブラウザのESモジュールキャッシュにより、同じURLの2回目以降のimport()は再フェッチされない。
  function loadGeoMod() {
    return import(ASSETS_JS_BASE + "geo.js");
  }

  // WSの最新状態(lastState)と自分の実座標(selfPos)から、3D渋谷のピン・近くのお店・ARの
  // 表示を更新する。承認前(active以外)や自分の位置がまだ無いときは何もしない。
  function refreshExtras() {
    if (!lastState || lastState.phase !== "active" || !selfPos) return;
    var state = lastState;
    var meFloor = floorLabelToInt(state.self && state.self.floor);
    var meFloorInt = meFloor == null ? 1 : meFloor;

    ensureShibuya3d().then(function (api) { api.setMe(selfPos.lat, selfPos.lng, meFloorInt); });
    if (extrasState.ar) extrasState.ar.setMe(selfPos.lat, selfPos.lng, meFloorInt);

    if (state.distance_m == null || state.bearing_deg == null) return; // 相手の位置はまだ届いていない

    var partnerName = (state.other && state.other.nickname) || "相手";
    var partnerFloor = floorLabelToInt(state.other && state.other.floor);
    var partnerFloorInt = partnerFloor == null ? 1 : partnerFloor;

    loadGeoMod().then(function (geoMod) {
      // 相手の推定座標 = 自分の実座標 + サーバーから届いた距離・方位(destinationPoint)。
      // 相手の生座標がネットワーク越しに届いているわけではない(このファイル冒頭のコメント参照)。
      var p = geoMod.destinationPoint(selfPos.lat, selfPos.lng, state.bearing_deg, state.distance_m);
      ensureShibuya3d().then(function (api) {
        api.setPartner(p.lat, p.lng, partnerFloorInt, partnerName);
        if (!extrasState.focused) { api.focusBoth(); extrasState.focused = true; } // 初回だけ2人が収まる距離へ(以後は手動操作を尊重)
      });
      if (extrasState.ar) extrasState.ar.setPartner(p.lat, p.lng, partnerFloorInt, partnerName);
      updateShopsList(p.lat, p.lng);
    });
  }

  // 近くのお店を取得してリストに描画する。ensureShibuya3dMod()(モジュールのimportのみ、地図の
  // マウントは待たない)にchainすることで、shibuya3d.mjsのモジュール本体さえ読み込めていれば
  // MapLibreの地図がまだ完全にマウントし終わっていなくても近くのお店を表示できるようにしている。
  function updateShopsList(lat, lng) {
    ensureShibuya3dMod().then(function (mod) {
      return mod.nearestShops(lat, lng, 3);
    }).then(function (shops) {
      var list = document.getElementById("shops-list");
      var empty = document.getElementById("shops-empty");
      list.innerHTML = "";
      if (!shops || !shops.length) { empty.style.display = "block"; return; }
      empty.style.display = "none";
      for (var i = 0; i < shops.length; i++) {
        var s = shops[i];
        var li = document.createElement("li");
        var nameSpan = document.createElement("span");
        nameSpan.className = "shop-name";
        nameSpan.textContent = s.name;
        var metaSpan = document.createElement("span");
        metaSpan.className = "shop-meta";
        metaSpan.textContent = s.distanceM + "m";
        if (s.level) {
          // 意図的な簡略化: OSMのlevelタグは自由記法("-1;0"等)のため、変換せずそのまま表示する。
          var tag = document.createElement("span");
          tag.className = "floor-tag";
          tag.textContent = s.level + "階";
          metaSpan.appendChild(tag);
        }
        li.appendChild(nameSpan);
        li.appendChild(metaSpan);
        list.appendChild(li);
      }
    }).catch(function () {
      // 意図的な簡略化: お店データの取得に失敗しても待ち合わせ本体の機能(距離・矢印)は継続する
    });
  }

  function bindArOverlay() {
    var overlay = document.getElementById("ar-fullscreen");
    var openBtn = document.getElementById("ar-open-btn");
    var closeBtn = document.getElementById("ar-close-btn");
    var vrBtn = document.getElementById("ar-vr-btn");

    openBtn.onclick = function () {
      if (!extrasState.ar) return; // 読み込み中はbutton disabledのはずだが念のため
      overlay.hidden = false;
      // start()は必ずクリックハンドラの中で直接(awaitを挟まずに)呼ぶ。iOSはユーザー操作の
      // コンテキストが切れるとカメラ・向きセンサーの許可ダイアログを出さないことがあるため。
      extrasState.ar.start();
      offerVrButton(vrBtn);
    };
    closeBtn.onclick = function () {
      overlay.hidden = true;
      if (extrasState.ar) extrasState.ar.stop();
    };
  }

  // VRメガネボタン: WebXR(immersive-ar/immersive-vr)に対応した端末でのみ表示する実験的機能。
  // AR部品のvr.js側でiPhone/Vision Proは明示的に対象外にしている。初回「ARで探す」タップ時に
  // 一度だけ対応判定を行う(判定にnavigator.xrへの問い合わせが要るため、使わないなら省く)。
  function offerVrButton(vrBtn) {
    if (extrasState.vrChecked) return;
    extrasState.vrChecked = true;
    import(ASSETS_JS_BASE + "vr.js").then(function (vrMod) {
      return vrMod.isVrAvailable().then(function (mode) {
        if (!mode) return;
        vrBtn.style.display = "block";
        vrBtn.onclick = function () {
          if (!lastState || lastState.bearing_deg == null || lastState.distance_m == null) return;
          loadGeoMod().then(function (geoMod) {
            var rel = geoMod.normalizeAngleDiff(heading, lastState.bearing_deg);
            vrMod.startVrScene(document.getElementById("ar-fullscreen"), mode, rel, lastState.distance_m).catch(function () {});
          });
        };
      });
    }).catch(function () {
      // WebXR非対応環境(大半のiPhone/Android)では静かに諦める(実験的機能・ボタンは出さないまま)
    });
  }

  function startOrientation() {
    function onOrientation(e) {
      var h = null;
      if (typeof e.webkitCompassHeading === "number") h = e.webkitCompassHeading;
      else if (e.alpha != null) h = 360 - e.alpha;
      if (h != null) {
        heading = h;
        if (lastState && lastState.bearing_deg != null) applyArrowRotation(lastState.bearing_deg);
      }
    }
    if (typeof DeviceOrientationEvent !== "undefined" && typeof DeviceOrientationEvent.requestPermission === "function") {
      var btn = document.getElementById("orientation-permission-btn");
      btn.style.display = "inline-block";
      btn.onclick = function () {
        DeviceOrientationEvent.requestPermission().then(function (res) {
          if (res === "granted") {
            window.addEventListener("deviceorientation", onOrientation);
            btn.style.display = "none";
          }
        }).catch(function () {});
      };
    } else if (typeof DeviceOrientationEvent !== "undefined") {
      window.addEventListener("deviceorientation", onOrientation);
    }
  }

  // 意図的な簡略化: watchPositionのみを使い、getCurrentPositionは併用しない
  // (同時に使うとブラウザによっては新しい要求が既存のwatchの陰でタイムアウトするまで
  // 応答しないことがある)。そのため、承認が揃った直後の初回送信は「次にGPSが位置を
  // 報告するタイミング」まで待つ(実機では静止していても数秒間隔で再報告されるのが通常)。
  // 承認直後により速く距離を出したい本格対応が要る場合は、サーバー側WSの接続時に
  // クライアントの現在のwatchPosition購読を一度張り直す(stopPosition→watchPosition)方式が入口。
  function startGeolocation() {
    if (!navigator.geolocation) return;
    navigator.geolocation.watchPosition(
      function (pos) {
        // selfPos(自分の実座標)はこのブラウザ内でのみ使う(3D渋谷の自分ピン・ARのsetMe用)。
        // ネットワークには一切送信しない値であり、下のsendWsとは別物。
        selfPos = { lat: pos.coords.latitude, lng: pos.coords.longitude };
        // 意図的な簡略化: 渋谷エリア判定はサーバー側だけで行う(二重実装を避けるため)。
        // ここでは「両者承認済み(active)」のときだけ送信することで、
        // 承認前は座標を一切ネットワークに出さない。
        if (!lastState || lastState.phase !== "active") return;
        sendWs({ type: "location", lat: pos.coords.latitude, lng: pos.coords.longitude, acc: pos.coords.accuracy });
        refreshExtras();
      },
      function () {},
      { enableHighAccuracy: true, maximumAge: 5000, timeout: 10000 }
    );
  }

  function buildShareLinks(url, hostName) {
    var text = (hostName || "") + "さんから渋谷マチマチの招待です";
    document.getElementById("line-share-btn").href = "https://line.me/R/msg/text/?" + encodeURIComponent(text + "\n" + url);
    document.getElementById("x-share-btn").href = "https://twitter.com/intent/tweet?text=" + encodeURIComponent(text) + "&url=" + encodeURIComponent(url);
  }

  function initCreateScreen() {
    showOnly("create");
    document.getElementById("create-btn").onclick = function () {
      var nickname = document.getElementById("create-nickname").value.trim();
      if (!nickname) { showError("ニックネームを入力してください"); return; }
      fetch("/api/rooms", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ nickname: nickname }),
      }).then(function (r) { return r.json(); }).then(function (data) {
        if (!data.ok) { showError("作成に失敗しました(" + data.reason + ")"); return; }
        saveSession(data.roomId, "host", data.hostSecret);
        var inviteUrl = location.origin + "/r/" + data.roomId + "?invite=" + data.inviteToken;
        history.replaceState(null, "", "/r/" + data.roomId);
        document.getElementById("invite-url-input").value = inviteUrl;
        buildShareLinks(inviteUrl, nickname);
        document.getElementById("copy-invite-btn").onclick = function () { copyToClipboard(inviteUrl); };
        connectWs(data.roomId, "host", data.hostSecret);
      }).catch(function () { showError("通信エラーが発生しました"); });
    };
  }

  function copyToClipboard(text) {
    if (navigator.clipboard && navigator.clipboard.writeText) {
      navigator.clipboard.writeText(text).catch(function () { fallbackCopy(text); });
    } else {
      fallbackCopy(text);
    }
  }
  function fallbackCopy(text) {
    var el = document.getElementById("invite-url-input");
    el.select();
    try { document.execCommand("copy"); } catch (e) {}
  }

  function initRoomScreen(roomId) {
    var existing = loadSession(roomId);
    if (existing) { connectWs(roomId, existing.role, existing.secret); return; }

    var params = new URLSearchParams(location.search);
    var invite = params.get("invite");
    if (!invite) { showError("このリンクだけでは参加できません。招待リンクを開いてください。"); return; }

    showOnly("loading");
    fetch("/api/rooms/" + roomId + "/preview?invite=" + encodeURIComponent(invite))
      .then(function (r) { return r.json().then(function (data) { return { status: r.status, data: data }; }); })
      .then(function (res) {
        if (!res.data.ok) {
          if (res.data.reason === "full") { document.getElementById("full-message").textContent = "この待ち合わせはすでに満員です。"; showOnly("full"); }
          else if (res.data.reason === "expired") { showOnly("expired"); }
          else if (res.data.reason === "not_found") { showError("待ち合わせが見つかりません。URLを確認してください。"); }
          else { showError("この招待リンクは使えません。"); }
          return;
        }
        document.getElementById("preview-host-name").textContent = res.data.hostNickname;
        showOnly("preview");
        document.getElementById("preview-join-btn").onclick = function () {
          var nickname = document.getElementById("preview-nickname").value.trim();
          if (!nickname) { showError("ニックネームを入力してください"); return; }
          fetch("/api/rooms/" + roomId + "/join", {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({ invite: invite, nickname: nickname }),
          }).then(function (r) { return r.json(); }).then(function (data) {
            if (!data.ok) { showError("参加に失敗しました(" + data.reason + ")"); return; }
            saveSession(roomId, "guest", data.guestSecret);
            history.replaceState(null, "", "/r/" + roomId);
            connectWs(roomId, "guest", data.guestSecret);
          }).catch(function () { showError("通信エラーが発生しました"); });
        };
      })
      .catch(function () { showError("通信エラーが発生しました"); });
  }

  function bindMeetControls() {
    document.getElementById("approve-btn").onclick = function () { sendWs({ type: "approve" }); };
    document.getElementById("judge-btn").onclick = function () { sendWs({ type: "judge" }); };
    document.getElementById("stop-btn").onclick = function () {
      if (confirm("位置の共有をやめますか？")) sendWs({ type: "stop" });
    };
    document.getElementById("floor-select").onchange = function (e) {
      if (e.target.value) sendWs({ type: "floor", floor: e.target.value });
    };
  }

  function main() {
    bindMeetControls();
    bindArOverlay();
    var m = location.pathname.match(/^\/r\/([a-f0-9]{32})$/);
    if (m) { initRoomScreen(m[1]); return; }
    if (location.pathname === "/") { initCreateScreen(); return; }
    showError("ページが見つかりません");
  }

  document.addEventListener("DOMContentLoaded", main);
})();
</script>
</body>
</html>`;
