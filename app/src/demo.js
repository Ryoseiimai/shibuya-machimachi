// 渋谷マチマチ iOSアプリの「デモで試す」。
// 1台で待ち合わせの流れ(招待→相手の参加→承認→距離と矢印→3D・お店・AR→会えた!)を体験できるよう、
// サーバーの代わりに端末の中で相手「すず」の参加と移動を模擬する。
//   - fetch/WebSocketを端末内の模擬に差し替える(何も送信しない)
//   - 自分の位置は実際の位置情報を使わず、渋谷駅前の固定点にする(渋谷の外にいても試せる)
//   - 画面の描画は本物と同じ app.js がそのまま行う(サーバーと同じ形の state を渡すだけ)
(function () {
  "use strict";
  var host = window.MachimachiHost;
  if (!host) return;

  var DEMO_ROOM_ID = host.demoRoomId;
  var DEMO_INVITE_TEXT = (host.apiBase || "") + "/r/demo（デモ用のリンク）";
  var PARTNER_NICKNAME = "すず";
  // 自分の位置(デモ用の固定点。渋谷駅ハチ公口の駅前広場あたり)
  var SELF_POS = { lat: 35.65905, lng: 139.70058 };
  var SELF_ACCURACY_M = 8;
  // 相手の出発点: 自分から見て北西(道玄坂・センター街方面)に約260m
  var PARTNER_START_BEARING_DEG = 300;
  var PARTNER_START_DISTANCE_M = 260;
  var WALK_SPEED_MPS = 5; // デモなので実際(約1.4m/s)より速く歩く
  var ARRIVE_DISTANCE_M = 6; // これ以上は近づかない
  var PARTNER_START_FLOOR = "2F";
  var PARTNER_ARRIVE_FLOOR = "1F";
  var FLOOR_CHANGE_DISTANCE_M = 60; // ここまで来たら相手が1階に降りてくる
  var SELF_DEFAULT_FLOOR = "1F";
  var TICK_MS = 1000;
  var JOIN_DELAY_MS = 3000;
  var MEET_DISTANCE_M = 20; // worker/src/constants.js の MEET_DISTANCE_M と同じ
  var ROOM_TTL_MS = 3 * 60 * 60 * 1000;
  var FLOORS = ["B5", "B4", "B3", "B2", "B1", "1F", "2F", "3F", "4F", "5F", "6F", "7F", "8F", "9F", "10F"];
  var OPEN = 1;
  var CLOSED = 3;

  var geoModPromise = null;
  function loadGeo() {
    if (!geoModPromise) geoModPromise = import("/assets/js/geo.js");
    return geoModPromise;
  }

  // worker/src/floors.js の floorDiffLabel と同じ文言
  function floorDiffLabel(myFloor, otherFloor) {
    var a = FLOORS.indexOf(myFloor);
    var b = FLOORS.indexOf(otherFloor);
    if (a < 0 || b < 0) return "相手のフロアは未設定です";
    var diff = b - a;
    if (diff === 0) return "相手は同じ階にいます";
    if (diff > 0) return "相手は" + diff + "つ上の階にいます";
    return "相手は" + Math.abs(diff) + "つ下の階にいます";
  }

  var room = null;
  var socket = null;
  var geo = null;
  var timers = [];

  function later(fn, ms) {
    timers.push(setTimeout(fn, ms));
  }
  function every(fn, ms) {
    timers.push(setInterval(fn, ms));
  }

  function newRoom(hostNickname) {
    var now = Date.now();
    return {
      hostNickname: hostNickname,
      phase: "waiting_guest",
      createdAt: now,
      selfFloor: null,
      partnerFloor: PARTNER_START_FLOOR,
      partner: null,
      partnerUpdatedAt: null,
      stopped: null,
      judge: { found: false, probability: null, source: null, at: null, callCount: 0 },
    };
  }

  function distanceAndBearing() {
    if (!geo || !room.partner) return { distance_m: null, bearing_deg: null };
    return {
      distance_m: Math.round(geo.distanceMeters(SELF_POS.lat, SELF_POS.lng, room.partner.lat, room.partner.lng)),
      bearing_deg: Math.round(geo.bearingDegrees(SELF_POS.lat, SELF_POS.lng, room.partner.lat, room.partner.lng)),
    };
  }

  // worker/src/room.js の buildPublicState(viewer=host) と同じ形
  function publicState() {
    var active = room.phase === "active";
    var db = active ? distanceAndBearing() : { distance_m: null, bearing_deg: null };
    return {
      type: "state",
      role: "host",
      phase: room.phase,
      roomId: DEMO_ROOM_ID,
      expiresAt: room.createdAt + ROOM_TTL_MS,
      self: { nickname: room.hostNickname, approved: active, floor: room.selfFloor, inArea: true },
      other:
        room.phase === "waiting_guest"
          ? null
          : {
              nickname: PARTNER_NICKNAME,
              approved: true,
              connected: true,
              inArea: active ? true : null,
              floor: active ? room.partnerFloor : null,
              lastUpdatedAt: active ? room.partnerUpdatedAt : null,
            },
      distance_m: db.distance_m,
      bearing_deg: db.bearing_deg,
      floorDiffText: active && room.selfFloor && room.partnerFloor ? floorDiffLabel(room.selfFloor, room.partnerFloor) : null,
      stopped: room.stopped,
      judge: {
        found: room.judge.found,
        probability: room.judge.probability,
        source: room.judge.source,
        at: room.judge.at,
        callsUsed: 0,
        maxCalls: 10,
        limitReached: false,
      },
    };
  }

  function emit(data) {
    if (!socket || socket.readyState !== OPEN || !socket.onmessage) return;
    socket.onmessage({ data: JSON.stringify(data) });
  }
  function emitState() {
    emit(publicState());
  }

  function stepPartner() {
    if (!room || room.phase !== "active" || !geo || !room.partner) return;
    var d = geo.distanceMeters(room.partner.lat, room.partner.lng, SELF_POS.lat, SELF_POS.lng);
    if (d > ARRIVE_DISTANCE_M) {
      var step = Math.min(WALK_SPEED_MPS * (TICK_MS / 1000), d - ARRIVE_DISTANCE_M);
      var toSelf = geo.bearingDegrees(room.partner.lat, room.partner.lng, SELF_POS.lat, SELF_POS.lng);
      room.partner = geo.destinationPoint(room.partner.lat, room.partner.lng, toSelf, step);
      d -= step;
    }
    if (d <= FLOOR_CHANGE_DISTANCE_M) room.partnerFloor = PARTNER_ARRIVE_FLOOR;
    room.partnerUpdatedAt = Date.now();
    emitState();
  }

  function startWalking() {
    loadGeo().then(function (mod) {
      geo = mod;
      room.partner = geo.destinationPoint(SELF_POS.lat, SELF_POS.lng, PARTNER_START_BEARING_DEG, PARTNER_START_DISTANCE_M);
      room.partnerUpdatedAt = Date.now();
      emitState();
      every(stepPartner, TICK_MS);
    });
  }

  function presetSelfFloor() {
    var select = document.getElementById("floor-select");
    if (!select || select.value) return;
    select.value = SELF_DEFAULT_FLOOR;
    select.dispatchEvent(new Event("change"));
  }

  function handleJudge() {
    var db = distanceAndBearing();
    var reason = null;
    if (!room.selfFloor || !room.partnerFloor) reason = "missing_floor";
    else if (db.distance_m == null) reason = "missing_location";
    else if (db.distance_m > MEET_DISTANCE_M) reason = "too_far";
    else if (room.selfFloor !== room.partnerFloor) reason = "different_floor";
    if (reason) {
      emit({ type: "judgeResult", ok: false, reason: reason, distance_m: db.distance_m });
      return;
    }
    room.judge = { found: true, probability: null, source: "distance_only", at: Date.now(), callCount: 0 };
    emitState();
  }

  function handleMessage(msg) {
    if (!room || !msg || typeof msg.type !== "string") return;
    if (msg.type === "approve" && room.phase === "waiting_host_approval") {
      room.phase = "active";
      emitState();
      startWalking();
      later(presetSelfFloor, 300);
      showBanner();
    } else if (msg.type === "floor" && FLOORS.indexOf(msg.floor) >= 0) {
      room.selfFloor = msg.floor;
      emitState();
    } else if (msg.type === "judge" && room.phase === "active") {
      handleJudge();
    } else if (msg.type === "stop" && !room.stopped) {
      room.stopped = { by: "host", at: Date.now() };
      room.phase = "stopped";
      emitState();
      stopTimers();
    }
    // "location" は無視する(デモの自分の位置は固定点で、端末の外にも出さない)
  }

  function stopTimers() {
    while (timers.length) {
      var t = timers.pop();
      clearTimeout(t);
      clearInterval(t);
    }
  }

  function FakeSocket() {
    var self = this;
    this.readyState = 0;
    this.onopen = null;
    this.onmessage = null;
    this.onclose = null;
    this.onerror = null;
    socket = this;
    setTimeout(function () {
      self.readyState = OPEN;
      if (self.onopen) self.onopen({});
      var input = document.getElementById("invite-url-input");
      if (input) input.value = DEMO_INVITE_TEXT;
      emitState();
      if (room.phase === "waiting_guest") {
        later(function () {
          room.phase = "waiting_host_approval";
          emitState();
        }, JOIN_DELAY_MS);
      }
    }, 50);
  }
  FakeSocket.prototype.send = function (text) {
    var msg = null;
    try {
      msg = JSON.parse(text);
    } catch (e) {
      return;
    }
    handleMessage(msg);
  };
  FakeSocket.prototype.close = function () {
    this.readyState = CLOSED;
  };

  function jsonResponse(data) {
    return Promise.resolve(new Response(JSON.stringify(data), { headers: { "content-type": "application/json" } }));
  }

  var demoApi = {
    fetch: function (url, init) {
      var method = (init && init.method) || "GET";
      if (/\/api\/rooms$/.test(url) && method === "POST") {
        var body = {};
        try {
          body = JSON.parse((init && init.body) || "{}");
        } catch (e) {
          body = {};
        }
        room = newRoom(body.nickname || "あなた");
        return jsonResponse({ ok: true, roomId: DEMO_ROOM_ID, hostSecret: "demo", inviteToken: "demo" });
      }
      return jsonResponse({ ok: false, reason: "not_found" });
    },
    createSocket: function () {
      return new FakeSocket();
    },
    watchPosition: function (onPos) {
      function tick() {
        onPos({ coords: { latitude: SELF_POS.lat, longitude: SELF_POS.lng, accuracy: SELF_ACCURACY_M }, timestamp: Date.now() });
      }
      setTimeout(tick, 0);
      every(tick, TICK_MS);
      return "demo";
    },
    share: function () {
      alert("デモなので、招待リンクは送られません。\n実際に使うときは、ここから会う相手に1回だけ使える招待リンクを送ります。");
      return Promise.resolve();
    },
  };

  function showBanner() {
    if (document.getElementById("demo-banner")) return;
    var banner = document.createElement("div");
    banner.id = "demo-banner";
    banner.className = "demo-banner";
    var text = document.createElement("span");
    text.textContent = "デモ中：相手の「" + PARTNER_NICKNAME + "」さんは模擬の動きです（実際より速く歩きます）";
    var end = document.createElement("button");
    end.type = "button";
    end.textContent = "終了";
    end.onclick = function () {
      location.href = "/new";
    };
    banner.appendChild(text);
    banner.appendChild(end);
    var main = document.getElementById("app");
    if (main) main.insertBefore(banner, main.firstChild);
  }

  // デモ中は、LINE・コピーのボタンで架空のリンクを外に出さない
  function guardShareButtons(e) {
    if (!host.isDemo()) return;
    var target = e.target && e.target.closest ? e.target.closest("#line-share-btn, #copy-invite-btn") : null;
    if (!target) return;
    e.preventDefault();
    e.stopPropagation();
    demoApi.share();
  }

  function startDemo() {
    host.setDemo(demoApi);
    var input = document.getElementById("create-nickname");
    if (input && !input.value.trim()) input.value = "あなた";
    var btn = document.getElementById("create-btn");
    if (btn) btn.click();
  }

  document.addEventListener("click", guardShareButtons, true);
  document.addEventListener("DOMContentLoaded", function () {
    var demoBtn = document.getElementById("demo-btn");
    if (demoBtn) demoBtn.onclick = startDemo;
    // shibuyamachimachi://demo(独自スキーム)から開いたとき。app.js の初期化(同じDOMContentLoaded)の後に動かす
    if (/[?&]demo=1(&|$)/.test(location.search)) setTimeout(startDemo, 0);
  });
})();
