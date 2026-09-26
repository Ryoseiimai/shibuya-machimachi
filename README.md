# 渋谷マチマチ (shibuya-machimachi)

[![CI](https://github.com/Ryoseiimai/shibuya-machimachi/actions/workflows/ci.yml/badge.svg)](https://github.com/Ryoseiimai/shibuya-machimachi/actions/workflows/ci.yml)
[![Open in GitHub Codespaces](https://github.com/codespaces/badge.svg)](https://codespaces.new/Ryoseiimai/shibuya-machimachi)
[![License: MIT](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)

**公開中: https://shibuya-machimachi.kaeru3160.workers.dev/**

渋谷で1対1の待ち合わせを、**お互いが承認した相手とだけ**位置を共有して、迷わず会うためのアプリです。

## スクリーンショット

| 招待リンクを送る | 参加通知を承認する | 距離と方角が届く |
| --- | --- | --- |
| ![招待リンク画面](docs/screenshot-invite.png) | ![承認画面](docs/screenshot-approve.png) | ![待ち合わせ画面](docs/screenshot-meet.png) |

(スクリーンショットは `npm run dev` のローカル環境と、Playwright E2Eテスト([e2e/tests/flow.spec.js](e2e/tests/flow.spec.js))で自動生成したものです)

## iOSアプリ

App Store版(iPhone)は [`app/`](app/README.md) にあります。画面・3D/AR部品・地図データをアプリに同梱し、通信だけ本番Workerへ行います。1台で試せる「デモで試す」付き。

## 3分で動かす

Googleアカウントも Cloudflareアカウントも不要です。

```bash
git clone https://github.com/Ryoseiimai/shibuya-machimachi.git
cd shibuya-machimachi
npm run dev   # または: make dev
```

`wrangler dev` をローカルのみ(Miniflare)で起動します。同じURLをブラウザのタブ2つで開けば、
1台のPCでA(ホスト)とB(ゲスト)の両方を再演できます。止めるときは `Ctrl+C`。

ローカルに何もインストールしたくない場合は、上の「Open in GitHub Codespaces」バッジからブラウザだけで同じ開発環境を起動できます。

## 使い方

1. **A(ホスト)がニックネームだけ入力して「待ち合わせを作る」を押す**(アカウント登録は不要)。
2. Aに招待リンクが表示される。コピー・LINE・Xのボタンで**Bに送る**(1回開かれると使えなくなるリンク)。
3. **Bが招待リンクを開き**、Aのニックネームを確認してから自分のニックネームを入力し「承認して参加」を押す。
4. **Aに通知が届き**、「この人と位置を共有する」を押して**Aも承認する**。
5. 両者の承認が揃った瞬間から、**距離(m)と方角の矢印**がお互いの画面に表示される。あわせて今いる階(B5〜10F)を選ぶと「相手は2つ上の階にいます」のように差が出る。
6. 20m以内・同じ階に来たら「会えた！」ボタンで判定できる。どちらかが「共有をやめる」を押せば即座に位置のやり取りは止まる。

### 道順で案内(歩行ルート)

矢印は相手や目的地への「直線の方角」ではなく、**歩ける道に沿った次の経由点**を指します。階段・エスカレーター・エレベーターでは「エスカレーターで2階へ」「階段で地下1階へ」のように上下も案内します。

- **場所へ行く(1人で使える)**: トップページや作成画面の「場所へ行く」(`/go`)から、ハチ公像・モヤイ像・ハチ公改札・スクランブル交差点・SHIBUYA109前など13か所の定番スポットを選ぶと、矢印・次の案内文(「20m先を右」)・残りの道のり・到着を表示します。**位置はサーバーに送らず、端末の中だけで経路を計算します**。
- **人モード**: 待ち合わせ画面の「道順で案内」で、相手のおおよその位置(距離・方角から端末内で推定)と相手の階まで、同じように案内します。
- **待ち合わせ場所を決める**: 待ち合わせ中にどちらかが定番スポットを選ぶと2人に届き、「待ち合わせ場所へ道順で案内」で2人ともそこへ向かえます。サーバーに送るのは**スポットのIDだけ**です。
- 経路から25m以上外れたら自動で計算し直し、同じ階で15m以内に来たら到着です。地下や館内はGPSが弱いので、「今いる階」のボタン1タップで階を直せます(階の移動の手前では「◯階に着いた」ボタンも出ます)。3D渋谷には道順の線を描きます。

道のデータ([`worker/public/route/graph.json`](worker/public/route/graph.json))は OpenStreetMap の歩道・横断歩道・階段・エスカレーター・エレベーター・館内の通路から [`scripts/build_route_graph.mjs`](scripts/build_route_graph.mjs) で作った、渋谷駅から半径1.5kmの歩行ネットワークです(約1.1万ノード・1.4万本、gzip後約120KB)。作り直すときは次のとおりです(Overpass APIへの問い合わせは1回)。

```bash
node scripts/build_route_graph.mjs --fetch --save-raw /tmp/raw_osm.json   # 取得して作る
node scripts/build_route_graph.mjs --input /tmp/raw_osm.json              # 取得済みデータから作り直す
# 出力された version を worker/public/assets/js/route.js の ROUTE_GRAPH_VERSION に反映する(テストがズレを検出)
```

意図的な簡略化: OSMの `level`(階)は建物ごとの数え方で、渋谷では描いた人によって0始まり/1始まりが混ざり、谷地形のため「坂の上の道路=別の建物の4階」も普通にあります。そのため地下(マイナスの階)はそのまま信じ、地上の階の変化は階段・エスカレーター・エレベーターの両端の差だけで数えます。行き先の階が怪しいときは「階段で下の階へ」、上り下りも怪しいときは「階段を通る」とだけ言います。改札の内側(有料区域)を通る道順を完全には避けられない点も既知の限界です(本格対応の入口: 改札ノードの取り込み、国交省「歩行空間ネットワークデータ」渋谷地区での補正)。

## プライバシー設計

- **相互承認が揃うまで、位置の送受信は一切始まらない**。承認前はサーバーも座標を保存しません(`worker/src/room.js` の `updateLocation()`)。
- **1部屋2人まで**。招待リンクは1回使われると無効になり、3人目は「満員」になります。
- どちらかが「共有をやめる」を押すと、**その場で双方の座標を削除**し、以後の位置更新も拒否します。
- 部屋は**3時間で自動終了**し、Durable Objectのストレージごと位置データを削除します。
- **渋谷駅から半径1.5km限定**。エリア外では自分の位置を送信せず「渋谷エリアの外なので共有を止めています」と表示します。
- 相手に渡すのは**距離・方角・フロアの差だけ**。生の座標はWebSocketメッセージ・APIレスポンス・ログのどこにも出しません(`buildPublicState()` が唯一の関所)。
- 「会えた？」判定(TypeSafe AI Jev)に送るのも**距離(m)・同じ階かどうか・経過時間だけ**で、座標やニックネームは送りません。
- **道順案内は端末の中だけで計算**します。現在地・行き先・経路はサーバーに送りません(読み込むのは公開の道データだけ)。待ち合わせ場所として共有するのも**スポットのIDだけ**です。

詳細な線引きは [SECURITY.md](SECURITY.md) を参照してください。

## ロードマップ

土台(招待リンク→相互承認→リアルタイムの距離と方角)に加えて、3D渋谷・近くのお店・ARを実装済みです。

- [x] **3D渋谷** — [PLATEAU](https://www.mlit.go.jp/plateau/)(国土交通省の3D都市モデル)を使って、渋谷の建物を3Dで表示する。自分と相手のピン(階も反映)が立ち、`focusBoth()`で2人が収まる位置まで自動的に引く
- [x] **近くのお店** — [OpenStreetMap](https://www.openstreetmap.org/)のデータで、相手の推定位置周辺の近い順3件を表示する
- [x] **道順で案内(歩行ルート)** — [OpenStreetMap](https://www.openstreetmap.org/)の歩行ネットワーク(階段・エスカレーター・エレベーター・館内の通路を含む)をブラウザ内のA*で探索し、歩ける道に沿った矢印と「エスカレーターで2階へ」のような階の移動を案内する。場所モード(1人で定番スポットへ)・人モード(待ち合わせ相手へ)・待ち合わせ場所の共有(スポットIDのみ)に対応
- [ ] **道順の精度向上** — 国交省「歩行空間ネットワークデータ」(渋谷地区)での補正、改札の内側(有料区域)の除外、ビルごとの階の対応表
- [ ] **上下(フロア)の自動化** — 今は手動選択(B5〜10F)のピッカーのみ。将来は端末の気圧センサーなどから高度を推定し、手動選択と組み合わせる
- [x] **AR** — 「ARで探す」ボタンから全画面ARビューを開き、カメラ越しに相手がいる方向へ人影(シルエット)と距離を重ねて表示する
- [ ] **VRメガネ対応(実験的)** — [WebXR](https://www.w3.org/TR/webxr/)の immersive-ar/immersive-vr に対応した端末でのみ、AR画面内に「VRメガネで見る」ボタンが出る。iPhone/Vision Proなど非対応端末には出さない

## 参加方法 (Contributing)

Issue・PR歓迎です。

- ローカル開発は上の「3分で動かす」を参照(Googleアカウント・Cloudflareアカウント不要)。
- ブランチ・PRの流れは [CONTRIBUTING.md](CONTRIBUTING.md)、行動規範は [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md)、受け付けない変更は [SECURITY.md](SECURITY.md) を参照。
- 初めてのコントリビューションに良さそうな小さめの課題には `good first issue` ラベルを付けています。[Issues](https://github.com/Ryoseiimai/shibuya-machimachi/issues) から探してください。
- Claude Code・Codex などAIコーディングエージェントを使う場合は [AGENTS.md](AGENTS.md) / [CLAUDE.md](CLAUDE.md) に構成・起動・テスト方法・守るべき線をまとめています。
- 小さな修正(誤字・翻訳・README改善など)は、Forkしなくても GitHub上のファイル右上の鉛筆アイコンから直接編集提案(PR)を送れます。

## 由来

このアプリは [OG探しゲーム (Ryoseiimai/gmaps-share-finder)](https://github.com/Ryoseiimai/gmaps-share-finder) から進化しました。距離・方角の計算方式や「座標を一切外に出さない」という設計思想を引き継ぎつつ、片方向の鬼ごっこから、**両者が明示的に承認しあう1対1の待ち合わせ**へと作り替えています。

## ライセンス・地図データの出典

- コード本体は **MIT License**([LICENSE](LICENSE)参照)。
- 建物3Dモデル: 出典 [国土交通省 3D都市モデルPLATEAU](https://www.mlit.go.jp/plateau/)(渋谷区, **CC BY 4.0**)。
- 地図タイル: [地理院タイル](https://maps.gsi.go.jp/development/ichiran.html)(国土地理院)。
- 店舗情報・道順(道のデータ・定番スポット): © [OpenStreetMap contributors](https://www.openstreetmap.org/copyright)(**ODbL**)。`worker/public/route/graph.json` / `places.json` は OpenStreetMap から作った派生データベースで、ODbL で提供します。
- 上記3件のクレジットは、待ち合わせ画面の3D渋谷/近くのお店の枠のすぐ下(フッター)と、3D地図右下のMapLibre属性コントロールの両方に表示しています。

---

# Shibuya Machimachi (English)

A 1-on-1 meetup app for Shibuya: share your location only with the person you've **mutually approved**, and find each other without getting lost.

## Screenshots

| Send the invite link | Approve the request | Distance & bearing arrive |
| --- | --- | --- |
| ![Invite link screen](docs/screenshot-invite.png) | ![Approval screen](docs/screenshot-approve.png) | ![Meetup screen](docs/screenshot-meet.png) |

(Screenshots were captured automatically from the local `npm run dev` environment via the Playwright E2E test, [e2e/tests/flow.spec.js](e2e/tests/flow.spec.js).)

## 3-minute quickstart

No Google account and no Cloudflare account required.

```bash
git clone https://github.com/Ryoseiimai/shibuya-machimachi.git
cd shibuya-machimachi
npm run dev   # or: make dev
```

Starts `wrangler dev` in local-only mode (Miniflare). Open the same URL in two browser tabs to
play both A (host) and B (guest) on one machine. Stop with `Ctrl+C`.

Prefer not to install anything locally? Use the "Open in GitHub Codespaces" badge above to get the same dev environment in your browser.

## How to use it

1. **A (the host) enters only a nickname** and taps "待ち合わせを作る" (Create a meetup) — no account needed.
2. A gets an invite link, with Copy / LINE / X buttons to **send it to B** (the link can only be opened successfully once).
3. **B opens the invite link**, sees A's nickname, enters their own nickname, and taps "承認して参加" (Approve & join).
4. **A is notified** and taps "この人と位置を共有する" (Share location with this person) to **approve too**.
5. The instant both approvals are in, **distance (m) and a direction arrow** appear on both screens. Pick your current floor (B5–10F) to also see a difference like "the other person is 2 floors up."
6. Once within 20m and on the same floor, either side can tap "会えた！" (We met!) to trigger the judgment. Tapping "共有をやめる" (Stop sharing) on either side halts the location exchange immediately.

### Walking directions

The arrow points to **the next waypoint along walkable paths**, not the straight-line bearing. Stairs, escalators, and elevators are announced with the floor change (e.g. "エスカレーターで2階へ" = take the escalator to 2F).

- **Go to a place (solo)**: "場所へ行く" (`/go`, linked from the top page and the create screen) lists 13 well-known spots (Hachiko statue, Moyai statue, Hachiko gate, Scramble Crossing, SHIBUYA109, …) and shows the arrow, the next instruction ("20m先を右" = turn right in 20 m), the remaining distance, and arrival. **Your position is never sent; the route is computed on-device.**
- **Person mode**: "道順で案内" on the meetup screen guides you to the other person's approximate position (reconstructed on-device from distance/bearing) and floor.
- **Meeting spot**: either person can pick a spot during a meetup; both see it and can get directions there. **Only the spot ID** is sent to the server.
- The route is recomputed when you stray 25 m or more, and you arrive within 15 m on the same floor. GPS is weak underground, so the current floor can be corrected with one tap (plus a "arrived at ◯F" button right before a floor change). The route is also drawn on the 3D map.

The walkway graph ([`worker/public/route/graph.json`](worker/public/route/graph.json), ~11k nodes / ~14k edges, ~120 KB gzipped) is built from OpenStreetMap by [`scripts/build_route_graph.mjs`](scripts/build_route_graph.mjs) (one Overpass query; see the Japanese section above for the commands).

## Privacy design

- **No location is ever sent or received until both sides have mutually approved.** The server doesn't even store coordinates before that (`updateLocation()` in `worker/src/room.js`).
- **2 people per room, max.** Invite tokens are single-use; a 3rd person gets "full."
- Tapping "stop sharing" **immediately deletes both participants' coordinates** and rejects further updates.
- Rooms **auto-expire after 3 hours**, deleting the entire Durable Object storage (including any location data).
- **Limited to a 1.5km radius from Shibuya Station.** Outside that area, your own position is never sent, and you see "渋谷エリアの外なので共有を止めています" (You're outside Shibuya, so sharing is paused).
- The other person only ever receives **distance, bearing, and floor difference** — raw coordinates never appear in a WebSocket message, API response, or log line (`buildPublicState()` is the single choke point).
- The "did we meet?" judgment (TypeSafe AI Jev) only ever receives **distance (m), same-floor status, and elapsed time** — never coordinates or nicknames.
- **Walking directions are computed on-device**; your position, destination, and route are never sent (only the public walkway data is downloaded). A shared meeting spot is sent as **a spot ID only**.

See [SECURITY.md](SECURITY.md) for the full set of lines this codebase must not cross.

## Roadmap

On top of the foundation (invite link → mutual approval → realtime distance/bearing), 3D Shibuya, nearby shops, and AR are now implemented.

- [x] **3D Shibuya** — renders Shibuya's buildings in 3D using [PLATEAU](https://www.mlit.go.jp/plateau/) (Japan's MLIT 3D city model). Pins for you and the other person (floor included) appear, and `focusBoth()` auto-zooms out until both fit
- [x] **Nearby shops** — shows the 3 closest shops to the other person's estimated location, using [OpenStreetMap](https://www.openstreetmap.org/) data
- [x] **Walking directions** — on-device A* over an [OpenStreetMap](https://www.openstreetmap.org/) walkway graph (stairs, escalators, elevators, indoor corridors included), with floor-change instructions. Solo "go to a place" mode, person mode, and a shared meeting spot (spot ID only)
- [ ] **Better directions** — refine with MLIT's pedestrian network data for Shibuya, exclude paid areas inside ticket gates, per-building floor tables
- [ ] **Automatic floor detection** — today it's a manual B5–10F picker only; later, estimate altitude from device sensors (e.g. barometer) and combine it with manual selection
- [x] **AR** — the "ARで探す" (Find in AR) button opens a fullscreen AR view that overlays a silhouette and distance toward the other person through the camera
- [ ] **VR glasses support (experimental)** — a "VRメガネで見る" (View with VR glasses) button appears inside the AR view only on devices that support [WebXR](https://www.w3.org/TR/webxr/) immersive-ar/immersive-vr; not shown on unsupported devices like iPhone or Vision Pro

## Contributing

Issues and PRs are welcome.

- For local dev, see "3-minute quickstart" above (no Google/Cloudflare account needed).
- See [CONTRIBUTING.md](CONTRIBUTING.md) for the branch/PR flow, [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md) for community standards, and [SECURITY.md](SECURITY.md) for changes we won't accept.
- Smaller issues suitable for a first contribution are labeled `good first issue` — browse [Issues](https://github.com/Ryoseiimai/shibuya-machimachi/issues).
- Using an AI coding agent (Claude Code, Codex, etc.)? See [AGENTS.md](AGENTS.md) / [CLAUDE.md](CLAUDE.md) for layout, run/test commands, and the lines not to cross.
- For small fixes (typos, translations, README tweaks), you don't even need to fork — use GitHub's pencil ("Edit this file") icon to propose a change directly.

## Origin

This app evolved from [OG探しゲーム (Ryoseiimai/gmaps-share-finder)](https://github.com/Ryoseiimai/gmaps-share-finder). It keeps the same distance/bearing math and the same "coordinates never leave the server" discipline, but rebuilds the one-directional hide-and-seek game into a **1-on-1 meetup where both sides explicitly approve each other**.

## License & map data attribution

- The code is **MIT licensed** (see [LICENSE](LICENSE)).
- 3D building models: [MLIT PLATEAU](https://www.mlit.go.jp/plateau/) 3D city model (Shibuya ward, **CC BY 4.0**).
- Map tiles: [GSI tiles](https://maps.gsi.go.jp/development/ichiran.html) (Geospatial Information Authority of Japan).
- Shop data and walking directions (walkway graph, well-known spots): © [OpenStreetMap contributors](https://www.openstreetmap.org/copyright) (**ODbL**). `worker/public/route/graph.json` / `places.json` are derived databases of OpenStreetMap and are provided under the ODbL.
- All three credits appear both in the footer directly under the 3D Shibuya / nearby shops slots on the meetup screen, and in the MapLibre attribution control (bottom-right of the 3D map).
