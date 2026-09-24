# AGENTS.md

Guidance for AI coding agents (Claude Code, Codex, GitHub Copilot, Cursor, etc.)
working in this repository. Humans, feel free to read this too — it doubles as
a technical overview.

## What this project is

`shibuya-machimachi` ("渋谷マチマチ") is a 1-on-1 meetup app scoped to Shibuya.
Two people who **both** explicitly approve sharing get a live distance/direction
to each other; no one else ever sees it. See [README.md](README.md) for the
full picture, and [SECURITY.md](SECURITY.md) for the privacy contract this
codebase must never break.

It grew out of [Ryoseiimai/gmaps-share-finder](https://github.com/Ryoseiimai/gmaps-share-finder)
("OG探しゲーム") — same distance/bearing math (`worker/src/geo.js`), same
"no coordinates ever leave the server" discipline, same dev-mode philosophy —
rebuilt around Durable Objects + WebSockets for real two-way, mutual-consent
sharing instead of a single shared token.

## Layout

- `worker/` — Cloudflare Worker (plain Fetch API, ES modules, no framework).
  - `src/index.js` — HTTP routing: creates rooms, forwards everything else to
    the Durable Object, serves the single-page HTML shell.
  - `src/room.js` — the room state machine. **Pure functions only** (no
    Workers/DO APIs). This is where the consent/capacity/area/judge-gate rules
    live, and where almost all unit tests point. Keep it side-effect-free.
  - `src/room-do.js` — `RoomDO`, the Durable Object. A thin wrapper: loads/saves
    the state object from `room.js` via `ctx.storage`, wires up the WebSocket
    Hibernation API (`acceptWebSocket`/`webSocketMessage`/`webSocketClose`/`alarm`).
    Business logic does not belong here — put it in `room.js` and keep it
    testable without Miniflare.
  - `src/geo.js` — pure `distanceMeters`/`bearingDegrees`/`isWithinRadius`.
  - `src/floors.js` — pure floor (B5〜10F) comparison helpers.
  - `src/jev.js` — TypeSafe AI Jev ("会えた？" judgment) payload builder + caller,
    plus the `distance_only` fallback used when no API key is configured or the
    per-room call cap is reached.
  - `src/constants.js` — every magic number (Shibuya center/radius, room TTL,
    meet distance, judge call cap, floor list) lives here.
  - `src/html.js` — the entire client-facing HTML/CSS/JS as one template
    string, served as-is (no build step, no framework — matches the Worker's
    own style). Client-side JS never computes area/distance itself; it only
    renders what the server already computed, so there is exactly one place
    (`buildPublicState()` in `room.js`) that decides what's safe to reveal.
  - `test/` — Node's built-in test runner (`node:test`).
  - `wrangler.toml` — Worker config, including the Durable Object binding and
    the `new_sqlite_classes` migration (SQLite-backed DO storage, usable on the
    Workers Free plan). **Do not add an `account_id`.**
- `e2e/` — Playwright end-to-end test that drives two isolated browser
  contexts (host + guest) through the full consent flow against a local
  `wrangler dev` server.
- `scripts/dev.sh` — the "3-minute quickstart" dev mode (`npm run dev` / `make dev`).

## How to run it

No Google account and no Cloudflare account needed:

```bash
npm run dev     # or: make dev
```

This starts `wrangler dev --local` (Miniflare, fully local — Durable Objects,
WebSockets, and the SQLite storage backend are all simulated with no network
access to Cloudflare). Open the printed URL in two browser tabs to play both
the host and the guest role. Stop with Ctrl+C.

## How to test

```bash
cd worker && npm test          # node:test — room/geo/floors/jev unit tests
node --check worker/src/*.js   # syntax check
cd e2e && npm test             # Playwright: full host+guest flow, 2 browser contexts
```

CI (`.github/workflows/ci.yml`) runs the worker syntax check + unit tests on
every PR. A PR must be green before it can be merged (branch protection on
`main`). The Playwright E2E suite is not wired into CI (real-browser
WebSocket + geolocation runs are comparatively slow/flaky for a required
merge gate); run it locally before shipping a change that touches the
realtime flow.

## Lines an agent must not cross

Read [SECURITY.md](SECURITY.md) in full before touching anything related to
location or consent. In short:

1. **Never** let a location update reach storage, a WebSocket message, or the
   other participant before **both** `host.approved` and `guest.approved` are
   true (`isActive()` in `room.js`). `updateLocation()` must keep refusing to
   store anything until then.
2. **Never** put raw coordinates in a WebSocket message, HTTP response, or log
   line. `buildPublicState()` is the only function allowed to decide what a
   viewer sees, and it must never grow a `lat`/`lng` field.
3. **Never** raise `MAX_PARTICIPANTS` above 2, or let a used/invalid invite
   token succeed a second time.
4. **Never** remove or weaken the Shibuya-area check (`SHIBUYA_STATION` /
   `SHIBUYA_RADIUS_M` in `constants.js`) — coordinates outside the radius must
   not be stored or forwarded.
5. **Never** send coordinates or nicknames to the Jev judge call
   (`worker/src/jev.js`) — only distance (m), same-floor boolean, and elapsed
   minutes.
6. **Never** commit a secret. `JEV_API_KEY` is set with `wrangler secret put`
   and must never appear in code, `wrangler.toml`, logs, or a screenshot.
7. **Never** add a workflow that runs `wrangler deploy` against the
   maintainer's production Worker; this repo intentionally has no
   deploy-on-merge automation.
8. Keep `worker/src/room.js` framework-free and side-effect-free so its
   behavior stays fully unit-testable without Miniflare.

## Style

- Plain Fetch API / vanilla JS everywhere (Worker and client HTML) — no new
  frameworks. Comments in `worker/` are Japanese-first, matching the existing
  style; match that when editing those files. New docs aimed at contributors
  (like this file) are fine in English.
- Small, focused PRs. See [CONTRIBUTING.md](CONTRIBUTING.md) for the branch/PR
  flow, and the PR template for the required checklist.
