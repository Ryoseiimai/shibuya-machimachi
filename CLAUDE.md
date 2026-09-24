# CLAUDE.md

This file is read automatically by Claude Code sessions opened in this repo.
The full agent guide (layout, run/test commands, and hard limits) lives in
[AGENTS.md](AGENTS.md) — read it before making changes. This file only adds
Claude-Code-specific notes.

## Quick start for a Claude Code session here

```bash
npm run dev              # or: make dev — no Google/Cloudflare account needed, Ctrl+C to stop
cd worker && npm test    # room state machine / geo / floors / jev unit tests
cd e2e && npm test       # Playwright: full host+guest consent flow, 2 browser contexts
```

## Non-negotiable limits (same as AGENTS.md, repeated because they matter)

- Do not let `updateLocation()` accept/store a position before both
  `host.approved` and `guest.approved` are true.
- Do not put raw coordinates (lat/lng) in any WebSocket message, HTTP
  response, or log line — `buildPublicState()` in `worker/src/room.js` is the
  single place allowed to decide what a viewer sees.
- Do not raise the 2-person room cap or let an already-used invite token
  succeed again.
- Do not weaken the Shibuya-area (1.5km) restriction in `worker/src/constants.js`.
- Do not send coordinates or nicknames to the Jev judge call
  (`worker/src/jev.js`) — distance/floor-match/elapsed-time text only.
- Do not read, edit, or commit `worker/.dev.vars`, `worker/.wrangler/`, or any
  file under `控え/` — all are intentionally git-ignored.
- Do not add a workflow that runs `wrangler deploy` against the maintainer's
  production Worker.

## Working style expected in this repo

- Small, single-purpose commits/PRs.
- Run the tests in [AGENTS.md](AGENTS.md) before proposing a change is done.
- Match existing code style (plain Fetch API / vanilla JS everywhere, no
  frameworks, Japanese-first comments in `worker/`).
