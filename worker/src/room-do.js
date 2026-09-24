/**
 * RoomDO: 1部屋(=1組の待ち合わせ)を担当するDurable Object。
 * SQLiteバックエンド(無料プランで利用可。wrangler.tomlのmigrationsで
 * new_sqlite_classesを指定)。状態そのものは room.js の純粋関数で作り、
 * ここでは storage への出し入れとWebSocket配線(Hibernation API)だけを行う。
 *
 * WebSocket接続ごとに serializeAttachment({role, secret}) で認証情報を貼り付け、
 * ハイバネーションから復帰しても誰の接続かをActor自身のメモリに頼らず判別できるようにする。
 */
import {
  createRoom,
  previewRoom,
  joinRoom,
  approveHost,
  authenticate,
  setFloor,
  updateLocation,
  stopSharing,
  canAttemptJudge,
  recordJudgeResult,
  buildPublicState,
  markConnected,
  RoomError,
} from "./room.js";
import { buildMeetContext, callJev, distanceOnlyJudge } from "./jev.js";
import { MAX_JUDGE_CALLS } from "./constants.js";

const ROOM_KEY = "room";

// M3セキュリティ対応: WSメッセージのサイズ上限(バイト)。超過分は中身を見ずに黙って捨てる
// (DoS対策優先。エラー通知もしない)。
const MAX_WS_MESSAGE_BYTES = 2048;
// M3セキュリティ対応: 位置情報送信の最小間隔(ミリ秒)。連投は無視して間引く。
const LOCATION_MIN_INTERVAL_MS = 1000;
// M2セキュリティ対応: 同一roleでの新規WS接続時に閉じる、既存接続へのcloseコード。
const DUPLICATE_CONNECTION_CLOSE_CODE = 4001;

function jsonResponse(data, status = 200) {
  return new Response(JSON.stringify(data), {
    status,
    headers: { "content-type": "application/json; charset=utf-8" },
  });
}

function errorStatus(code) {
  switch (code) {
    case "not_found":
      return 404;
    case "expired":
      return 410;
    case "full":
      return 409;
    case "invalid_invite":
      return 403;
    case "unauthorized":
      return 401;
    case "no_guest":
    case "stopped":
      return 409;
    default:
      return 400;
  }
}

function otherRoleOf(role) {
  return role === "host" ? "guest" : "host";
}

export class RoomDO {
  constructor(ctx, env) {
    this.ctx = ctx;
    this.env = env;
    // H2セキュリティ対応: 「会えた」判定(handleJudge)の同期ロック。judgeメッセージのハンドラは
    // Jev API呼び出し(fetch、storage以外のawait)を挟むため、Durable Objectの入力ゲートだけでは
    // 同時に届いた2件目の judge メッセージが1件目のawait中に処理されてしまうのを防げない
    // (loadRoom等のstorage呼び出し中はゲートされるが、fetch待ち中はゲートされない)。
    // このインスタンスメモリ上のフラグで、1部屋につき常に1回のJev呼び出ししか同時に走らせない。
    this.judgeInProgress = false;
    // M3セキュリティ対応: role("host"/"guest")ごとに直近の位置情報送信時刻を覚えておき、
    // LOCATION_MIN_INTERVAL_MS未満の連投を間引く(ハイバネーション復帰でリセットされても実害はない)。
    this.lastLocationAt = new Map();
  }

  async loadRoom() {
    return (await this.ctx.storage.get(ROOM_KEY)) ?? null;
  }

  async saveRoom(room) {
    await this.ctx.storage.put(ROOM_KEY, room);
  }

  async fetch(request) {
    const url = new URL(request.url);
    try {
      if (url.pathname === "/init" && request.method === "POST") return await this.handleInit(request);
      if (url.pathname === "/preview" && request.method === "GET") return await this.handlePreview(url);
      if (url.pathname === "/join" && request.method === "POST") return await this.handleJoin(request);
      if (url.pathname === "/ws" && request.method === "GET") return await this.handleWsUpgrade(request, url);
      return jsonResponse({ ok: false, reason: "not_found" }, 404);
    } catch (err) {
      if (err instanceof RoomError) return jsonResponse({ ok: false, reason: err.code }, errorStatus(err.code));
      throw err;
    }
  }

  async handleInit(request) {
    const existing = await this.loadRoom();
    if (existing) return jsonResponse({ ok: false, reason: "already_initialized" }, 409);
    const body = await request.json().catch(() => null);
    if (!body || !body.roomId || !body.hostNickname) {
      return jsonResponse({ ok: false, reason: "invalid_request" }, 400);
    }
    const room = createRoom({ hostNickname: body.hostNickname, roomId: body.roomId });
    await this.saveRoom(room);
    await this.ctx.storage.setAlarm(room.expiresAt);
    return jsonResponse({
      ok: true,
      roomId: room.roomId,
      hostSecret: room.host.secret,
      inviteToken: room.inviteToken,
    });
  }

  async handlePreview(url) {
    const room = await this.loadRoom();
    if (!room) return jsonResponse({ ok: false, reason: "not_found" }, 404);
    const invite = url.searchParams.get("invite") ?? "";
    const result = previewRoom(room, invite);
    return jsonResponse(result, result.ok ? 200 : errorStatus(result.reason));
  }

  async handleJoin(request) {
    // M1セキュリティ対応: request.json()(storageではないawait)を先に読み切ってから
    // loadRoom→joinRoom→saveRoomを実行する。storage以外のawaitをこの区間に挟むと、
    // 同時に届いた2件目のjoinがDurable Objectの入力ゲートをすり抜けて古いroomを
    // 読んでしまい、招待トークンの2重消費(=定員2人を超える参加)につながるため。
    const body = await request.json().catch(() => null);
    if (!body) return jsonResponse({ ok: false, reason: "invalid_request" }, 400);
    const room = await this.loadRoom();
    if (!room) return jsonResponse({ ok: false, reason: "not_found" }, 404);
    const next = joinRoom(room, { inviteToken: body.invite, nickname: body.nickname });
    await this.saveRoom(next);
    this.broadcast(next);
    return jsonResponse({ ok: true, guestSecret: next.guest.secret });
  }

  async handleWsUpgrade(request, url) {
    const role = url.searchParams.get("role");
    const secret = url.searchParams.get("secret") ?? "";
    if (role !== "host" && role !== "guest") return jsonResponse({ ok: false, reason: "invalid_role" }, 400);
    const room = await this.loadRoom();
    if (!room) return jsonResponse({ ok: false, reason: "not_found" }, 404);
    if (!authenticate(room, role, secret)) return jsonResponse({ ok: false, reason: "unauthorized" }, 401);
    if (request.headers.get("Upgrade") !== "websocket") {
      return jsonResponse({ ok: false, reason: "expected_websocket" }, 426);
    }

    // M2セキュリティ対応: 同じroleで既に繋がっているソケットがあれば先に閉じる
    // (1人が複数タブ/複数端末で同時に繋いでbroadcastを混乱させるのを防ぐ。1role=1接続)。
    for (const existing of this.ctx.getWebSockets(`role:${role}`)) {
      try {
        existing.close(DUPLICATE_CONNECTION_CLOSE_CODE, "duplicate_connection");
      } catch (_err) {
        /* noop */
      }
    }

    const pair = new WebSocketPair();
    const client = pair[0];
    const server = pair[1];
    this.ctx.acceptWebSocket(server, [`role:${role}`]);
    server.serializeAttachment({ role, secret });

    const updated = markConnected(room, role, true);
    await this.saveRoom(updated);
    this.sendState(server, updated, role);
    this.broadcastTo(otherRoleOf(role), updated);

    return new Response(null, { status: 101, webSocket: client });
  }

  sendState(ws, room, role) {
    try {
      ws.send(JSON.stringify(buildPublicState(room, role)));
    } catch (_err) {
      // ソケットが既に閉じている場合は無視する(Hibernation APIでは起こり得る)
    }
  }

  broadcast(room) {
    this.broadcastTo("host", room);
    this.broadcastTo("guest", room);
  }

  broadcastTo(role, room) {
    for (const ws of this.ctx.getWebSockets(`role:${role}`)) this.sendState(ws, room, role);
  }

  async webSocketMessage(ws, message) {
    // M3セキュリティ対応: 2KBを超えるメッセージは中身を見ずに黙って捨てる(DoS対策優先)。
    const byteLength = typeof message === "string" ? new TextEncoder().encode(message).length : message.byteLength;
    if (byteLength > MAX_WS_MESSAGE_BYTES) return;

    const attachment = ws.deserializeAttachment() || {};
    const role = attachment.role;
    const secret = attachment.secret;

    let payload;
    try {
      const text = typeof message === "string" ? message : new TextDecoder().decode(message);
      payload = JSON.parse(text);
    } catch (_err) {
      return;
    }

    const room = await this.loadRoom();
    if (!room || !role || !authenticate(room, role, secret)) {
      this.sendError(ws, "unauthorized");
      return;
    }

    try {
      if (payload.type === "approve" && role === "host") {
        const next = approveHost(room, { secret });
        await this.saveRoom(next);
        this.broadcast(next);
      } else if (payload.type === "floor") {
        const next = setFloor(room, { role, secret, floor: payload.floor });
        await this.saveRoom(next);
        this.broadcast(next);
      } else if (payload.type === "location") {
        // M3セキュリティ対応: 位置情報の連投を1秒に1回程度へ間引く(超過分は無視)。
        const lastAt = this.lastLocationAt.get(role) || 0;
        const now = Date.now();
        if (now - lastAt < LOCATION_MIN_INTERVAL_MS) return;
        this.lastLocationAt.set(role, now);

        const result = updateLocation(room, {
          role,
          secret,
          lat: payload.lat,
          lng: payload.lng,
          acc: payload.acc,
        });
        await this.saveRoom(result.room);
        if (!result.accepted) this.sendJson(ws, { type: "locationRejected", reason: result.reason });
        this.broadcast(result.room);
      } else if (payload.type === "stop") {
        const next = stopSharing(room, { role, secret });
        await this.saveRoom(next);
        this.broadcast(next);
      } else if (payload.type === "judge") {
        await this.handleJudge(room, ws);
      }
    } catch (err) {
      const code = err instanceof RoomError ? err.code : "internal_error";
      this.sendError(ws, code);
    }
  }

  async handleJudge(room, ws) {
    // H2セキュリティ対応: このDOインスタンス内で同時に1件しかJev判定を走らせない。
    // 理由はコンストラクタのjudgeInProgressのコメント参照(fetch待ち中は入力ゲートが
    // 効かないため、ここで明示的にロックしないとJev呼び出し回数の上限をすり抜けられる)。
    if (this.judgeInProgress) {
      this.sendJson(ws, { type: "judgeResult", ok: false, reason: "judge_in_progress" });
      return;
    }
    this.judgeInProgress = true;
    try {
      const gate = canAttemptJudge(room);
      if (!gate.ok) {
        this.sendJson(ws, { type: "judgeResult", ok: false, reason: gate.reason, distance_m: gate.distance_m ?? null });
        return;
      }
      const waitingMinutes = (Date.now() - room.createdAt) / 60000;
      const floorMatch = true; // gate.ok===true の時点で同じ階であることは確認済み
      const canUseJev = !!this.env.JEV_API_KEY && room.judge.callCount < MAX_JUDGE_CALLS;

      let result;
      if (canUseJev) {
        try {
          const context = buildMeetContext({ distance_m: gate.distance_m, floorMatch, waitingMinutes });
          result = await callJev(this.env.JEV_API_KEY, context);
        } catch (_err) {
          result = distanceOnlyJudge({ distance_m: gate.distance_m, floorMatch });
        }
      } else {
        result = distanceOnlyJudge({ distance_m: gate.distance_m, floorMatch });
      }

      const next = recordJudgeResult(room, { ...result, now: Date.now() });
      await this.saveRoom(next);
      this.broadcast(next);
    } finally {
      this.judgeInProgress = false;
    }
  }

  sendJson(ws, data) {
    try {
      ws.send(JSON.stringify(data));
    } catch (_err) {
      /* noop */
    }
  }

  sendError(ws, code) {
    this.sendJson(ws, { type: "error", code });
  }

  async webSocketClose(ws) {
    await this.handleDisconnect(ws);
  }

  async webSocketError(ws) {
    await this.handleDisconnect(ws);
  }

  async handleDisconnect(ws) {
    const attachment = ws.deserializeAttachment() || {};
    const role = attachment.role;
    if (!role) return;
    const room = await this.loadRoom();
    if (!room) return;
    const updated = markConnected(room, role, false);
    await this.saveRoom(updated);
    this.broadcastTo(otherRoleOf(role), updated);
  }

  async alarm() {
    // 3時間経過。座標を含む部屋のデータを丸ごと削除する。
    const room = await this.loadRoom();
    for (const ws of this.ctx.getWebSockets()) {
      try {
        ws.send(JSON.stringify({ type: "state", phase: "expired" }));
        ws.close(1000, "expired");
      } catch (_err) {
        /* noop */
      }
    }
    if (room) await this.ctx.storage.deleteAll();
  }
}
