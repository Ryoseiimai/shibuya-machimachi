## What / 変更内容

<!-- What does this PR do, and why? / 何を、なぜ変更しましたか？ -->

## How tested / 動作確認

- [ ] `cd worker && npm test` passes
- [ ] Tried `npm run dev` / `make dev` and confirmed the screen behaves as expected (if you touched `worker/` or the phone UI)

## Lines not to cross / 守るべき線 (see [SECURITY.md](../SECURITY.md))

- [ ] This PR does **not** start location sharing before both participants have explicitly approved.
      このPRは、両者が明示的に承認する前に位置の送受信を始めていません。
- [ ] This PR does **not** add raw coordinates (lat/lng) to any WebSocket message, API response, or log line.
      このPRは、座標そのものをWebSocketメッセージ・APIレスポンス・ログのいずれにも出力していません。
- [ ] This PR does **not** send coordinates to a third-party service (including the Jev judge call) beyond distance/floor-match text.
      このPRは、距離・同階かどうかのテキスト以外の情報を第三者サービス(Jev判定含む)に送っていません。
- [ ] This PR does **not** raise the room capacity above 2 or remove the Shibuya-area (1.5km) restriction without discussion.
      このPRは、議論なしに部屋の定員を2人より増やしたり、渋谷エリア(1.5km)制限を外したりしていません。

## Related issue / 関連Issue

<!-- Closes #... -->
