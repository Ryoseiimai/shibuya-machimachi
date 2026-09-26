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
  - `src/security-headers.js` — the security headers (CSP, X-Frame-Options,
    etc.) applied to every non-101 response by `index.js`'s `fetch()`. The
    CSP string here must stay byte-for-byte identical to the one in
    `public/_headers` (which covers `/assets/*` and `/vendor/*`, served
    directly by the assets binding without going through `index.js`);
    `test/security-headers.test.js` asserts they match.
  - `src/html.js` — the HTML/CSS shell as one template string (no build step,
    no framework — matches the Worker's own style). The page's client-side
    JS itself lives in `public/assets/js/app.js` (external file, not inline,
    so the CSP's `script-src` needs no `'unsafe-inline'`). Client-side JS
    never computes area/distance itself; it only renders what the server
    already computed, so there is exactly one place (`buildPublicState()` in
    `room.js`) that decides what's safe to reveal.
  - `public/assets/js/` — client-side JS/ESM served as static assets:
    `app.js` (main screen logic), `shibuya3d.mjs`/`ar.js`/`vr.js`/`geo.js`
    (3D map, AR, VR, and their shared geo helpers), `route.js` (walking-directions
    engine: graph decoding, snapping, A*, next waypoint, instruction text — pure
    functions, unit-tested) and `route-panel.js` (the directions UI shared by the
    solo "go to a place" mode at `/go` and the meetup screen's "道順で案内").
  - `public/route/` — walkway graph (`graph.json`, built from OpenStreetMap by
    `scripts/build_route_graph.mjs`) and well-known spots (`places.json`). Served with a
    1-year cache; bump `ROUTE_GRAPH_VERSION`/`PLACES_VERSION` in `route.js` when they
    change (`test/route-data.test.js` fails otherwise).
  - `public/vendor/` — MapLibre GL JS and three.js, vendored verbatim from
    npm (see `package.json` devDependencies and each package's own
    `VERSION.txt`) instead of loaded from a CDN at runtime. Do not hand-edit
    these files; to update, bump the version in `package.json`,
    `npm install`, and re-copy from `node_modules/<pkg>/dist` (or
    `build`/`examples`) following the same file list as the current
    `VERSION.txt` neighbors.
  - `test/` — Node's built-in test runner (`node:test`).
  - `wrangler.toml` — Worker config, including the Durable Object binding,
    the `new_sqlite_classes` migration (SQLite-backed DO storage, usable on
    the Workers Free plan), and a `[[ratelimits]]` binding
    (`ROOM_CREATE_LIMITER`) that caps `POST /api/rooms` per hashed IP.
    **Do not add an `account_id`.**
- `app/` — the iOS app (Capacitor). `app/scripts/build-www.mjs` bundles the screen from
  `worker/src/html.js` + `worker/public/` into `app/www/`; `app/src/native-bridge.js` exposes native
  features to `worker/public/assets/js/app.js` as `window.MachimachiHost` (absent on the web, where
  app.js behaves exactly as before); `app/src/demo.js` is the on-device demo mode. See `app/README.md`.
  The Worker allows CORS only for the app origin `capacitor://localhost` (`worker/src/app-origin.js`).
- `e2e/` — Playwright end-to-end test that drives two isolated browser
  contexts (host + guest) through the full consent flow against a local
  `wrangler dev` server.
- `scripts/dev.sh` — the "3-minute quickstart" dev mode (`npm run dev` / `make dev`).
- `scripts/build_route_graph.mjs` — builds `worker/public/route/graph.json` from one
  Overpass API query (`--fetch`) or a saved Overpass result (`--input`).

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
   viewer sees, and it must never grow a `lat`/`lng` field. The 3D Shibuya
   map's "partner pin" is allowed to exist, but only as a **client-side**
   approximation computed by the *other* participant's own app (real GPS +
   the server's distance/bearing), and only after both sides have approved
   (`isActive()` true) — see `worker/public/assets/js/app.js`'s
   `refreshExtras()`. The server itself must never compute, store, or log
   that approximate position.
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
9. **Never** send the user's position, destination, or route to the server for
   walking directions — routing stays on-device (`route.js`). A shared meeting
   spot is a spot ID only (`setMeetSpot()`), never coordinates.

## Style

- Plain Fetch API / vanilla JS everywhere (Worker and client HTML) — no new
  frameworks. Comments in `worker/` are Japanese-first, matching the existing
  style; match that when editing those files. New docs aimed at contributors
  (like this file) are fine in English.
- Small, focused PRs. See [CONTRIBUTING.md](CONTRIBUTING.md) for the branch/PR
  flow, and the PR template for the required checklist.
