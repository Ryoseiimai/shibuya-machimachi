// RoomDO(Durable Objectの薄いラッパー)に対する、Miniflareなしでの単体テスト。
// Workers Runtime専用グローバル(WebSocketPair等)はテストの範囲外に必要な分だけ最小限で
// フェイクする。実際のWebSocket配線・Hibernation APIの結線はe2e(Playwright)側でカバーする。
import { test } from "node:test";
import assert from "node:assert/strict";
import { RoomDO } from "../src/room-do.js";
import { createRoom, joinRoom, approveHost, updateLocation, setFloor } from "../src/room.js";
import { SHIBUYA_STATION, MAX_JUDGE_CALLS } from "../src/constants.js";

const ROOM_KEY = "room";

function makeStorage(initial) {
  const data = new Map(initial ? [[ROOM_KEY, initial]] : []);
  return {
    data,
    getCalls: 0,
    putCalls: 0,
    async get(key) {
      this.getCalls += 1;
      return data.get(key);
    },
    async put(key, value) {
      this.putCalls += 1;
      data.set(key, value);
    },
    async setAlarm() {},
    async deleteAll() {
      data.clear();
    },
  };
}

function makeActiveRoomInMeetRange() {
  let room = createRoom({ hostNickname: "ホスト", roomId: "room-1" });
  room = joinRoom(room, { inviteToken: room.inviteToken, nickname: "ゲスト" });
  const guestSecret = room.guest.secret;
  const hostSecret = room.host.secret;
  room = approveHost(room, { secret: hostSecret });
  room = setFloor(room, { role: "host", secret: hostSecret, floor: "3F" });
  room = setFloor(room, { role: "guest", secret: guestSecret, floor: "3F" });
  const afterHost = updateLocation(room, {
    role: "host",
    secret: hostSecret,
    lat: SHIBUYA_STATION.lat,
    lng: SHIBUYA_STATION.lng,
  });
  const afterGuest = updateLocation(afterHost.room, {
    role: "guest",
    secret: guestSecret,
    lat: SHIBUYA_STATION.lat + 0.00004,
    lng: SHIBUYA_STATION.lng,
  });
  return { room: afterGuest.room, hostSecret, guestSecret };
}

// ---- H2: 「会えた」判定の同期ロック ----
test("handleJudge: 同時に2件届いても2件目はjudge_in_progressで即座に拒否され、Jev呼び出しは1回だけ", async () => {
  const { room, hostSecret } = makeActiveRoomInMeetRange();
  const storage = makeStorage(room);
  const ctx = { storage, getWebSockets: () => [] };
  const doInstance = new RoomDO(ctx, { JEV_API_KEY: "fake-key-for-test" });

  const fetchCalls = [];
  let resolveFirstFetch;
  const firstFetchGate = new Promise((resolve) => {
    resolveFirstFetch = resolve;
  });
  const originalFetch = globalThis.fetch;
  globalThis.fetch = async () => {
    fetchCalls.push(Date.now());
    await firstFetchGate; // 1件目のJev呼び出しをわざと長引かせ、2件目が追いつけるようにする
    return { ok: true, json: async () => ({ answers: { met: { type: "noul", noul: 0.91 } } }) };
  };

  try {
    const sent1 = [];
    const sent2 = [];
    const ws1 = { send: (m) => sent1.push(JSON.parse(m)) };
    const ws2 = { send: (m) => sent2.push(JSON.parse(m)) };

    const loaded = await doInstance.loadRoom();
    const p1 = doInstance.handleJudge(loaded, ws1);
    await Promise.resolve(); // p1がロック取得→fetch呼び出し直後まで進むのを待つ(マイクロタスク1回分)
    await Promise.resolve();
    const p2 = doInstance.handleJudge(loaded, ws2); // ロック中なので即座にjudge_in_progressで返るはず
    await p2;
    resolveFirstFetch();
    await p1;

    assert.equal(fetchCalls.length, 1, "Jev APIは1回しか呼ばれない(2件目はAPIに到達しない)");
    assert.ok(
      sent2.some((m) => m.type === "judgeResult" && m.reason === "judge_in_progress"),
      "2件目にはjudge_in_progressが返る",
    );
    assert.equal(sent2.length, 1, "2件目はjudge_in_progressの通知1件だけでJev結果は受け取らない");
  } finally {
    globalThis.fetch = originalFetch;
  }
});

// ---- M1: join の競合(request.json()を先読みしてstorage以外のawaitを間に挟まない) ----
test("handleJoin: request.json()を読み終えてからloadRoom(storage.get)する呼び出し順になっている", async () => {
  const room = createRoom({ hostNickname: "A", roomId: "room-2" });
  const order = [];
  const storage = makeStorage(room);
  const originalGet = storage.get.bind(storage);
  const originalPut = storage.put.bind(storage);
  storage.get = async (key) => {
    order.push("storage.get");
    return originalGet(key);
  };
  storage.put = async (key, value) => {
    order.push("storage.put");
    return originalPut(key, value);
  };
  const ctx = { storage, getWebSockets: () => [] };
  const doInstance = new RoomDO(ctx, {});

  const request = {
    json: async () => {
      order.push("request.json");
      return { invite: room.inviteToken, nickname: "ゲスト" };
    },
  };

  const res = await doInstance.handleJoin(request);
  const body = await res.json();
  assert.equal(body.ok, true);
  assert.deepEqual(
    order,
    ["request.json", "storage.get", "storage.put"],
    "request.json()の完了がstorage.get(=loadRoom)より先でなければならない(M1)",
  );
});

test("handleJoin: 同じ招待トークンへ連続で参加要求しても2人目はfullで拒否される(招待の2重消費防止)", async () => {
  const room = createRoom({ hostNickname: "A", roomId: "room-3" });
  const storage = makeStorage(room);
  const ctx = { storage, getWebSockets: () => [] };
  const doInstance = new RoomDO(ctx, {});

  // RoomError→JSONレスポンスへの変換は fetch() 側で行うため、fetch() 経由で叩く
  // (handleJoin()を直接呼ぶとRoomErrorがそのままthrowされる。room-do.jsの設計どおり)。
  const makeRequest = (nickname) => ({
    url: "https://room.internal/join",
    method: "POST",
    json: async () => ({ invite: room.inviteToken, nickname }),
  });

  const first = await doInstance.fetch(makeRequest("ゲスト1"));
  assert.equal(first.status, 200);
  const second = await doInstance.fetch(makeRequest("ゲスト2"));
  assert.equal(second.status, 409);
  const secondBody = await second.json();
  assert.equal(secondBody.ok, false);
  assert.equal(secondBody.reason, "full");
});

// ---- M2: 同一roleの多重WS接続 ----
test("handleWsUpgrade: 同じroleの既存ソケットは新規接続時にclose(4001)される", async () => {
  const room = createRoom({ hostNickname: "A", roomId: "room-4" });
  const hostSecret = room.host.secret;
  const storage = makeStorage(room);
  const closeCalls = [];
  const existingHostSocket = { close: (...args) => closeCalls.push(args) };
  const ctx = {
    storage,
    getWebSockets: (tag) => (tag === "role:host" ? [existingHostSocket] : []),
    acceptWebSocket: () => {},
  };
  const doInstance = new RoomDO(ctx, {});

  // Workers Runtime専用のWebSocketPair/101レスポンスはNode標準のfetch実装には無いため
  // 最小限のフェイクを与える。このテストの関心事(重複ソケットのclose)はそれより前で完結する。
  class FakeWebSocketPair {
    constructor() {
      this[0] = { role: "client" };
      this[1] = { role: "server", serializeAttachment() {}, send() {} };
    }
  }
  const originalPair = globalThis.WebSocketPair;
  globalThis.WebSocketPair = FakeWebSocketPair;

  const request = { headers: new Headers({ Upgrade: "websocket" }) };
  const url = new URL(`https://room.internal/ws?role=host&secret=${encodeURIComponent(hostSecret)}`);

  try {
    await doInstance.handleWsUpgrade(request, url);
  } catch (_err) {
    // status:101のResponse構築はNodeのfetch実装がサポートしないため、ここで例外になるのは想定内。
    // close()の呼び出しはそれより前の行で既に発生している。
  } finally {
    globalThis.WebSocketPair = originalPair;
  }

  assert.equal(closeCalls.length, 1, "既存の同role接続がちょうど1回closeされる");
  assert.deepEqual(closeCalls[0], [4001, "duplicate_connection"]);
});

// ---- 「会えた」判定の改善: 理由の通知・両者申告のJevコンテキスト反映 ----
test("handleJudge: 0m・同フロアで両者が60秒以内に押すとJevのcontextに反映されfound:trueになる", async () => {
  let room = createRoom({ hostNickname: "ホスト", roomId: "room-both-press" });
  room = joinRoom(room, { inviteToken: room.inviteToken, nickname: "ゲスト" });
  const guestSecret = room.guest.secret;
  const hostSecret = room.host.secret;
  room = approveHost(room, { secret: hostSecret });
  room = setFloor(room, { role: "host", secret: hostSecret, floor: "5F" });
  // ゲストはまずホストと違う階にする(1回目の押下ではゲートが通らないことを確認するため)。
  room = setFloor(room, { role: "guest", secret: guestSecret, floor: "6F" });
  const afterHost = updateLocation(room, {
    role: "host",
    secret: hostSecret,
    lat: SHIBUYA_STATION.lat,
    lng: SHIBUYA_STATION.lng,
    acc: 5,
  });
  const afterGuest = updateLocation(afterHost.room, {
    role: "guest",
    secret: guestSecret,
    lat: SHIBUYA_STATION.lat, // ホストと同じ座標(0m)
    lng: SHIBUYA_STATION.lng,
    acc: 8,
  });
  room = afterGuest.room;

  const storage = makeStorage(room);
  const ctx = { storage, getWebSockets: () => [] };
  const doInstance = new RoomDO(ctx, { JEV_API_KEY: "fake-key-for-test" });

  const capturedBodies = [];
  const originalFetch = globalThis.fetch;
  globalThis.fetch = async (url, init) => {
    capturedBodies.push(JSON.parse(init.body));
    return { ok: true, json: async () => ({ answers: { met: { type: "noul", noul: 0.95 } } }) };
  };

  try {
    const sentHost = [];
    const wsHost = { send: (m) => sentHost.push(JSON.parse(m)) };
    const wsGuest = { send: () => {} };

    // 1回目: ホストが押す。まだ階が違うのでゲートで弾かれ、Jevは呼ばれない。押下自体は記録される。
    let loaded = await doInstance.loadRoom();
    await doInstance.handleJudge(loaded, wsHost, "host");
    assert.equal(capturedBodies.length, 0, "階が違う間はJevを呼ばない");
    assert.ok(
      sentHost.some((m) => m.type === "judgeResult" && m.reason === "different_floor"),
      "1回目はdifferent_floorの理由が返る",
    );
    let afterFirstPress = await doInstance.loadRoom();
    assert.ok(afterFirstPress.judge.hostPressedAt, "ゲートが通らなくても押下時刻は記録される");

    // ゲストが階をホストに合わせてから、60秒以内に押す。
    const synced = setFloor(afterFirstPress, { role: "guest", secret: guestSecret, floor: "5F" });
    await storage.put("room", synced);

    loaded = await doInstance.loadRoom();
    await doInstance.handleJudge(loaded, wsGuest, "guest");

    assert.equal(capturedBodies.length, 1, "階が揃った2回目でJevが呼ばれる");
    assert.match(capturedBodies[0].state, /両者が60秒以内に「会えた」ボタンを押した: はい/);
    assert.match(capturedBodies[0].state, /Aさんの位置精度: 約5m/);
    assert.match(capturedBodies[0].state, /Bさんの位置精度: 約8m/);

    const finalRoom = await doInstance.loadRoom();
    assert.equal(finalRoom.judge.found, true);
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test("handleJudge: ゲートを通ってもfound:falseなら、押した本人にだけ残り回数付きの理由が届く", async () => {
  const { room, hostSecret } = makeActiveRoomInMeetRange();
  const storage = makeStorage(room);
  const ctx = { storage, getWebSockets: () => [] };
  const doInstance = new RoomDO(ctx, { JEV_API_KEY: "fake-key-for-test" });

  const originalFetch = globalThis.fetch;
  globalThis.fetch = async () => ({ ok: true, json: async () => ({ answers: { met: { type: "noul", noul: 0.1 } } }) });

  try {
    const sent = [];
    const ws = { send: (m) => sent.push(JSON.parse(m)) };
    const loaded = await doInstance.loadRoom();
    await doInstance.handleJudge(loaded, ws, "host");

    const note = sent.find((m) => m.type === "judgeResult");
    assert.ok(note, "found:falseでもjudgeResult通知が届く");
    assert.equal(note.ok, false);
    assert.equal(note.reason, "not_found");
    assert.equal(note.remainingJevCalls, MAX_JUDGE_CALLS - 1);

    const finalRoom = await doInstance.loadRoom();
    assert.equal(finalRoom.judge.found, false);
  } finally {
    globalThis.fetch = originalFetch;
  }
});

// ---- M3: WSメッセージサイズ上限 ----
test("webSocketMessage: 2KBを超えるメッセージは中身を見ずに破棄される(storageに触れない)", async () => {
  const { room } = makeActiveRoomInMeetRange();
  const storage = makeStorage(room);
  const ctx = { storage, getWebSockets: () => [] };
  const doInstance = new RoomDO(ctx, {});
  const sent = [];
  const ws = {
    deserializeAttachment: () => ({ role: "host", secret: "whatever" }),
    send: (m) => sent.push(m),
  };

  const oversized = JSON.stringify({ type: "location", lat: 1, lng: 1, pad: "a".repeat(3000) });
  assert.ok(Buffer.byteLength(oversized, "utf8") > 2048, "テストデータが実際に2KBを超えている前提の確認");

  await doInstance.webSocketMessage(ws, oversized);

  assert.equal(storage.getCalls, 0, "サイズ超過メッセージはloadRoom(storage.get)にすら到達しない");
  assert.equal(sent.length, 0, "エラー通知も送らず黙って捨てる");
});

// ---- M3: 位置情報送信の間引き(1秒1回) ----
test("webSocketMessage: locationの連投は1秒以内なら2回目以降が間引かれる", async () => {
  const { room, hostSecret } = makeActiveRoomInMeetRange();
  const storage = makeStorage(room);
  const ctx = { storage, getWebSockets: () => [] };
  const doInstance = new RoomDO(ctx, {});
  const ws = { deserializeAttachment: () => ({ role: "host", secret: hostSecret }), send: () => {} };

  const putsAfterFirst = storage.putCalls;
  await doInstance.webSocketMessage(
    ws,
    JSON.stringify({ type: "location", lat: SHIBUYA_STATION.lat, lng: SHIBUYA_STATION.lng, acc: 5 }),
  );
  const putsAfterSecondCall = storage.putCalls;
  assert.ok(putsAfterSecondCall > putsAfterFirst, "1回目のlocationは保存される");

  await doInstance.webSocketMessage(
    ws,
    JSON.stringify({ type: "location", lat: SHIBUYA_STATION.lat, lng: SHIBUYA_STATION.lng, acc: 5 }),
  );
  assert.equal(storage.putCalls, putsAfterSecondCall, "1秒以内の2回目はstorageに触れず間引かれる");
});

// ---- 道順案内: 待ち合わせ場所(スポットID)の受け渡し ----
test("webSocketMessage: spot はスポットIDだけを保存して2人に配り、不正なIDはinvalid_spotで拒否する", async () => {
  const { room, hostSecret } = makeActiveRoomInMeetRange();
  const storage = makeStorage(room);
  const sentToGuest = [];
  const guestSocket = { send: (m) => sentToGuest.push(JSON.parse(m)) };
  const ctx = { storage, getWebSockets: (tag) => (tag === "role:guest" ? [guestSocket] : []) };
  const doInstance = new RoomDO(ctx, {});
  const sentToHost = [];
  const ws = { deserializeAttachment: () => ({ role: "host", secret: hostSecret }), send: (m) => sentToHost.push(JSON.parse(m)) };

  await doInstance.webSocketMessage(ws, JSON.stringify({ type: "spot", spotId: "moyai" }));
  assert.deepEqual(storage.data.get(ROOM_KEY).meetSpot.id, "moyai");
  const guestState = sentToGuest.filter((m) => m.type === "state").pop();
  assert.deepEqual(guestState.meetSpot, { id: "moyai", byMe: false });

  await doInstance.webSocketMessage(ws, JSON.stringify({ type: "spot", spotId: { lat: 35.65, lng: 139.7 } }));
  assert.ok(sentToHost.some((m) => m.type === "error" && m.code === "invalid_spot"), "座標らしきものは受け取らない");
  assert.equal(storage.data.get(ROOM_KEY).meetSpot.id, "moyai", "拒否したら保存も変わらない");
});
