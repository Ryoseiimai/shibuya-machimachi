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
<link rel="icon" href="data:image/svg+xml,%3Csvg%20xmlns%3D%22http%3A%2F%2Fwww.w3.org%2F2000%2Fsvg%22%20viewBox%3D%220%200%20100%20100%22%3E%3Ctext%20y%3D%22.9em%22%20font-size%3D%2290%22%3E%F0%9F%93%8D%3C%2Ftext%3E%3C%2Fsvg%3E">
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
  .future-slot {
    border: 2px dashed #e8d9cc; border-radius: 14px; padding: 16px; margin-bottom: 12px;
    text-align: center; color: #b3a296;
  }
  .future-slot-label { font-weight: 800; font-size: 14px; color: #8a7a70; }
  .future-slot-body { font-size: 12px; margin-top: 4px; }
  #judge-box { text-align: center; margin: 14px 0; }
  #judge-status { font-size: 20px; font-weight: 800; padding: 10px; border-radius: 12px; background: #f4ede6; }
  #judge-status.found { background: #ff5a3c; color: #fff; }
  #judge-note { font-size: 13px; color: #9a8b80; margin-top: 6px; }
  .floor-diff { text-align: center; font-size: 15px; font-weight: 700; margin-top: 6px; }
  .updated-at { text-align: center; font-size: 12px; color: #9a8b80; margin-top: 4px; }
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
    <div class="future-slot" id="slot-shops">
      <div class="future-slot-label">近くのお店</div>
      <div class="future-slot-body">後日追加予定</div>
    </div>
    <div class="future-slot" id="slot-3d">
      <div class="future-slot-label">3D渋谷</div>
      <div class="future-slot-body">後日追加予定</div>
    </div>
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

  function renderMeet(state) {
    document.getElementById("meet-other-name").textContent = state.other ? state.other.nickname : "相手";

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
        // 意図的な簡略化: 渋谷エリア判定はサーバー側だけで行う(二重実装を避けるため)。
        // ここでは「両者承認済み(active)」のときだけ送信することで、
        // 承認前は座標を一切ネットワークに出さない。
        if (!lastState || lastState.phase !== "active") return;
        sendWs({ type: "location", lat: pos.coords.latitude, lng: pos.coords.longitude, acc: pos.coords.accuracy });
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
