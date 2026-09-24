/**
 * 部屋(待ち合わせ)の状態機械。副作用なしの純粋関数だけで構成する。
 * Durable Object(room-do.js)は、この状態オブジェクトを storage に出し入れするだけの
 * 薄いラッパーにして、承認フロー・満員判定・停止・エリア制限・判定ゲートのロジックは
 * すべてここでユニットテストできるようにする(geo.js と同じ設計方針)。
 *
 * 同意フロー:
 *   1. createRoom: Aがニックネームだけで部屋を作る。招待トークンを1つ発行する。
 *   2. joinRoom: Bが招待トークンでニックネームを添えて参加する。
 *      「承認して参加」ボタン = Bの同意そのものなので、参加と同時に guest.approved=true。
 *   3. approveHost: Aが「この人と共有する」を押して host.approved=true にする。
 *   4. isActive() が true (=両者approved) になって初めて updateLocation を受け付ける。
 *      意図的な簡略化: 承認前の位置は一切保存しない(サーバー側もゼロ知識に保つ)。
 *      「本人の合意なく位置を溜め込まない」を優先し、承認後に届いた位置だけを保持する設計。
 */
import { distanceMeters, bearingDegrees, isWithinRadius, isValidCoordinate } from "./geo.js";
import { floorDiffLabel, isValidFloor, sameFloor } from "./floors.js";
import {
  SHIBUYA_STATION,
  SHIBUYA_RADIUS_M,
  ROOM_TTL_MS,
  MEET_DISTANCE_M,
  MAX_JUDGE_CALLS,
  LOCATION_STALE_MS,
} from "./constants.js";

export const ERROR_CODES = Object.freeze({
  INVALID_NICKNAME: "invalid_nickname",
  EXPIRED: "expired",
  FULL: "full",
  INVALID_INVITE: "invalid_invite",
  NO_GUEST: "no_guest",
  UNAUTHORIZED: "unauthorized",
  STOPPED: "stopped",
  INVALID_LOCATION: "invalid_location",
  INVALID_FLOOR: "invalid_floor",
  NOT_ACTIVE: "not_active",
});

export class RoomError extends Error {
  constructor(code, message) {
    super(message || code);
    this.name = "RoomError";
    this.code = code;
  }
}

const MAX_NICKNAME_LEN = 20;

export function randomToken() {
  return crypto.randomUUID().replace(/-/g, "");
}

function clone(room) {
  return structuredClone(room);
}

// C0(\u0000-\u001F)・DEL(\u007F)・C1(\u0080-\u009F)制御文字を除去する(M4セキュリティ対応)。
// 除去後に空/上限超になる場合は通常のinvalid_nicknameとして弾く。
function stripControlCharacters(raw) {
  return raw.replace(/[\u0000-\u001F\u007F-\u009F]/g, "");
}

function assertNickname(nickname) {
  const trimmed = typeof nickname === "string" ? stripControlCharacters(nickname).trim() : "";
  if (!trimmed || trimmed.length > MAX_NICKNAME_LEN) {
    throw new RoomError(ERROR_CODES.INVALID_NICKNAME, "ニックネームは1〜20文字で入力してください");
  }
  return trimmed;
}

// GPSのaccuracy(メートル)は未指定(null/undefined)を許すが、指定されるなら有限の0以上
function isValidAccuracy(acc) {
  return acc === undefined || acc === null || (typeof acc === "number" && Number.isFinite(acc) && acc >= 0);
}

function newParticipant(nickname, { approved }) {
  return {
    nickname,
    secret: randomToken(),
    approved,
    connected: false,
    floor: null,
    lastLocation: null, // { lat, lng, acc, updatedAt } | null。isActiveになるまで一切書かない
    inArea: null,
  };
}

export function createRoom({ hostNickname, roomId, now = Date.now() }) {
  const nickname = assertNickname(hostNickname);
  return {
    roomId,
    createdAt: now,
    expiresAt: now + ROOM_TTL_MS,
    inviteToken: randomToken(),
    inviteUsed: false,
    host: newParticipant(nickname, { approved: false }),
    guest: null,
    stopped: null,
    judge: {
      callCount: 0,
      found: false,
      probability: null,
      source: null,
      at: null,
      limitReached: false,
    },
  };
}

export function isExpired(room, now = Date.now()) {
  return now >= room.expiresAt;
}

export function isActive(room, now = Date.now()) {
  return (
    !isExpired(room, now) &&
    !room.stopped &&
    !!room.guest &&
    room.host.approved &&
    room.guest.approved
  );
}

// 参加前のプレビュー(招待リンクを開いた直後、Bのニックネーム入力前)に使う。副作用なし。
export function previewRoom(room, inviteToken, now = Date.now()) {
  if (isExpired(room, now)) return { ok: false, reason: ERROR_CODES.EXPIRED };
  if (room.guest || room.inviteUsed) return { ok: false, reason: ERROR_CODES.FULL };
  if (inviteToken !== room.inviteToken) return { ok: false, reason: ERROR_CODES.INVALID_INVITE };
  return { ok: true, hostNickname: room.host.nickname };
}

export function joinRoom(room, { inviteToken, nickname, now = Date.now() }) {
  if (isExpired(room, now)) throw new RoomError(ERROR_CODES.EXPIRED, "この待ち合わせは終了しました");
  if (room.guest || room.inviteUsed) throw new RoomError(ERROR_CODES.FULL, "この待ち合わせは満員です");
  if (inviteToken !== room.inviteToken) {
    throw new RoomError(ERROR_CODES.INVALID_INVITE, "招待リンクが無効です");
  }
  const clean = assertNickname(nickname);
  const next = clone(room);
  next.guest = newParticipant(clean, { approved: true }); // 「承認して参加」=Bの同意そのもの
  next.inviteUsed = true;
  return next;
}

export function authenticate(room, role, secret) {
  const participant = room[role];
  return !!participant && !!secret && participant.secret === secret;
}

export function approveHost(room, { secret, now = Date.now() }) {
  if (isExpired(room, now)) throw new RoomError(ERROR_CODES.EXPIRED);
  if (room.stopped) throw new RoomError(ERROR_CODES.STOPPED);
  if (!authenticate(room, "host", secret)) throw new RoomError(ERROR_CODES.UNAUTHORIZED);
  if (!room.guest) throw new RoomError(ERROR_CODES.NO_GUEST, "まだ相手が参加していません");
  const next = clone(room);
  next.host.approved = true;
  return next;
}

export function markConnected(room, role, connected) {
  if (!room[role]) return room;
  const next = clone(room);
  next[role].connected = connected;
  return next;
}

export function setFloor(room, { role, secret, floor, now = Date.now() }) {
  if (isExpired(room, now)) throw new RoomError(ERROR_CODES.EXPIRED);
  if (room.stopped) throw new RoomError(ERROR_CODES.STOPPED);
  if (!authenticate(room, role, secret)) throw new RoomError(ERROR_CODES.UNAUTHORIZED);
  if (!isValidFloor(floor)) throw new RoomError(ERROR_CODES.INVALID_FLOOR, "フロアの指定が不正です");
  const next = clone(room);
  next[role].floor = floor;
  return next;
}

// 意図的な簡略化: isActiveになる前は座標を一切保存しない(合意前ゼロ知識)。
// 本格対応でホスト側の「承認待ち中に自分の位置だけ先に確定させたい」要望が出た場合は、
// ここを「保存はするが buildPublicState 側で隠す」方式に切り替えるのが入口。
export function updateLocation(room, { role, secret, lat, lng, acc, now = Date.now() }) {
  if (isExpired(room, now)) throw new RoomError(ERROR_CODES.EXPIRED);
  if (!authenticate(room, role, secret)) throw new RoomError(ERROR_CODES.UNAUTHORIZED);
  if (room.stopped) return { room, accepted: false, reason: ERROR_CODES.STOPPED };
  if (!isActive(room, now)) return { room, accepted: false, reason: ERROR_CODES.NOT_ACTIVE };
  if (!isValidCoordinate(lat, lng) || !isValidAccuracy(acc)) {
    throw new RoomError(ERROR_CODES.INVALID_LOCATION, "位置情報が不正です");
  }

  const inArea = isWithinRadius(lat, lng, SHIBUYA_STATION.lat, SHIBUYA_STATION.lng, SHIBUYA_RADIUS_M);
  const next = clone(room);
  if (!inArea) {
    next[role].inArea = false;
    next[role].lastLocation = null; // エリア外の座標は保存しない
    return { room: next, accepted: false, reason: "out_of_area" };
  }
  next[role].inArea = true;
  next[role].lastLocation = { lat, lng, acc: acc ?? null, updatedAt: now };
  return { room: next, accepted: true };
}

export function stopSharing(room, { role, secret, now = Date.now() }) {
  if (!authenticate(room, role, secret)) throw new RoomError(ERROR_CODES.UNAUTHORIZED);
  if (room.stopped) return room; // 既に停止済みなら何もしない(冪等)
  const next = clone(room);
  next.stopped = { by: role, at: now };
  // 共有停止時点で座標は即座に消す(3時間の自動失効を待たない)
  if (next.host.lastLocation) next.host.lastLocation = null;
  if (next.guest?.lastLocation) next.guest.lastLocation = null;
  return next;
}

function locationIsFresh(participant, now) {
  return !!participant?.lastLocation && now - participant.lastLocation.updatedAt <= LOCATION_STALE_MS;
}

// 「会えた！」ボタン押下時のゲート判定。Jevを呼ぶ前にここで足切りすることで、
// 20m以内・同じ階のときだけ実際にAPIコストが発生するようにする。
export function canAttemptJudge(room, now = Date.now()) {
  if (!isActive(room, now)) return { ok: false, reason: ERROR_CODES.NOT_ACTIVE };
  const { host, guest } = room;
  if (!locationIsFresh(host, now) || !locationIsFresh(guest, now) || !host.inArea || !guest.inArea) {
    return { ok: false, reason: "missing_location" };
  }
  if (!host.floor || !guest.floor) {
    return { ok: false, reason: "missing_floor" };
  }
  const distance_m = Math.round(
    distanceMeters(host.lastLocation.lat, host.lastLocation.lng, guest.lastLocation.lat, guest.lastLocation.lng),
  );
  if (!sameFloor(host.floor, guest.floor)) {
    return { ok: false, reason: "different_floor", distance_m };
  }
  if (distance_m > MEET_DISTANCE_M) {
    return { ok: false, reason: "too_far", distance_m };
  }
  return { ok: true, distance_m };
}

export function recordJudgeResult(room, { found, probability, source, now = Date.now() }) {
  const next = clone(room);
  if (source === "jev") next.judge.callCount += 1; // 距離だけの判定はJev呼び出し数に数えない
  next.judge.found = !!found;
  next.judge.probability = typeof probability === "number" ? probability : null;
  next.judge.source = source;
  next.judge.at = now;
  next.judge.limitReached = next.judge.callCount >= MAX_JUDGE_CALLS;
  return next;
}

// WSで各参加者に送る公開状態。lat/lngはここを含めどこにも現れない(距離・方角のみ)。
export function buildPublicState(room, viewerRole, now = Date.now()) {
  const otherRole = viewerRole === "host" ? "guest" : "host";
  const self = room[viewerRole];
  const otherP = room[otherRole];
  const expired = isExpired(room, now);
  const active = !expired && isActive(room, now);

  let phase = "waiting_guest";
  if (expired) phase = "expired";
  else if (room.stopped) phase = "stopped";
  else if (!room.guest) phase = "waiting_guest";
  else if (!room.host.approved) phase = "waiting_host_approval";
  else phase = "active";

  let distance_m = null;
  let bearing_deg = null;
  let floorDiffText = null;
  if (active && self?.lastLocation && otherP?.lastLocation) {
    distance_m = Math.round(
      distanceMeters(self.lastLocation.lat, self.lastLocation.lng, otherP.lastLocation.lat, otherP.lastLocation.lng),
    );
    bearing_deg = Math.round(
      bearingDegrees(self.lastLocation.lat, self.lastLocation.lng, otherP.lastLocation.lat, otherP.lastLocation.lng),
    );
  }
  if (active && self?.floor && otherP?.floor) {
    floorDiffText = floorDiffLabel(self.floor, otherP.floor);
  }

  return {
    type: "state",
    role: viewerRole,
    phase,
    roomId: room.roomId,
    expiresAt: room.expiresAt,
    self: self
      ? { nickname: self.nickname, approved: self.approved, floor: self.floor, inArea: self.inArea }
      : null,
    other: otherP
      ? {
          nickname: otherP.nickname,
          approved: otherP.approved,
          connected: !!otherP.connected,
          inArea: active ? otherP.inArea : null,
          floor: active ? otherP.floor : null,
          lastUpdatedAt: active ? (otherP.lastLocation?.updatedAt ?? null) : null,
        }
      : null,
    distance_m,
    bearing_deg,
    floorDiffText,
    stopped: room.stopped,
    judge: {
      found: room.judge.found,
      probability: room.judge.probability,
      source: room.judge.source,
      at: room.judge.at,
      callsUsed: room.judge.callCount,
      maxCalls: MAX_JUDGE_CALLS,
      limitReached: room.judge.limitReached,
    },
  };
}
