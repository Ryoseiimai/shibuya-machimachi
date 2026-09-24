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
    const room = await this.loadRoom();
    if (!room) return jsonResponse({ ok: false, reason: "not_found" }, 404);
    const body = await request.json().catch(() => null);
    if (!body) return jsonResponse({ ok: false, reason: "invalid_request" }, 400);
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
