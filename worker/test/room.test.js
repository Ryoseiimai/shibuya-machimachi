import { test } from "node:test";
import assert from "node:assert/strict";
import {
  createRoom,
  previewRoom,
  joinRoom,
  approveHost,
  authenticate,
  setFloor,
  updateLocation,
  stopSharing,
  isActive,
  canAttemptJudge,
  recordJudgeResult,
  buildPublicState,
  RoomError,
  ERROR_CODES,
} from "../src/room.js";
import { SHIBUYA_STATION, MAX_JUDGE_CALLS, MEET_DISTANCE_M } from "../src/constants.js";

const ROOM_ID = "test-room-id";
const NOW = 1_700_000_000_000;

// 渋谷駅から見てだいたい5m先(緯度をわずかにずらしただけ)の近接点。会えた判定のテストに使う。
const NEAR_A = { lat: SHIBUYA_STATION.lat, lng: SHIBUYA_STATION.lng };
const NEAR_B = { lat: SHIBUYA_STATION.lat + 0.00004, lng: SHIBUYA_STATION.lng };
// 渋谷駅から約3km離れた新宿駅相当(エリア外テスト用)
const FAR_OUTSIDE = { lat: 35.6896, lng: 139.7006 };

function makeActiveRoom({ now = NOW } = {}) {
  let room = createRoom({ hostNickname: "ホスト太郎", roomId: ROOM_ID, now });
  room = joinRoom(room, { inviteToken: room.inviteToken, nickname: "ゲスト花子", now });
  const guestSecret = room.guest.secret;
  room = approveHost(room, { secret: room.host.secret, now });
  return { room, hostSecret: room.host.secret, guestSecret };
}

// ---- 必須1: 未承認では位置が届かない ----
test("未承認の間はupdateLocationが位置を保存しない(not_active)", () => {
  let room = createRoom({ hostNickname: "A", roomId: ROOM_ID, now: NOW });
  room = joinRoom(room, { inviteToken: room.inviteToken, nickname: "B", now: NOW });
  assert.equal(isActive(room, NOW), false, "ホストが未承認なのでまだactiveではない");

  const res = updateLocation(room, {
    role: "guest",
    secret: room.guest.secret,
    lat: NEAR_A.lat,
    lng: NEAR_A.lng,
    now: NOW,
  });
  assert.equal(res.accepted, false);
  assert.equal(res.reason, ERROR_CODES.NOT_ACTIVE);
  assert.equal(res.room.guest.lastLocation, null, "未承認中は座標を一切保存しない");

  // buildPublicStateからも当然距離は出てこない
  const stateForHost = buildPublicState(res.room, "host", NOW);
  assert.equal(stateForHost.distance_m, null);
  assert.equal(stateForHost.phase, "waiting_host_approval");
});

test("両者承認後はupdateLocationが位置を受け付け、距離が届く", () => {
  const { room, hostSecret, guestSecret } = makeActiveRoom();
  assert.equal(isActive(room, NOW), true);

  const afterHost = updateLocation(room, { role: "host", secret: hostSecret, ...NEAR_A, now: NOW });
  assert.equal(afterHost.accepted, true);
  const afterGuest = updateLocation(afterHost.room, { role: "guest", secret: guestSecret, ...NEAR_B, now: NOW });
  assert.equal(afterGuest.accepted, true);

  const stateForHost = buildPublicState(afterGuest.room, "host", NOW);
  assert.notEqual(stateForHost.distance_m, null);
  assert.ok(stateForHost.distance_m < 50, `expected close distance, got ${stateForHost.distance_m}`);
  assert.equal(stateForHost.phase, "active");
});

// ---- 必須2: 3人目は入れない ----
test("3人目の参加は満員(full)で拒否される", () => {
  let room = createRoom({ hostNickname: "A", roomId: ROOM_ID, now: NOW });
  const inviteToken = room.inviteToken;
  room = joinRoom(room, { inviteToken, nickname: "B", now: NOW });

  assert.throws(
    () => joinRoom(room, { inviteToken, nickname: "C", now: NOW }),
    (err) => err instanceof RoomError && err.code === ERROR_CODES.FULL,
  );

  const preview = previewRoom(room, inviteToken, NOW);
  assert.equal(preview.ok, false);
  assert.equal(preview.reason, ERROR_CODES.FULL);
});

test("無効な招待トークンではinvalid_inviteになる(3人目とは別のエラー)", () => {
  const room = createRoom({ hostNickname: "A", roomId: ROOM_ID, now: NOW });
  assert.throws(
    () => joinRoom(room, { inviteToken: "wrong-token", nickname: "B", now: NOW }),
    (err) => err instanceof RoomError && err.code === ERROR_CODES.INVALID_INVITE,
  );
});

// ---- 必須3: 停止で届かなくなる ----
test("共有をやめると位置が即座に消え、以後の更新も拒否される", () => {
  const { room, hostSecret, guestSecret } = makeActiveRoom();
  const afterHost = updateLocation(room, { role: "host", secret: hostSecret, ...NEAR_A, now: NOW });
  const afterGuest = updateLocation(afterHost.room, { role: "guest", secret: guestSecret, ...NEAR_B, now: NOW });
  assert.notEqual(afterGuest.room.host.lastLocation, null);
  assert.notEqual(afterGuest.room.guest.lastLocation, null);

  const stopped = stopSharing(afterGuest.room, { role: "guest", secret: guestSecret, now: NOW + 1000 });
  assert.equal(stopped.stopped.by, "guest");
  assert.equal(stopped.host.lastLocation, null, "停止時に相手の座標も即座に消す");
  assert.equal(stopped.guest.lastLocation, null);

  const res = updateLocation(stopped, { role: "host", secret: hostSecret, ...NEAR_A, now: NOW + 2000 });
  assert.equal(res.accepted, false);
  assert.equal(res.reason, ERROR_CODES.STOPPED);
  assert.equal(res.room.host.lastLocation, null, "停止後は新しい位置も保存されない");

  const stateForHost = buildPublicState(stopped, "host", NOW + 2000);
  assert.equal(stateForHost.phase, "stopped");
});

// ---- ボーナス: 渋谷エリア制限 ----
test("渋谷から1.5km外の位置は保存されずout_of_areaになる", () => {
  const { room, hostSecret } = makeActiveRoom();
  const res = updateLocation(room, { role: "host", secret: hostSecret, ...FAR_OUTSIDE, now: NOW });
  assert.equal(res.accepted, false);
  assert.equal(res.reason, "out_of_area");
  assert.equal(res.room.host.inArea, false);
  assert.equal(res.room.host.lastLocation, null);
});

// ---- ボーナス: 認証(secret不一致) ----
test("secretが違えばunauthorizedで拒否される(approve/floor/location/stop共通)", () => {
  const { room, hostSecret } = makeActiveRoom();
  assert.equal(authenticate(room, "host", "違うsecret"), false);
  assert.throws(() => setFloor(room, { role: "host", secret: "x", floor: "3F", now: NOW }), (e) => e.code === ERROR_CODES.UNAUTHORIZED);
  assert.throws(() => updateLocation(room, { role: "host", secret: "x", ...NEAR_A, now: NOW }), (e) => e.code === ERROR_CODES.UNAUTHORIZED);
  assert.throws(() => stopSharing(room, { role: "host", secret: "x", now: NOW }), (e) => e.code === ERROR_CODES.UNAUTHORIZED);

  let fresh = createRoom({ hostNickname: "A", roomId: ROOM_ID, now: NOW });
  fresh = joinRoom(fresh, { inviteToken: fresh.inviteToken, nickname: "B", now: NOW });
  assert.throws(() => approveHost(fresh, { secret: "x", now: NOW }), (e) => e.code === ERROR_CODES.UNAUTHORIZED);
  assert.equal(hostSecret !== "x", true);
});

test("参加者がいないうちはapproveHostがno_guestで拒否される", () => {
  const room = createRoom({ hostNickname: "A", roomId: ROOM_ID, now: NOW });
  assert.throws(
    () => approveHost(room, { secret: room.host.secret, now: NOW }),
    (e) => e.code === ERROR_CODES.NO_GUEST,
  );
});

// ---- ボーナス: フロアと「会えた？」ゲート ----
test("canAttemptJudge: フロア未設定はmissing_floor、離れていればtoo_far、揃えばok", () => {
  const { room, hostSecret, guestSecret } = makeActiveRoom();
  const afterHost = updateLocation(room, { role: "host", secret: hostSecret, ...NEAR_A, now: NOW });
  const afterGuest = updateLocation(afterHost.room, { role: "guest", secret: guestSecret, ...NEAR_B, now: NOW });

  const gate1 = canAttemptJudge(afterGuest.room, NOW);
  assert.equal(gate1.ok, false);
  assert.equal(gate1.reason, "missing_floor");

  const withFloors1 = setFloor(afterGuest.room, { role: "host", secret: hostSecret, floor: "3F", now: NOW });
  const withFloors2 = setFloor(withFloors1, { role: "guest", secret: guestSecret, floor: "5F", now: NOW });
  const gate2 = canAttemptJudge(withFloors2, NOW);
  assert.equal(gate2.ok, false);
  assert.equal(gate2.reason, "different_floor");

  const sameFloorRoom = setFloor(withFloors2, { role: "guest", secret: guestSecret, floor: "3F", now: NOW });
  const gate3 = canAttemptJudge(sameFloorRoom, NOW);
  assert.equal(gate3.ok, true);
  assert.ok(gate3.distance_m <= MEET_DISTANCE_M);
});

test("canAttemptJudge: 20mを超えて離れていればtoo_far", () => {
  const { room, hostSecret, guestSecret } = makeActiveRoom();
  const FAR_BUT_IN_AREA = { lat: SHIBUYA_STATION.lat + 0.003, lng: SHIBUYA_STATION.lng }; // 渋谷駅から約330m(エリア内・20mより遠い)
  const afterHost = updateLocation(room, { role: "host", secret: hostSecret, ...NEAR_A, now: NOW });
  const afterGuest = updateLocation(afterHost.room, { role: "guest", secret: guestSecret, ...FAR_BUT_IN_AREA, now: NOW });
  const withFloors1 = setFloor(afterGuest.room, { role: "host", secret: hostSecret, floor: "1F", now: NOW });
  const withFloors2 = setFloor(withFloors1, { role: "guest", secret: guestSecret, floor: "1F", now: NOW });

  const gate = canAttemptJudge(withFloors2, NOW);
  assert.equal(gate.ok, false);
  assert.equal(gate.reason, "too_far");
  assert.ok(gate.distance_m > MEET_DISTANCE_M);
});

test("recordJudgeResult: Jev判定だけがcallCountを消費し、上限でlimitReachedになる", () => {
  let room = makeActiveRoom().room;
  for (let i = 0; i < MAX_JUDGE_CALLS; i++) {
    room = recordJudgeResult(room, { found: false, probability: 0.1, source: "jev", now: NOW });
  }
  assert.equal(room.judge.callCount, MAX_JUDGE_CALLS);
  assert.equal(room.judge.limitReached, true);

  const beforeCount = room.judge.callCount;
  room = recordJudgeResult(room, { found: true, probability: null, source: "distance_only", now: NOW });
  assert.equal(room.judge.callCount, beforeCount, "distance_onlyはcallCountを増やさない");
  assert.equal(room.judge.found, true);
});

// ---- ボーナス: buildPublicStateは座標のキーを一切持たない ----
test("buildPublicStateのselfとotherにlat/lngのキーが存在しない", () => {
  const { room, hostSecret, guestSecret } = makeActiveRoom();
  const afterHost = updateLocation(room, { role: "host", secret: hostSecret, ...NEAR_A, now: NOW });
  const afterGuest = updateLocation(afterHost.room, { role: "guest", secret: guestSecret, ...NEAR_B, now: NOW });
  const state = buildPublicState(afterGuest.room, "host", NOW);

  assert.deepEqual(Object.keys(state.self).sort(), ["approved", "floor", "inArea", "nickname"]);
  assert.deepEqual(Object.keys(state.other).sort(), ["approved", "connected", "floor", "inArea", "lastUpdatedAt", "nickname"]);
  assert.equal(JSON.stringify(state).includes(String(NEAR_A.lat)), false);
  assert.equal(JSON.stringify(state).includes(String(NEAR_B.lng)), false);
});

test("expiresAtはROOM_TTL_MS(3時間)後に設定される", () => {
  const room = createRoom({ hostNickname: "A", roomId: ROOM_ID, now: NOW });
  assert.equal(room.expiresAt - room.createdAt, 3 * 60 * 60 * 1000);
});

// ---- M4セキュリティ対応: 入力検証 ----
test("ニックネームの制御文字は除去され、除去後が空なら invalid_nickname になる", () => {
  const room = createRoom({ hostNickname: "り\u0000ょう\u0007せい", roomId: ROOM_ID, now: NOW });
  assert.equal(room.host.nickname, "りょうせい", "制御文字だけが取り除かれる");

  assert.throws(
    () => createRoom({ hostNickname: "\u0000\u0001\u0002", roomId: ROOM_ID, now: NOW }),
    (e) => e.code === ERROR_CODES.INVALID_NICKNAME,
    "制御文字を除去した結果が空文字ならinvalid_nickname",
  );
});

test("updateLocation: 範囲外(緯度91度)やInfinityの座標はinvalid_locationで拒否される", () => {
  const { room, hostSecret } = makeActiveRoom();
  assert.throws(
    () => updateLocation(room, { role: "host", secret: hostSecret, lat: 91, lng: 139.7, now: NOW }),
    (e) => e.code === ERROR_CODES.INVALID_LOCATION,
  );
  assert.throws(
    () => updateLocation(room, { role: "host", secret: hostSecret, lat: Infinity, lng: 139.7, now: NOW }),
    (e) => e.code === ERROR_CODES.INVALID_LOCATION,
  );
});

test("updateLocation: accが負の数や有限でない場合はinvalid_locationで拒否される(未指定は許可)", () => {
  const { room, hostSecret } = makeActiveRoom();
  assert.throws(
    () => updateLocation(room, { role: "host", secret: hostSecret, ...NEAR_A, acc: -1, now: NOW }),
    (e) => e.code === ERROR_CODES.INVALID_LOCATION,
  );
  assert.throws(
    () => updateLocation(room, { role: "host", secret: hostSecret, ...NEAR_A, acc: Infinity, now: NOW }),
    (e) => e.code === ERROR_CODES.INVALID_LOCATION,
  );
  const ok = updateLocation(room, { role: "host", secret: hostSecret, ...NEAR_A, now: NOW }); // acc未指定
  assert.equal(ok.accepted, true);
});

test("setFloor: FLOORSに無い値(B6・11F・3.5F等)はinvalid_floorで拒否される", () => {
  const { room, hostSecret } = makeActiveRoom();
  for (const bad of ["B6", "11F", "3.5F", "", "3f", 3]) {
    assert.throws(
      () => setFloor(room, { role: "host", secret: hostSecret, floor: bad, now: NOW }),
      (e) => e.code === ERROR_CODES.INVALID_FLOOR,
      `floor=${JSON.stringify(bad)} should be rejected`,
    );
  }
});
