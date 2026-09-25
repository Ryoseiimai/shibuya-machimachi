// 渋谷マチマチ スマホ画面のクライアントロジック。
// 元々 worker/src/html.js の <script> タグにインラインで書かれていたコードをそのまま
// 外部ファイル化したもの(2026-09-24 セキュリティ対応。CSPのscript-srcから'unsafe-inline'を
// 外すため。挙動はインライン時と同じ)。定数(MEET_DISTANCE_M)だけは、テンプレート文字列で
// 埋め込めなくなった代わりに <meta name="app-config"> から読む(html.js側参照)。
(function () {
  "use strict";
  var configMeta = document.querySelector('meta[name="app-config"]');
  var MEET_DISTANCE_M = configMeta ? parseInt(configMeta.getAttribute("content"), 10) : 20;
  var staleMeta = document.querySelector('meta[name="app-config-location-stale-ms"]');
  var LOCATION_STALE_MS = staleMeta ? parseInt(staleMeta.getAttribute("content"), 10) : 120000;
  var SCREENS = [
    "loading", "create", "preview", "full", "error", "expired",
    "waiting-guest", "approve", "waiting-approval-guest", "stopped", "meet",
  ];
  // 通信切れ再接続の指数バックオフ設定(1s, 2s, 4s, ... 上限15s)。
  var RECONNECT_BASE_MS = 1000;
  var RECONNECT_MAX_MS = 15000;
  var STATUS_BANNER_POLL_MS = 5000; // WSが止まっていても「最終更新から何秒」表示を進めるための定期再評価
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
  // iOSアプリ(app/src/native-bridge.js)が差し込むホスト機能。Web版では常にnullで、下の分岐は
  // すべて従来どおり(同一オリジンのfetch/WebSocket・ブラウザ標準のAPI)になる。アプリでは画面を
  // アプリ内に同梱して読み込むため、通信先(apiBase)だけ本番Workerの絶対URLを使う。
  var host = window.MachimachiHost || null;
  var API_BASE = (host && host.apiBase) || ""; // ""=同一オリジン(Web版)
  var WS_BASE = API_BASE ? API_BASE.replace(/^http/, "ws") : wsScheme + "//" + location.host;
  var PUBLIC_ORIGIN = API_BASE || location.origin; // 招待リンクのオリジン(アプリが無い相手もブラウザで開ける)
  function apiFetch(path, init) {
    return host && host.fetch ? host.fetch(API_BASE + path, init) : fetch(API_BASE + path, init);
  }
  function openSocket(url) {
    return host && host.createSocket ? host.createSocket(url) : new WebSocket(url);
  }
  var judgeFoundNotified = false; // 「会えた!」の触覚フィードバックを1回だけ鳴らすため
  var ws = null;
  var lastState = null;
  var heading = 0;

  // --- 通信切れ検知・自動再接続(指数バックオフ) ---
  var wsConnected = false; // まだ一度も繋がっていない/意図的な終端状態ではfalseのまま
  var currentConn = null; // { roomId, role, secret } — 再接続時に使う
  var reconnectAttempts = 0;
  var reconnectTimer = null;
  var disconnectedAt = null;

  // --- 3D渋谷・近くのお店・AR(組み込み部品)---
  // 重要: 相手の生座標(lat/lng)はサーバーから一切送られてこない
  // (buildPublicState()が返すのはdistance_m/bearing_degだけ。AGENTS.md/SECURITY.mdの
  // 非交渉ルール)。3D地図の相手ピンとARの矢印・人影が使う「相手の推定座標」は、
  // 自分の実座標(selfPos, 自分のGPSから取得)にサーバーから届いたdistance_m/bearing_degを
  // destinationPoint(AR部品のgeo.js)で適用し、画面内だけで復元したもの。既にサーバーが
  // 送ってよいと決めている情報(距離・方位)だけから作っているので、この復元によって
  // サーバー側の非交渉ルールを回避しているわけではない。
  var ASSETS_JS_BASE = "/assets/js/";
// 意図的な簡略化: /assets/* は以前 immutable(1年)で配信していたため、中身を変えたら版の印を上げて
// 古いキャッシュを持つ端末にも新しい版を読ませる(本格対応はファイル名へのハッシュ付与)。
var ASSET_VERSION_QUERY = "?v=20260925b";
  var selfPos = null;
  var extrasState = {
    shibuya3dModPromise: null, shibuya3dPromise: null, shibuya3d: null, nearestShops: null,
    arPromise: null, ar: null, focused: false, vrChecked: false,
    hqPromise: null, hq: null, lastMe: null, lastPartner: null,
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

  function connectWs(roomId, role, secret, isReconnect) {
    currentConn = { roomId: roomId, role: role, secret: secret };
    if (!isReconnect) showOnly("loading");
    var url = WS_BASE + "/api/rooms/" + roomId + "/ws?role=" + role + "&secret=" + encodeURIComponent(secret);
    ws = openSocket(url);
    ws.onopen = function () {
      wsConnected = true;
      disconnectedAt = null;
      reconnectAttempts = 0;
      if (reconnectTimer) { clearTimeout(reconnectTimer); reconnectTimer = null; }
      updateStatusBanner();
    };
    ws.onmessage = function (evt) {
      var data;
      try { data = JSON.parse(evt.data); } catch (e) { return; }
      if (data.type === "state") {
        wsConnected = true;
        lastState = data;
        render(data);
      }
      else if (data.type === "judgeResult" && data.ok === false) { showJudgeNote(data); }
      else if (data.type === "error") { /* 個別のUIメッセージは各操作のUIで表示するため、ここでは黙って無視 */ }
    };
    ws.onclose = function () {
      if (lastState && (lastState.phase === "expired" || lastState.phase === "stopped")) return; // 終端状態は再接続しない
      wsConnected = false;
      if (!disconnectedAt) disconnectedAt = Date.now();
      updateStatusBanner();
      scheduleReconnect();
    };
    ws.onerror = function () { try { ws.close(); } catch (e) {} };
    if (!isReconnect) { startGeolocation(); startOrientation(); }
  }

  // 通信が切れたら指数バックオフ(1s→2s→4s→…上限15s)で再接続を試みる。
  // 成功(ws.onopen/stateメッセージ受信)すればreconnectAttemptsは0に戻る。
  function scheduleReconnect() {
    if (reconnectTimer || !currentConn) return;
    var delay = Math.min(RECONNECT_MAX_MS, RECONNECT_BASE_MS * Math.pow(2, reconnectAttempts));
    reconnectAttempts += 1;
    reconnectTimer = setTimeout(function () {
      reconnectTimer = null;
      if (currentConn) connectWs(currentConn.roomId, currentConn.role, currentConn.secret, true);
    }, delay);
  }

  function formatClockTime(ms) {
    if (!ms) return "--:--";
    return new Date(ms).toLocaleTimeString("ja-JP", { hour: "2-digit", minute: "2-digit" });
  }

  // 待ち合わせ画面の「状態バナー」を1箇所に集約する: 通信切れ > 自分がエリア外 > 相手がエリア外 >
  // 相手の位置が古い、の優先順で1つだけ表示する(複数のバナーが同時に積み重なるのを避ける)。
  // 併せて、通信切れ・位置が古いときは距離/矢印カードを薄く(is-stale)して「今の値ではない」と伝える。
  function updateStatusBanner() {
    var wrap = document.getElementById("status-banner-wrap");
    var el = document.getElementById("status-banner");
    var distanceCard = document.getElementById("distance-card");
    if (!wrap || !el) return;

    if (!wsConnected) {
      var lastUpdate = lastState && lastState.other && lastState.other.lastUpdatedAt;
      el.textContent = "通信が切れました。位置が更新されていません(最終更新 " + formatClockTime(lastUpdate || disconnectedAt) + ")";
      el.className = "offline-banner";
      wrap.style.display = "block";
      if (distanceCard) distanceCard.classList.add("is-stale");
      return;
    }

    if (!lastState || lastState.phase !== "active") {
      wrap.style.display = "none";
      if (distanceCard) distanceCard.classList.remove("is-stale");
      return;
    }

    if (lastState.self && lastState.self.inArea === false) {
      el.textContent = "渋谷エリアの外なので共有を止めています";
      el.className = "warn-banner";
      wrap.style.display = "block";
      if (distanceCard) distanceCard.classList.remove("is-stale");
      return;
    }
    if (lastState.other && lastState.other.inArea === false) {
      el.textContent = "相手が渋谷エリアの外にいるため、距離を計算できません";
      el.className = "warn-banner";
      wrap.style.display = "block";
      if (distanceCard) distanceCard.classList.remove("is-stale");
      return;
    }

    var otherUpdatedAt = lastState.other && lastState.other.lastUpdatedAt;
    var isStale = !!otherUpdatedAt && (Date.now() - otherUpdatedAt) > LOCATION_STALE_MS;
    if (distanceCard) distanceCard.classList.toggle("is-stale", isStale);
    if (isStale) {
      el.textContent = "相手の位置が古くなっています";
      el.className = "warn-banner";
      wrap.style.display = "block";
      return;
    }

    wrap.style.display = "none";
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

    updateStatusBanner();

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
      if (!judgeFoundNotified && host && host.haptic) host.haptic("success");
      judgeFoundNotified = true;
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
    if (data.reason === "not_found") {
      // 距離・階のゲートは通ったが、Jev(または距離のみ判定)が「まだ会えたとは言えない」と
      // 判定したケース。理由を出さず沈黙すると「押しても反応がない」ように見えてしまうため、
      // 再挑戦を促す文言を出す(残りJev呼び出し回数が分かれば併記する)。
      var remaining = typeof data.remainingJevCalls === "number" ? data.remainingJevCalls : null;
      note.textContent = "まだ判定できませんでした。相手の姿が見えたらもう一度押してください" + (remaining != null ? "(残り" + remaining + "回)" : "");
      return;
    }
    var reasonText = {
      too_far: "まだ" + MEET_DISTANCE_M + "m以内に近づいていません" + (data.distance_m != null ? "(現在約" + data.distance_m + "m)" : ""),
      different_floor: "階が違います。同じ階に来てから押してください",
      missing_floor: "お互いに今いる階を選んでください",
      missing_location: "位置情報を取得中です。少し待ってからもう一度押してください",
      not_active: "まだお互いの承認が完了していません",
      judge_in_progress: "判定中です。少し待ってからもう一度押してください",
    };
    note.textContent = reasonText[data.reason] || "まだ判定できません";
  }

  function applyArrowRotation(bearingToTarget) {
    var arrow = document.getElementById("arrow");
    var rel = (bearingToTarget - heading + 360) % 360;
    arrow.style.transform = "rotate(" + rel + "deg)";
  }

  // shibuya3d.mjsモジュール自体の読み込み(import()のみ、地図のmountは含まない)。一度だけ実行し、
  // 以後は同じPromiseを返す。近くのお店(nearestShops)は地図(MapLibre GL、自ホストvendor)を
  // 待たずに使いたいので、モジュール読み込みとマウントのPromiseを分けている
  // (以前はensureShibuya3d()の完了(=地図マウント完了)を待たないとnearestShopsが使えず、
  // geo.jsの読み込みの方が先に終わって「近くのお店」が空のまま固定される競合があった)。
  function ensureShibuya3dMod() {
    if (!extrasState.shibuya3dModPromise) {
      extrasState.shibuya3dModPromise = import(ASSETS_JS_BASE + "shibuya3d.mjs" + ASSET_VERSION_QUERY).then(function (mod) {
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
      extrasState.arPromise = import(ASSETS_JS_BASE + "ar.js" + ASSET_VERSION_QUERY).then(function (mod) {
        var api = mod.mountAR(document.getElementById("ar-mount"));
        extrasState.ar = api;
        var btn = document.getElementById("ar-open-btn");
        btn.disabled = false;
        btn.textContent = "ARで探す";
        // AR部品の読み込みは3D渋谷(shibuya3d.mjs、MapLibre GL本体を含む)より遅く終わることがある。
        // そのままだと、既に届いていた自分・相手の位置がARインスタンスに一度も渡されないまま
        // (次の位置更新が来るまでmm-ar-personが表示されない)になるため、マウント直後に
        // 現在分かっている最新状態を一度だけ流し込む。
        refreshExtras();
        return api;
      });
    }
    return extrasState.arPromise;
  }

  // AR部品のgeo.js(destinationPoint/normalizeAngleDiffなどの純粋関数)を読み込む。
  // ブラウザのESモジュールキャッシュにより、同じURLの2回目以降のimport()は再フェッチされない。
  function loadGeoMod() {
    return import(ASSETS_JS_BASE + "geo.js" + ASSET_VERSION_QUERY);
  }

  // WSの最新状態(lastState)と自分の実座標(selfPos)から、3D渋谷のピン・近くのお店・ARの
  // 表示を更新する。承認前(active以外)や自分の位置がまだ無いときは何もしない。
  function refreshExtras() {
    if (!lastState || lastState.phase !== "active" || !selfPos) return;
    var state = lastState;
    var meFloor = floorLabelToInt(state.self && state.self.floor);
    var meFloorInt = meFloor == null ? 1 : meFloor;

    extrasState.lastMe = { lat: selfPos.lat, lng: selfPos.lng, floor: meFloorInt };
    ensureShibuya3d().then(function (api) { api.setMe(selfPos.lat, selfPos.lng, meFloorInt); });
    if (extrasState.ar) extrasState.ar.setMe(selfPos.lat, selfPos.lng, meFloorInt);
    if (extrasState.hq) extrasState.hq.setMe(selfPos.lat, selfPos.lng, meFloorInt);

    if (state.distance_m == null || state.bearing_deg == null) return; // 相手の位置はまだ届いていない

    var partnerName = (state.other && state.other.nickname) || "相手";
    var partnerFloor = floorLabelToInt(state.other && state.other.floor);
    var partnerFloorInt = partnerFloor == null ? 1 : partnerFloor;

    loadGeoMod().then(function (geoMod) {
      // 相手の推定座標 = 自分の実座標 + サーバーから届いた距離・方位(destinationPoint)。
      // 相手の生座標がネットワーク越しに届いているわけではない(このファイル冒頭のコメント参照)。
      var p = geoMod.destinationPoint(selfPos.lat, selfPos.lng, state.bearing_deg, state.distance_m);
      extrasState.lastPartner = { lat: p.lat, lng: p.lng, floor: partnerFloorInt, name: partnerName };
      ensureShibuya3d().then(function (api) {
        api.setPartner(p.lat, p.lng, partnerFloorInt, partnerName);
        if (!extrasState.focused) { api.focusBoth(); extrasState.focused = true; } // 初回だけ2人が収まる距離へ(以後は手動操作を尊重)
      });
      if (extrasState.ar) extrasState.ar.setPartner(p.lat, p.lng, partnerFloorInt, partnerName);
      if (extrasState.hq) extrasState.hq.setPartner(p.lat, p.lng, partnerFloorInt, partnerName);
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

  // 「高画質で見る」: PLATEAU LOD2テクスチャ付き3D Tiles(shibuya3d-hq.mjs、three.js+
  // 3d-tiles-renderer自ホスト)を全画面表示する。数十MB規模のデータなので、AR同様ボタンを
  // 押した時に初めて動的importする(mountShibuya3D/mountARと同じ「一度だけmountしPromiseを
  // 使い回す」パターン)。
  function ensureHq() {
    if (!extrasState.hqPromise) {
      extrasState.hqPromise = import(ASSETS_JS_BASE + "shibuya3d-hq.mjs" + ASSET_VERSION_QUERY).then(function (mod) {
        return mod.mountShibuyaHQ(document.getElementById("hq-mount"), {});
      }).then(function (api) {
        extrasState.hq = api;
        // 既に分かっている自分・相手の位置があれば、開いた瞬間に反映する
        // (承認済みのクライアント側state。refreshExtras()と同じデータ、新しい計算はしない)。
        if (extrasState.lastMe) api.setMe(extrasState.lastMe.lat, extrasState.lastMe.lng, extrasState.lastMe.floor);
        if (extrasState.lastPartner) {
          api.setPartner(extrasState.lastPartner.lat, extrasState.lastPartner.lng, extrasState.lastPartner.floor, extrasState.lastPartner.name);
        }
        return api;
      });
    }
    return extrasState.hqPromise;
  }

  function bindHqOverlay() {
    var overlay = document.getElementById("hq-fullscreen");
    var openBtn = document.getElementById("hq-open-btn");
    var closeBtn = document.getElementById("hq-close-btn");
    openBtn.onclick = function () {
      overlay.hidden = false;
      ensureHq();
    };
    closeBtn.onclick = function () {
      overlay.hidden = true;
    };
  }

  // VRメガネボタン: WebXR(immersive-ar/immersive-vr)に対応した端末でのみ表示する実験的機能。
  // AR部品のvr.js側でiPhone/Vision Proは明示的に対象外にしている。初回「ARで探す」タップ時に
  // 一度だけ対応判定を行う(判定にnavigator.xrへの問い合わせが要るため、使わないなら省く)。
  function offerVrButton(vrBtn) {
    if (extrasState.vrChecked) return;
    extrasState.vrChecked = true;
    import(ASSETS_JS_BASE + "vr.js" + ASSET_VERSION_QUERY).then(function (vrMod) {
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
    // アプリ版は端末のコンパス(CoreLocationの方位)を直接使う。使えたら許可ボタンは出さない。
    if (host && host.watchHeading && host.watchHeading(function (h) {
      heading = h;
      if (lastState && lastState.bearing_deg != null) applyArrowRotation(lastState.bearing_deg);
    })) return;
    function onOrientation(e) {
      var h = null;
      if (typeof e.webkitCompassHeading === "number") h = e.webkitCompassHeading;
      else if (e.alpha != null) h = 360 - e.alpha;
      if (h != null) {
        heading = h;
        if (lastState && lastState.bearing_deg != null) applyArrowRotation(lastState.bearing_deg);
      }
    }
    var hint = document.getElementById("orientation-permission-hint");
    if (typeof DeviceOrientationEvent !== "undefined" && typeof DeviceOrientationEvent.requestPermission === "function") {
      var btn = document.getElementById("orientation-permission-btn");
      btn.style.display = "inline-block";
      if (hint) hint.style.display = "block";
      btn.onclick = function () {
        DeviceOrientationEvent.requestPermission().then(function (res) {
          if (res === "granted") {
            window.addEventListener("deviceorientation", onOrientation);
            btn.style.display = "none";
            if (hint) hint.style.display = "none";
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
    var geo = (host && host.geolocation) || navigator.geolocation; // アプリ版はOSの位置情報(ネイティブ)
    if (!geo) return;
    geo.watchPosition(
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
  }

  // 「共有する」ボタン: navigator.shareに対応していればOSの共有シートを開く。
  // 非対応端末(主にPC Safari以外のデスクトップブラウザ)ではリンクをコピーして代替する。
  function bindShareButton(url, hostName) {
    document.getElementById("share-invite-btn").onclick = function () {
      var text = (hostName || "") + "さんから渋谷マチマチの招待です";
      if (host && host.share) { host.share({ title: "渋谷マチマチ", text: text, url: url }); return; }
      if (navigator.share) {
        navigator.share({ title: "渋谷マチマチ", text: text, url: url }).catch(function () {});
      } else {
        copyToClipboard(url);
      }
    };
  }

  function initCreateScreen() {
    showOnly("create");
    document.getElementById("create-btn").onclick = function () {
      var nickname = document.getElementById("create-nickname").value.trim();
      if (!nickname) { showError("ニックネームを入力してください"); return; }
      apiFetch("/api/rooms", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ nickname: nickname }),
      }).then(function (r) { return r.json(); }).then(function (data) {
        if (!data.ok) {
          if (data.reason === "rate_limited") { showError(data.message || "しばらく時間をおいてから、もう一度お試しください。"); return; }
          showError("作成に失敗しました(" + data.reason + ")");
          return;
        }
        saveSession(data.roomId, "host", data.hostSecret);
        var inviteUrl = PUBLIC_ORIGIN + "/r/" + data.roomId + "?invite=" + data.inviteToken;
        history.replaceState(null, "", "/r/" + data.roomId);
        document.getElementById("invite-url-input").value = inviteUrl;
        buildShareLinks(inviteUrl, nickname);
        bindShareButton(inviteUrl, nickname);
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
    apiFetch("/api/rooms/" + roomId + "/preview?invite=" + encodeURIComponent(invite))
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
          apiFetch("/api/rooms/" + roomId + "/join", {
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

  // 行き止まり画面(満員/エラー/期限切れ/停止済み)の「新しく待ち合わせを作る」ボタン。
  // 作成画面("/new")へ普通に遷移するだけ(sessionStorageの部屋別キーは新しい部屋IDでは参照されないため、
  // 特別な後始末は不要)。
  function bindRestartButtons() {
    var buttons = document.querySelectorAll(".restart-btn");
    for (var i = 0; i < buttons.length; i++) {
      buttons[i].onclick = function () { location.href = "/new"; };
    }
  }

  // LINE/X(旧Twitter)/Instagram/Facebook等のアプリ内ブラウザ(WebView)は、getUserMedia(AR用カメラ)や
  // DeviceOrientationEvent.requestPermission(iOSの向きセンサー許可)が制限されていることが多いため、
  // 標準ブラウザで開き直すよう促す。UAでの判定はベストエフォート(将来UAが変わる可能性はある)。
  function isInAppBrowser() {
    var ua = navigator.userAgent || "";
    return /Line\//i.test(ua) || /FBAN|FBAV/i.test(ua) || /Instagram/i.test(ua) || /Twitter/i.test(ua) || /MicroMessenger/i.test(ua);
  }
  function bindInAppBrowserBanner() {
    if (!isInAppBrowser()) return;
    var el = document.getElementById("in-app-browser-banner");
    if (el) el.classList.add("visible");
  }

  function main() {
    bindMeetControls();
    bindArOverlay();
    bindHqOverlay();
    bindRestartButtons();
    bindInAppBrowserBanner();
    // WSが止まっていても「最終更新から何秒経ったか」の表示(通信切れバナー・古い位置の薄表示)を
    // 進めるための定期再評価。renderMeet()を経由しない軽量な関数なので、頻度が高くても負荷は小さい。
    setInterval(updateStatusBanner, STATUS_BANNER_POLL_MS);
    var m = location.pathname.match(/^\/r\/([a-f0-9]{32})$/);
    if (m) { initRoomScreen(m[1]); return; }
    if (location.pathname === "/new") { initCreateScreen(); return; }
    showError("ページが見つかりません");
  }

  document.addEventListener("DOMContentLoaded", main);
})();
