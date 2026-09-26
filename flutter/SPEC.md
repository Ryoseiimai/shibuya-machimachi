# 渋谷マチマチ Flutter 版 設計書（SPEC）

- 基準: `origin/main` 426e411（#19 歩行ルート案内まで）。ブランチ `feat/flutter`、置き場所 `flutter/`
- Web 版（`worker/`）と Capacitor 版 iOS（`app/`、1.0 審査中）は**触らない**。Flutter 版は別アプリとして並べて作る
- Bundle ID / applicationId: `jp.co.ryoseiworld.shibuyamachimachi.flutter`（Capacitor 版 `jp.co.ryoseiworld.shibuyamachimachi` と別）
- 表示名: 渋谷マチマチ。org: `jp.co.ryoseiworld`。対象: iOS 15+ / Android（Flutter 既定の minSdk）
- 正本の優先順位: サーバー契約は `worker/src/*.js`、画面の文言と動きは `worker/src/html.js`・`worker/public/assets/js/*.js`、道順は `route.js`・`route-panel.js`。この SPEC と食い違ったら JS が正

---

## 1. 要件

### 1.1 Web 版と同じにする機能

| 機能 | 担当 | Web 版の場所 |
|---|---|---|
| 作成（ニックネーム）→ 招待リンク（LINE・共有・コピー） | room | html.js `screen-create` / `waiting-guest` |
| 参加プレビュー → 「承認して参加」 | room | `preview` |
| host の承認 / guest の承認待ち | room | `approve` / `waiting-approval-guest` |
| 待ち合わせ画面（状態バナー・距離と矢印・待ち合わせ場所・会えた判定・停止・階・近くのお店・3D・出典） | room（3D は map3d、道順は route の部品を埋め込む） | `meet` |
| 行き止まり（停止・満員・期限切れ・エラー・読み込み中） | room | `stopped` / `full` / `expired` / `error` / `loading` |
| 場所モード `/go`（1人で定番スポットへ・位置は送らない） | route | `place-select` / `place-route` |
| 道順パネル（場所モード・人モード共通）と階チップ・「◯階に着いた」 | route | route-panel.js |
| 3D渋谷（軽量・fill-extrusion）・2人のピン・道順の線 | map3d | shibuya3d.mjs |
| 高画質3D（PLATEAU LOD2・WebView） | map3d | shibuya3d-hq.mjs |
| AR（カメラ越しに相手の方向を人影で示す） | ar_home | ar.js |
| ホーム（LP の要点・入口・出典・このアプリについて） | ar_home | lp.js |
| デモモード（1台で体験・何も送らない） | core（済） | app/src/demo.js |

VR（WebXR）は移植しない（iPhone では元から出していない）。

### 1.2 ネイティブらしい操作感（Web 版より良くする所）

- 入力エラーは**画面遷移ではなくその場で**出す（TextField の errorText か SnackBar）。Web 版の「エラー画面へ飛ぶ」は直す
- 「リンクをコピー」後に「コピーしました」を出す（`showToast`）
- 状態バナーと判定の注記は読み上げ装置に届く（`StatusBanner` は liveRegion 済み）
- 文字の拡大を禁止しない（OS の文字サイズ設定に追従。レイアウトは 200% で崩れないこと）
- 共有はネイティブの共有シート（share_plus）、確認はネイティブのダイアログ（`showConfirm`）、触覚（`Haptics`）
- 許可（位置・カメラ・モーション）は**必ずボタンのタップの中で**求める。拒否されたら中立表示＋「設定を開く」（permission_handler の `openAppSettings()`）
- 縦画面固定（`main.dart`・Info.plist・AndroidManifest で設定済み）
- 戻るジェスチャー: AR・高画質は `context.push` で重ねるので、スワイプ/戻るで meet に戻る

### 1.3 プライバシーの約束（全担当・厳守）

- 相互承認（phase == active）の前は位置を送らない。**location を送れるのは `RoomController` だけ**。機能側に送信口は無い
- 渋谷駅（35.658, 139.7016）から 1500m の外では送らない（端末の中で判定し、圏外バナーを出す）
- 相手の座標はサーバーから来ない。相手のピン・AR・お店・道順（人モード）は `partnerEstimateProvider`（自分の GPS＋distance/bearing から端末の中で計算）だけを使う。**どこにも送らない・ログに出さない**
- 道順・場所モードは端末の中だけで計算。現在地・行き先・経路を送る fetch/WS を足さない。待ち合わせ場所として送るのは**スポット ID だけ**
- カメラ映像は画面に出すだけ（`startImageStream`・撮影・録画・録音は使わない。`enableAudio: false`）
- WS の URL（secret 入り）・座標・secret を `print`/`debugPrint`/例外メッセージ/クラッシュレポートに出さない（`GeoPoint`・`PositionFix`・`RoomSession` の toString は伏せ字にしてある）
- 2人部屋・招待1回きり・Jev に座標/ニックネームを渡さない（サーバー側の約束。クライアントは変えない）

---

## 2. アーキテクチャ

```
lib/
  main.dart / app.dart        起動・MaterialApp.router・日本語ロケール・ディープリンク
  core/                       ← 骨組み担当だけが編集（機能担当は読むだけ）
    core.dart                 公開面（機能はこれだけ import する）
    constants.dart            定数（サーバー・route.js と同じ値）
    geo.dart / floors.dart    純関数（距離・方位・destinationPoint・渋谷判定・階の変換・jsRound）
    models/room_models.dart   サーバー契約のモデル（全部 nullable）
    models/place.dart         places.json・POI・nearestShops・placesProvider・poisProvider
    api/api_client.dart       HTTP（作る・のぞく・参加）
    ws/room_socket.dart       WebSocket の土台（dart:io・自前ハンドシェイクで 404/401 を取る）
    ws/room_connection.dart   再接続（1→2→4→8→15s）・終わり方（4001/1000/終端/404×2/401）
    ws/outbound_guard.dart    2048バイト上限・location 1.2秒間引き
    session/room_controller.dart  部屋の司令塔（Riverpod Notifier）＋ partnerEstimateProvider
    session/session_store.dart    secure storage に roomId/role/secret/inviteUrl
    sensors/location.dart     positionProvider・LocationService（本物/デモ）
    sensors/orientation.dart  headingProvider（コンパス）・tiltProvider（傾き beta）
    sensors/floor.dart        ownFloorProvider（今いる階。変えたら部屋へ floor を送る）
    demo/demo_mode.dart       デモの模擬サーバー（API＋WS）・demoModeProvider
    providers.dart            API/WS/保存先の差し替え口（デモ中は模擬）
    deep_link.dart            ディープリンク → location
    router.dart               go_router（機能の画面をここで繋ぐ）
    theme.dart                色・文字・ThemeData・contrastRatio
    widgets/                  AppPage・AppCard・ボタン・バナー・FloorChips・PhraseText・出典 等
  features/
    room/     room_screen.dart     ← room 担当
    route/    route_screen.dart    ← route 担当（engine/ も）
    map3d/    map3d_screen.dart    ← map3d 担当（assets/hq/ も）
    ar_home/  ar_home_screen.dart  ← ar_home 担当
```

- 状態管理: **flutter_riverpod 3**（Provider / Notifier / StreamProvider のみ。コード生成なし。legacy の StateProvider は使わない）
- 画面遷移: **go_router 18**
- 部屋はアプリ全体で1つ（`roomControllerProvider` は keepAlive の Notifier）
- 位置・向き・傾きは autoDispose の StreamProvider。誰も見ていなければセンサーは止まる

---

## 3. サーバー契約（要約。詳細は worker/src/index.js・room.js・room-do.js）

本番 `https://shibuya-machimachi.kaeru3160.workers.dev`（WS は `wss://` 同ホスト）。**Origin ヘッダ無しのネイティブ接続は弾かれない**（Origin は CORS ヘッダを足すだけで拒否に使っていない。本番で確認済み）。

### 3.1 秘密値
roomId・inviteToken・hostSecret・guestSecret はすべて `[a-f0-9]{32}`。部屋は作成から3時間で全削除。

### 3.2 HTTP（`ApiClient`）
| 操作 | 要求 | 成功 | 失敗（判定順） |
|---|---|---|---|
| 作る | `POST /api/rooms {nickname}` | `{ok,roomId,hostSecret,inviteToken}` | 429 `rate_limited`（1分5回/IP・`message` 付き）/ 400 `invalid_nickname` |
| のぞく | `GET /api/rooms/{id}/preview?invite=` | `{ok,hostNickname}` | 404 `not_found` / 410 `expired` / 409 `full` / 403 `invalid_invite` |
| 参加 | `POST /api/rooms/{id}/join {invite,nickname}` | `{ok,guestSecret}`（参加＝guest の承認。招待は使用済みに） | 400 `invalid_request` / 404 / 410 / 409 `full` / 403 `invalid_invite` / 400 `invalid_nickname` |

- ニックネーム: 制御文字を除いて trim、1〜20（UTF-16。絵文字は2）。`sanitizeNickname()` がクライアント側で同じ判定をする
- 招待リンク: `{本番}/r/{roomId}?invite={inviteToken}`（`ApiClient.inviteUrl`）
- どのルートにも当たらない 404 は `{"error":"not found"}`（`ApiException('not_found')` に寄せてある）
- 通信の例外は `ApiException('network')`

### 3.3 WebSocket `wss://…/api/rooms/{id}/ws?role={host|guest}&secret=`
- 認証は role+secret だけ。1 role 1 接続。新しい接続が来ると古い方は **close 4001** → 再接続しない
- 期限切れは close 1000 `"expired"`（直前に `{"type":"state","phase":"expired"}` だけの最小形が来る）
- ハンドシェイク失敗: 400 invalid_role / 404 部屋が消えた / 401 unauthorized
- 1メッセージ 2048 バイトまで（超えると黙って捨てる）。location は role ごと 1000ms に1回まで（黙って捨てる）
- アプリ層の ping は送らない（WS の ping フレームは可。25秒にしてある）

送る（`RoomController` のメソッド経由のみ）:
| type | 中身 | 条件 |
|---|---|---|
| `approve` | — | host のみ |
| `floor` | `floor`: B5〜10F | いつでも |
| `location` | `lat,lng,acc` | **core だけが送る**（active・圏内・1.2秒間引き） |
| `spot` | `spotId`: `^[a-z0-9-]{1,40}$` か null | active |
| `judge` | — | active（門は §6.1.6） |
| `stop` | — | いつでも（冪等） |

受ける: `state`（公開状態）/ `locationRejected{reason: not_active|stopped|out_of_area}` / `judgeResult{ok:false, reason, distance_m?, remainingJevCalls?}`（ok:true は無い。成功は `state.judge.found`）/ `error{code}`。

### 3.4 公開状態 `RoomState`（全部 nullable）
`phase`（waiting_guest / waiting_host_approval / active / stopped / expired）、`role`、`roomId`、`expiresAt`、`self{nickname,approved,floor,inArea}`、`other{nickname,approved,connected,inArea*,floor*,lastUpdatedAt*}`（*は active のときだけ）、`distance_m`・`bearing_deg`（active かつ2人とも位置あり）、`floorDiffText`、`meetSpot{id,byMe}`（active のみ）、`stopped{by,at}`、`judge{found,probability,source(jev|distance_only),at,callsUsed,maxCalls,limitReached}`。**lat/lng はどこにも無い。**

phase → 画面: expired→期限切れ / stopped→停止 / waiting_guest→招待 / waiting_host_approval→host は承認・guest は承認待ち / active→meet。

---

## 4. パッケージ（pubspec.yaml に固定。上げるのは統合担当だけ）

| パッケージ | 版 | 用途 | 使う担当 |
|---|---|---|---|
| flutter_riverpod | 3.4.3 | 状態管理 | 全員 |
| go_router | 18.0.1 | 画面遷移 | core |
| http | 1.6.0 | HTTP API | core |
| geolocator | 14.1.0 | 位置 | core |
| flutter_compass | 0.8.1 | 方位（更新が止まっている。壊れたら自前 MethodChannel） | core |
| sensors_plus | 7.1.0 | 傾き | core |
| camera | 0.12.1 | AR のカメラ映像 | ar_home |
| permission_handler | 13.0.2 | カメラ・モーションの許可確認、設定を開く | ar_home / room |
| maplibre_gl | 0.27.1 | 3D渋谷（MapLibre Native） | map3d |
| flutter_inappwebview | 6.1.5 | 高画質3D の WebView（同梱 HTML をカスタムスキームで配る） | map3d |
| flutter_secure_storage | 11.2.0 | セッション保存 | core |
| share_plus | 13.3.0 | 招待リンクの共有 | room |
| url_launcher | 6.3.2 | LINE で送る・GitHub・プライバシー/サポート | room / ar_home |
| app_links | 7.2.1 | ディープリンク | core |
| flutter_localizations | SDK | 日本語のダイアログ・入力 | core |
| flutter_lints | 6.0.0 | lint | — |

Flutter 3.47.5 / Dart ^3.13.4。新しいパッケージが要る担当は、自分では足さず統合担当に依頼する（pubspec は共有物）。

---

## 5. 並列実装の分担と境界

### 5.1 ルール
- 各担当は **`lib/features/<name>/` の中だけ**を編集する（下の「追加で触ってよい所」を除く）。`lib/core/`・`lib/main.dart`・`lib/app.dart`・`pubspec.yaml`・`ios/`・`android/` は骨組み/統合担当だけ
- 公開インターフェース（`<name>_screen.dart` の**クラス名・コンストラクタ・公開メソッドの形**）は固定。中身は自由に差し替え、内部ファイルはフォルダ内に増やしてよい
- 他の機能を使うときは相手の `<name>_screen.dart` の公開クラスだけを import する（内部ファイルを import しない）
- core に足りないものがあれば自分で core を直さず、統合担当に「欲しいインターフェース」を1行で依頼する。待つ間は自分のフォルダ内に仮実装を置く（統合時に core へ移す）
- テストは `test/features/<name>/` に置く。`flutter analyze` 0件・`flutter test` 全通過で渡す
- 各担当は専用の git worktree で作業し、`feat/flutter` から `feat/flutter-<name>` を切る

| 担当 | 編集してよい所 | 追加で触ってよい所 |
|---|---|---|
| room | `lib/features/room/` | `test/features/room/` |
| route | `lib/features/route/` | `test/features/route/` |
| map3d | `lib/features/map3d/` | `test/features/map3d/`、`assets/hq/`（中身を置く。pubspec には `assets/hq/` 登録済み。サブフォルダを作るなら統合担当に登録を依頼） |
| ar_home | `lib/features/ar_home/` | `test/features/ar_home/` |

### 5.2 依存関係（誰が誰の部品を使うか）
- room の meet 画面 → route の `RoutePanel`、map3d の `Map3dView`/`Map3dController`/`MapPin`、`/ar`（ar_home）・`/hq`（map3d）へ push
- route の `GoScreen` → map3d の `Map3dView`（行き先をピン、経路を線）
- 並行作業中は相手の仮画面がそのまま動くので、互いを待たずに進められる

---

## 6. 各機能の仕様

### 6.1 room（`lib/features/room/room_screen.dart`）

公開インターフェース:
```dart
class CreateRoomScreen extends ConsumerStatefulWidget { const CreateRoomScreen({super.key, this.startDemo = false}); final bool startDemo; }
class RoomScreen extends ConsumerStatefulWidget { const RoomScreen({super.key, required this.roomId, this.invite}); final String roomId; final String? invite; }
```

使う core: `roomControllerProvider`（`createRoom`・`startDemo`・`preview`・`join`・`resume`・`approve`・`setSpot`・`judge`・`stop`・`leave`・`clearJudgeFailure`）、`ownFloorProvider`、`partnerEstimateProvider`、`positionProvider`・`headingProvider`・`locationServiceProvider.ensurePermission()`、`placesProvider`・`findPlace`、`poisProvider`・`nearestShops`、`isPartnerStale`、`demoModeProvider`・`DemoConfig`、`AppPage`・`AppCard`・`PrimaryButton`・`SecondaryButton`・`HintText`・`FieldLabel`・`AppBadge`・`StatusBanner`・`LoadingView`・`DeadEndCard`・`FloorChips`・`PhraseText`・`AttributionText(Attributions.all)`・`showConfirm`・`showToast`・`Haptics`。

#### 6.1.1 作成（`/new`）
- カード1: ラベル「ニックネーム(相手に表示されます)」、入力（maxLength 20、hint「例: りょうせい」）、主ボタン「待ち合わせを作る」、hint「作ると1回だけ使える招待リンクが出ます。相手に送って参加してもらいましょう。」「アカウント登録は不要です。作った待ち合わせは3時間で自動的に終了します。」、副ボタン「デモで試す（1台で体験）」＋hint「デモでは、模擬の相手が渋谷駅前であなたに近づいてきます。位置情報は使わず、何も送信しません。」
- カード2: 太字「1人で行きたい場所がありますか？」、副ボタン「場所へ行く（道順で案内・1人で使えます）」→ `/go`、hint「ハチ公像・モヤイ像などの定番スポットまで、歩ける道に沿った矢印で案内します。上の階や地下への移動も案内します。位置はサーバーに送りません。」
- 作るとき: `createRoom(nick)` → 成功で `context.go('/r/<roomId>')`。**位置の許可はこのタップの中で `ensurePermission()`**。失敗はその場で表示: `invalid_nickname`→「ニックネームを入力してください」、`rate_limited`→ `e.message ?? 'しばらく時間をおいてから、もう一度お試しください。'`、`network`→「通信エラーが発生しました」、その他→「作成に失敗しました({reason})」
- `startDemo == true` なら開いた直後に `startDemo(nick)` → `/r/<DemoConfig.roomId>`

#### 6.1.2 部屋（`/r/:roomId`）の入口
1. `resume(roomId)` が true → そのまま接続（招待プレビューを飛ばす）
2. false で `invite` が無い → エラー「このリンクだけでは参加できません。招待リンクを開いてください。」（デモ ID で resume が false なら `/new` へ戻す）
3. `preview(roomId, invite)`: 成功 → 参加プレビュー。`full`→満員「この待ち合わせはすでに満員です。」、`expired`→期限切れ、`not_found`→「待ち合わせが見つかりません。URLを確認してください。」、`network`→「通信エラーが発生しました」、その他→「この招待リンクは使えません。」

#### 6.1.3 画面（`RoomViewState` から出し分け）
- 接続前・state 未着: `LoadingView`（「読み込んでいます…」）
- **招待（host・waiting_guest）**: バッジ「招待リンクを送ってください」、ラベル「招待リンク(1回だけ使えます)」＋読み取り専用の URL（`session.inviteUrl`）、hint「このリンクは1回だけ使えます。公開の場には貼らないでください。」、LINE ボタン（地 `AppColors.lineGreen`・白文字「LINEで送る」・`url_launcher` で `https://line.me/R/msg/text/?` + encodeURIComponent(「{host}さんから渋谷マチマチの招待です」+改行+URL)）、「共有する」（share_plus。title「渋谷マチマチ」、text「{host}さんから渋谷マチマチの招待です」＋URL）、「リンクをコピー」（Clipboard ＋ `showToast('コピーしました')`）、hint「相手がリンクを開いて参加するまでお待ちください。」。**デモ中**は LINE・共有・コピーで `DemoConfig.shareAlertText` をダイアログで出すだけ
- **参加プレビュー（guest）**: 「**{hostNickname}**さんから招待されました。」、ラベル「あなたのニックネーム」（maxLength 20・hint「例: すず」）、hint「承認すると、相手の画面の3D地図にあなたのおおよその位置と近くのお店が表示されます。」、主ボタン「承認して参加」（タップの中で位置の許可 → `join`）、hint「参加すると、位置情報の共有についてお互いが承認するまで位置は送られません。」。失敗「参加に失敗しました({reason})」
- **承認（host・waiting_host_approval）**: 「**{guest}**さんが参加しました。」、hint（上と同じ文）、主ボタン「この人と位置を共有する」→ `approve()`、hint「押すまで、あなたの位置は相手に送られません。」
- **承認待ち（guest・waiting_host_approval）**: 「参加しました。**{host}**さんの承認をお待ちください。」
- **停止**: 「{あなた|相手}が共有をやめたため、位置の共有は停止しました。」（`stopped.by == server.role` ならあなた）
- **期限切れ**: 「この待ち合わせは終了しました(3時間経過)。位置情報のデータは削除されています。」
- **二重接続（`endedBy == duplicate`）**: 「別の画面でこの待ち合わせが開かれたため、こちらの接続を閉じました。」＋「もう一度つなぐ」（`resume` し直し）。Web 版に無い追加
- 行き止まりのボタンは全部「新しく待ち合わせを作る」→ `leave()` してから `/new`（`DeadEndCard(onRestart:)`）
- デモ中は `AppPage(top:)` にデモバナー（地 `AppColors.demoBanner`・白 13px 太字・角丸14・`DemoConfig.bannerText`・右に白ボタン「終了」→ `leave()` → `/new`）

#### 6.1.4 meet（active）上から順に
1. **状態バナー**（1つだけ・優先順）: 通信切れ（`!wsConnected && disconnectedAt != null`、`StatusBanner(offline)`「通信が切れました。位置が更新されていません(最終更新 {HH:MM})」時刻は other.lastUpdatedAt → disconnectedAt → 「--:--」）/ 自分が圏外（`selfOutOfArea`）「渋谷エリアの外なので共有を止めています」/ 相手が圏外（`other.inArea == false`）「相手が渋谷エリアの外にいるため、距離を計算できません」/ 相手が古い（`isPartnerStale`）「相手の位置が古くなっています」。**5秒ごとに再評価**（Timer.periodic で setState）。通信切れ・古いときは距離カードを opacity 0.4
2. **距離カード**: 「相手: **{nickname}**」、矢印（円 180・枠 `brandOrange` 35%・中の矢印 84。回転 `(bearing - heading + 360) % 360`、0.25秒で回す。heading が null なら北が上）、距離 52px `{distance_m}`（無ければ「--」）＋「 m」、最終更新「相手の最終更新: {HH:MM:SS}」か「相手の位置を待っています…」、トグル「道順で案内（歩ける道に沿った矢印）」⇄「まっすぐの矢印に戻す」（ON で矢印を隠し `RoutePanel(mode: person)` を出す。距離の数字は残す）。向きの許可ボタンは不要（ネイティブのコンパスは許可不要）
3. **待ち合わせ場所カード**: ラベル「待ち合わせ場所を決める」、今の場所「まだ決めていません」/「待ち合わせ場所：{name}(あなたが決めました|相手が決めました)」/ 一覧読み込み中「待ち合わせ場所を読み込んでいます…」、ドロップダウン（「場所を選ぶ」＋13件）、副ボタン「ここで待ち合わせる」→ `setSpot(id)`、場所が決まっていれば主ボタン「待ち合わせ場所へ道順で案内」（行き先をそのスポットにして道順 ON）、hint「どちらかが決めると2人に届きます。送るのは場所の名前だけです。」。places が読めなければカードごと隠す。一覧に無い ID は「まだ決めていません」扱い。スポットが消えたら道順の行き先を相手に戻す
4. **会えた判定カード**: 表示「未確認」（地 `judgeIdleBg`）→ found で「会えた! {NN%}」（probability があれば `round(p*100)%`、地オレンジ・白文字、注記「Jev判定」か「距離による判定」、`Haptics.success()` を1回）。主ボタン「会えた！」→ `judge()`。`judgeFailureSeq` が増えたら注記を出す: too_far「まだ20m以内に近づいていません(現在約{d}m)」（d 不明なら括弧なし）/ different_floor「階が違います。同じ階に来てから押してください」/ missing_floor「お互いに今いる階を選んでください」/ missing_location「位置情報を取得中です。少し待ってからもう一度押してください」/ not_active「まだお互いの承認が完了していません」/ judge_in_progress「判定中です。少し待ってからもう一度押してください」/ not_found「まだ判定できませんでした。相手の姿が見えたらもう一度押してください(残り{n}回)」/ その他「まだ判定できません」。注記は liveRegion
5. **停止カード**: 副ボタン「共有をやめる」→ `showConfirm(message: '位置の共有をやめますか？', ok: 'やめる')` → `stop()`（送れなくても端末からの送信は止まり、つながったら送り直される）
6. **今いる階カード**: `FloorChips()`（ラベル付き）と、その下に `floorDiffText`（15px 太字・中央）
7. **近くのお店カード**: ラベル「近くのお店」、`partnerEstimateProvider` の点で `nearestShops(pois, lat, lng)` の3件（左に店名太字、右に「{n}m」、level があれば「{level}階」タグ）。無ければ「相手の位置と階が分かると表示されます。」。POI の読み込み失敗は何も出さない
8. **3D渋谷カード**: ラベル「3D渋谷」、`Map3dView(controller:)`（高さ 280）。`Map3dController` を State で持ち、`setMe(MapPin(point: 自分, floor: floorLabelToInt(ownFloor) ?? 1, name: '自分'))`・`setPartner(MapPin(point: 推定, floor: floorLabelToInt(other.floor) ?? 1, name: other.nickname))`、相手の位置が初めて来たとき1回だけ `focusBoth()`。道順 ON なら `RoutePanel.onRoute` の線を `setRoute(line, fit: 最初の1回だけ)`、OFF で `setRoute(null)`。副ボタン「ARで探す」→ `context.push('/ar')`、「高画質で見る」→ `context.push('/hq')`。3D は active になってから作る
9. **出典**: `AttributionText(Attributions.all)`

#### 6.1.5 道順（人モード）のつなぎ
- 行き先: 待ち合わせ場所モードならそのスポット（`RouteTarget(point, name, level: place.level)`）、それ以外は `RouteTarget(point: partnerEstimate, name: other.nickname, level: appFloorIntToLevel(floorLabelToInt(other.floor)))`
- 到着で `Haptics.success()`
- 階は `ownFloorProvider` を共有（パネル側で変えれば自動で floor が送られ、select/チップも揃う）

#### 6.1.6 「会えた？」の門（サーバー側。表示の説明用）
not_active → missing_location（2人とも2分以内の位置・圏内）→ missing_floor → different_floor → too_far（20m 超）→ Jev（1部屋10回まで、無ければ distance_only）。

受け入れ条件: E2E（`e2e/tests/*.spec.js`）と同じ流れが2台（またはシミュレータ＋デモ）で通る。デモで 作成→3秒で参加→承認→相手が近づく→1F 自動→会えた→停止 まで行ける。

### 6.2 route（`lib/features/route/route_screen.dart` と `lib/features/route/engine/`）

公開インターフェース:
```dart
class GoScreen extends ConsumerStatefulWidget { const GoScreen({super.key}); }
enum RoutePanelMode { place, person }
class RouteTarget { const RouteTarget({required this.point, required this.name, this.level}); final GeoPoint point; final String name; final num? level; }
class RoutePanel extends ConsumerStatefulWidget {
  const RoutePanel({super.key, required this.mode, required this.target, this.onRoute, this.onArrive});
  final RoutePanelMode mode; final RouteTarget? target;
  final ValueChanged<List<GeoPoint>?>? onRoute;   // 経路を計算するたび（null=経路なし）
  final VoidCallback? onArrive;                   // 到着の瞬間に1回
}
```

使う core: `positionProvider`（自分）・`headingProvider`（矢印の回転）・`ownFloorProvider`（今いる階。ラベル⇄`floorLabelToLevel`/`levelToFloorLabel`）・`placesProvider`・`kAssetGraph`・`levelLabel`・`jsRound`・`distanceMeters`・`bearingDegrees`・`isInShibuyaArea`・`FloorChips`・`PhraseText`・`Attributions.places`/`placeRoute`・`Haptics`。

- **エンジン**: `worker/public/assets/js/route.js` を `lib/features/route/engine/route_engine.dart` に**1対1で移植**（decodeGraph・snapToGraph・findRoute(A*)・assembleRoute・assignFloors・buildManeuvers・floorChangeText・formatDistance・maneuverText・remainingText・guide・routeLineCoordinates）。定数は route.js と同じ（OFF_ROUTE_M 25・ARRIVAL_M 15・WALK_M_PER_MIN 80・FLOOR_PROMPT_M 20・LEVEL_MATCH_TOLERANCE 0.5・LEVEL_MISMATCH_PENALTY_M 30・SNAP_MAX_M 150・WAYPOINT_MIN_AHEAD_M 6・TURN_SMOOTH_M 8・TURN 35/60/150・MANEUVER_MERGE_M 6・NEAR_MANEUVER_M 8・BACKTRACK_PENALTY_M 3・コスト式）。型付き配列（Float64List/Int32List/Uint8List）、弧番号 `edge*2+向き`、番兵 −1/−2/−3
- **グラフは同梱アセット**（`rootBundle.loadString(kAssetGraph)` → `compute()` で decode。1回だけ・失敗したら再試行できるように）。places は `placesProvider`
- **JS とずれる所**: 丸めは全部 `jsRound`（Dart の round は負の .5 で違う）/ `Number(x)||0` は `x.isFinite ? x : 0` / `toFixed(1)` は `toStringAsFixed(1)` / snap は生の OSM level、guide の照合は推定階（fromFloor/toFloor）で比べる（JS の現状どおり）/ 地上の階推定は意図的な簡略化（コメントを残す）
- **パネルの状態機械**: route-panel.js どおり（REPLAN_MIN_INTERVAL_MS 3000・VIRTUAL_POSITION_RELEASE_M 15・TARGET_MOVE_REPLAN_M 20・エリア外なら計算しない・name が変われば別の目的地・「◯階に着いた」で仮の位置＋階変更）
- **表示の優先順**: 読み込み失敗「道のデータを読み込めませんでした。通信を確かめて開き直してください」/ 読み込み中「道のデータを読み込んでいます…」/ 現在地なし「現在地を取得しています…(位置情報を許可してください)」/ 圏外「渋谷エリア(駅から1.5km)の外なので、道順は出せません」/ 行き先なし（place「行き先を選んでください」・person「相手の位置を待っています…」）/ no_start「近くに歩ける道が見つかりません(渋谷駅から1.5km以内で使えます)」/ no_goal「目的地の近くに歩ける道が見つかりません」/ unreachable「道順が見つかりませんでした」/ その他「道順を計算しています…」/ 案内中 `instruction.text`、到着「到着しました！」（オレンジ地・白字・`onArrive`）
- パネル: バッジ「道順で案内」、行き先名 18px＋` {levelLabel}`、矢印の円 150（矢印 72、`((bearing − (heading ?? 0)) % 360 + 360) % 360`、案内なし/到着は opacity 0.3）、案内文 22px/900（liveRegion・`PhraseText`）、残り「残り{x}・約{n}分」、階移動中は地 `brandOrangeSoftBg`・字 `brandOrangeOnSoft`、「{levelLabel}に着いた」ボタン、`FloorChips`、注記（place「位置情報は／この端末の中だけで使い、／サーバーには／送りません。」、person「道順は／この端末の中で／計算します。／相手の位置は、／届いた距離と方角からの／推定です。」）
- **GoScreen**: カード1 バッジ「場所へ行く（1人で使えます）」、本文「行きたい場所を選ぶと、歩ける道に沿った矢印で案内します。エスカレーターや階段での上の階・地下への移動も案内します。」、13件のリスト（名前 16/800・hint 12・右に「直線{formatDistance}」）、状態文（「場所の一覧を読み込んでいます…」/「場所の一覧を読み込めませんでした。通信を確かめて開き直してください。」/ 拒否「位置情報がオフになっています。許可すると道順を案内できます。」）、hint「位置情報はこの端末の中だけで使い、サーバーには送りません。」。カード2 副ボタン「相手と待ち合わせる（招待リンクを作る）」→ `/new`。出典 `Attributions.places`
- 選んだら: タップの中で `ensurePermission()`、`ownFloorProvider.setByUser(levelToFloorLabel(place.level))`、パネル＋カード「3D渋谷（オレンジの線が道順）」（`Map3dView`。行き先を `setPartner(MapPin(point: place, floor: levelToAppFloorInt(place.level), name: place.name))`、自分を `setMe`、経路を `setRoute(line, fit: その場所の最初の経路だけ)`）、副ボタン「ほかの場所を選ぶ」、出典 `Attributions.placeRoute`。到着で `Haptics.success()`
- **テスト**: route.test.js の15件と route-data.test.js（版の一致・156組の全ペアで findRoute ok・ハチ公像→モヤイ像 150〜700m・地下3階 `{35.658588, 139.702834, level -3}` からハチ公像で「(エスカレーター|階段|エレベーター)で(地下\d+|\d+)階へ」）を `test/features/route/` に移植

### 6.3 map3d（`lib/features/map3d/map3d_screen.dart` と `assets/hq/`）

公開インターフェース（置き済み。`Map3dController` は実装済みの状態の箱なので、そのまま使ってよい）:
```dart
class MapPin { const MapPin({required this.point, required this.floor, this.name}); }          // floor は app の階整数
class Map3dController extends ChangeNotifier { setMe(MapPin?); setPartner(MapPin?); focusBoth(); setRoute(List<GeoPoint>?, {bool fit = false}); }
class Map3dView extends StatefulWidget { const Map3dView({super.key, required this.controller, this.height = 280}); }
class HqViewerScreen extends ConsumerStatefulWidget { const HqViewerScreen({super.key}); }   // `/hq`
```

**軽量3D（Map3dView・maplibre_gl）** — `shibuya3d.mjs` が正:
- style は JSON 文字列で丸ごと渡す（`sky` は Native 未対応なので外し、地図の上端に薄い空色グラデーションを重ねるか省く）。レイヤー: `bg #eef1f3` / 地理院 pale ラスタ `https://cyberjapandata.gsi.go.jp/xyz/pale/{z}/{x}/{y}.png`（256・maxzoom 18）/ `buildings-3d` fill-extrusion（ヒカリエ・ストリームは `#c8431f`、他は height で {0:#f7f8fa,20:#eef0f3,60:#dee2e6,120:#c7cdd3,220:#a6aeb7}、opacity 0.6、vertical-gradient）/ pins-glow 2層 / pins-line（点線 `#c8431f` 2.4・dash [1.4,1.6]）/ route-line-casing（白 8）/ route-line（`#c8431f` 5）/ pins-3d（8m 角の柱）
- light `{anchor: viewport, color #fff, intensity 0.38, position [1.4,210,42]}`
- カメラ: 中心 `kMapCenterLat/Lng`、zoom 15.6（14〜19）、pitch 50（最大60）、bearing −17、範囲は駅から ±1700m。最初は pitch 60 で +3°/秒回し、ユーザー操作か setMe/setPartner で止める
- 建物 GeoJSON（4.1MB）は同梱 `kAssetBuildings`。アセット URL 渡し（`asset://…`）を実機で確かめ、だめなら起動時に1回だけ渡す
- ピンの高さ: 地上 `階×3.5m`（0階は1F扱い）、地下は 5m 固定でラベル `B{n}`。色 自分 `AppColors.pinMe`（地下 `pinMeUnderground`）・相手 `pinPartner`（地下 `pinPartnerUnderground`）。ラベルは地図の上に Stack で重ね、`toScreenLocation(Batch)` で位置を求め、`heightM / metersPerPixel × sin(pitch)` 持ち上げる（56px より近ければ奥側を +34px）。ラベル「{名前} ・ {formatFloor}」
- ランドマークのラベル6件（スクランブルスクエア・ヒカリエ・SHIBUYA109・ストリーム・フクラス・ハチ公像。座標と高さは shibuya3d.mjs）
- focusBoth: 0人→駅（zoom 15.6）、1人→そのピン（zoom 17）、2人→fitBounds（maxZoom 17・800ms）。padding は縦 12%（12〜40px）・横 max(12%, ラベル幅/2)（12〜90px）、どちらも「幅/高さの半分−12」を上限（NaN を出さない）
- setRoute: 2点以上で線を出し点線を隠す。fit なら上 +34px の padding で maxZoom 17.5
- dispose で地図を破棄

**高画質3D（HqViewerScreen・flutter_inappwebview）** — `shibuya3d-hq.mjs` が正:
- `assets/hq/` に `worker/public/vendor/three/`（three.module.js・GLTFLoader・DRACOLoader・BufferGeometryUtils・draco の wasm と wrapper）、`vendor/3d-tiles-renderer/`、`shibuya3d-hq.mjs`、小さい `index.html` を写す。`file://` は使わず、`resourceCustomSchemes`＋`onLoadResourceWithCustomScheme` で同一オリジン配信（wasm は `application/wasm`）。localhost サーバーを使うならポート 8787・8799 は禁止
- Dart→JS は `evaluateJavascript` で setMe/setPartner、JS→Dart は `callHandler` で ready と読み込み率。外へ通信するのは `https://assets.cms.plateau.reearth.io` の GET だけ（`shouldOverrideUrlLoading` で他を止める）。座標を WebView から外に出す処理を作らない
- 省メモリ設定（TOUCH_LIMITS）を HTML 側で強制: 半径 500m・テクスチャ 1024/512・キャッシュ 220/150MB・ダウンロード4・展開2・draco Worker 2
- 画面: 地 `#0b1114`、右上「✕」（`tooltip: '閉じる'`）、下に `Attributions.hq`（白75%）、読み込み表示「高画質モデルを読み込み中…」「テクスチャ付きの3D建物データ(数十MB)を読み込みます。モバイル回線では時間がかかることがあるため、Wi-Fi推奨です。」
- **閉じたら JS の `destroy()` → WebView ごと破棄**。AR と同時に開かない。active でなくなったら自分で閉じる
- 表示に使う値: 自分 `positionProvider`、相手 `partnerEstimateProvider`、階 `roomControllerProvider` の `self.floor`/`other.floor`（`floorLabelToInt`）

### 6.4 ar_home（`lib/features/ar_home/ar_home_screen.dart`）

公開インターフェース:
```dart
class HomeScreen extends ConsumerWidget { const HomeScreen({super.key}); }        // `/`
class ArScreen extends ConsumerStatefulWidget { const ArScreen({super.key}); }    // `/ar`
```

**ホーム（`/`）** — lp.js の要点をネイティブの入口に:
- ヒーロー: キッカー「渋谷駅から1.5km限定・無料」、見出し「今日、渋谷の待ち合わせで困ったから作りました。」、副見出し「**渋谷マチマチ** — お互いに承認した2人だけで、渋谷で迷わず会える」、主ボタン「待ち合わせを作る」＋小さく「（無料・登録なし）」→ `/new`、注記「ニックネームだけで今すぐ使えます。アカウント登録は不要です。」、リンク「1人で使う：場所へ行く（道順で案内）」→ `/go`、「デモで試す（1台で体験）」→ `/new?demo=1`
- 「渋谷マチマチができること」7項目・「安心して使えるための設計」6項目・「使い方は3ステップ」（文言は lp.js / この下の表）。長くなるので折りたたみでもよい
- 「このアプリについて」: GitHub（https://github.com/Ryoseiimai/shibuya-machimachi）、プライバシーポリシー（`{本番}/privacy`）、サポート（`{本番}/support`）を url_launcher で、ライセンス（`showLicensePage`）、出典 `Attributions.all`
- 保存済みの部屋があれば「続きを開く」を出してよい（任意）

安心の設計6項目: 承認した2人だけに位置が届く / 招待リンクは1回きりで無効になる / どちらかが押せば、いつでも即座に停止できる / 待ち合わせは3時間で自動的に削除される / 渋谷駅から1.5km以内でだけ使える / 位置情報はサーバーのログに残さない

**AR（`/ar`）** — ar.js が正:
- 地は黒。`camera` 0.12.1 で背面カメラを `CameraController(..., ResolutionPreset.high, enableAudio: false)`→`CameraPreview`。`startImageStream`・`takePicture`・録画は**使わない**。`didChangeAppLifecycleState` で dispose/再初期化
- 許可はこの画面を開くタップ（meet の「ARで探す」）の後、画面の最初のタップ or initState で `Permission.camera` / `Permission.sensors` を確認。拒否は下端の赤帯で表示し「設定を開く」
- 値: 自分 `positionProvider`、相手 `partnerEstimateProvider`（null なら「相手の位置を待っています…」）、向き `headingProvider`（null なら中立表示）、傾き `tiltProvider`、相手の名前と階 `roomControllerProvider`（`other.nickname`・`other.floor`、自分は `ownFloorProvider`）
- 描画（毎回・両方そろったとき）: `dist = distanceMeters`、向きが無い→人影と矢印を出さず中央に「コンパスが使えないので方向は出せません。距離: {round(dist)}m」。`rel = normalizeAngleDiff(heading, bearing)`、|rel| ≤ 30 なら人影: x = W/2 + clamp(rel/30,−1,1)×W×0.42、y = H×0.56 + clamp((beta−90)×4, −160, 160)、幅 = clamp(2600/max(dist,1), 26, 200)（高さ×2）、足元基準。上から 階差バッジ（`AppColors.arBadgeRed`、相手が上なら「↑{diff}階上」、下なら「↓{formatFloor(partner)}」、同じ階なら出さない）、シルエット（頭の円＋胴体。塗り `rgba(24,24,26,.85)`）、名前 14 太字、距離 13（`formatDistanceAr`）。視野外は右端「→ 右に振り向いて（{距離}・{名前}）」/ 左端「← 左に振り向いて（…）」（黒60%の帯）
- エラー帯（下端・赤）: 向きが無い「この端末・ブラウザは向き(コンパス)に対応していないため、方向は表示できません。距離だけ表示します。」、カメラ拒否「カメラの利用が許可されませんでした。設定からカメラへのアクセスを許可してください。」、カメラ無し「この端末・ブラウザではカメラが利用できません。」（カメラが使えないときは地 `#5a5d63`）
- 右上「✕」（`tooltip: '閉じる'`・40px）。active でなくなったら自分で閉じる。高画質と同時に開かない
- 映っている人の検出や識別は一切しない（人影は方向を示す図形）

---

## 7. core が各機能に出しているインターフェース（`import '../../core/core.dart';`）

| 分類 | 名前 | 形 |
|---|---|---|
| 部屋 | `roomControllerProvider` | `NotifierProvider<RoomController, RoomViewState>` |
| | `RoomController` | `Future<RoomSession> createRoom(String nick)` / `startDemo(String nick)` / `Future<String> preview(id, invite)` / `Future<RoomSession> join(id, invite, nick)` / `Future<bool> resume(id)` / `bool approve()` / `bool sendFloor(label)`（通常は ownFloor 経由）/ `bool setSpot(String? id)` / `bool judge()` / `bool stop()` / `void clearJudgeFailure()` / `Future<void> leave()`。失敗は `ApiException(reason, status, message)` |
| | `RoomViewState` | `session`・`server`（`RoomState?`）・`connection`・`disconnectedAt`・`lastJudgeFailure`＋`judgeFailureSeq`・`lastLocationRejected`・`lastErrorCode`＋`errorSeq`・`selfOutOfArea`・`stopRequested`・getter `phase`・`isActive`・`wsConnected`・`endedBy`（`ConnectionEnd.duplicate/expired/unauthorized/terminal`）・`isDemo` |
| | `partnerEstimateProvider` | `Provider.autoDispose<GeoPoint?>`（active・自分の位置・distance/bearing が揃ったときだけ） |
| | `isPartnerStale(RoomState?)` | 相手の位置が2分より古いか |
| モデル | `RoomState`・`SelfView`・`OtherView`・`MeetSpotView`・`StoppedInfo`・`JudgeView`・`Phase`（`.wire`・`.isTerminal`）・`Role`・`RoomSession`・`JudgeResultEvent` | §3.4 |
| 位置 | `positionProvider` | `StreamProvider.autoDispose<PositionFix>`（`lat,lng,accuracy,timestampMs,point,inShibuya`） |
| | `locationServiceProvider` | `ensurePermission()`（タップの中で）/ `currentAccess()` → `LocationAccess.granted/denied/deniedForever/serviceDisabled` |
| 向き | `headingProvider` | `StreamProvider.autoDispose<double?>`（真北0・時計回り。無ければ null） |
| 傾き | `tiltProvider` | `StreamProvider.autoDispose<double>`（beta 相当。縦に立てて正面=90） |
| 階 | `ownFloorProvider` | `NotifierProvider<OwnFloorNotifier, String?>`。`setByUser(label)`（部屋が開いていれば送る）/ `syncFromServer`（core が呼ぶ）/ `clear()` |
| データ | `placesProvider` / `findPlace` / `Place` | 同梱 places.json（13件） |
| | `poisProvider` / `nearestShops(pois, lat, lng, n: 3)` / `NearbyShop` | 同梱 POI（2,789件） |
| 純関数 | geo.dart | `distanceMeters`・`bearingDegrees`・`normalizeAngleDiff`・`destinationPoint`・`destinationFromOffset`・`isInShibuyaArea`・`formatDistanceAr`・`jsRound`・`clampDouble`・`GeoPoint`・`kDefaultFovDegrees` |
| | floors.dart | `isValidFloor`・`floorLabelToInt`・`formatFloor`・`floorDiffLabel`・`floorLabelToLevel`・`levelToFloorLabel`・`levelLabel`・`appFloorIntToLevel`・`levelToAppFloorInt` |
| 定数 | constants.dart | `kProdBaseUrl`・`kAppScheme`・`kShibuyaStationLat/Lng`・`kShibuyaRadiusM`・`kMapCenterLat/Lng`・`kMeetDistanceM`・`kLocationStaleMs`・`kRoomTtlMs`・`kMaxJudgeCalls`・`kFloors`・`kRouteGraphVersion`・`kPlacesVersion`・`kAsset*`・`kHex32`・`kSpotIdPattern`・`kNicknameMaxLength` |
| デモ | `demoModeProvider`・`DemoConfig`（`roomId`・`bannerText`・`shareAlertText`・`inviteText` 等） | デモ中は API・WS・位置・保存が全部模擬 |
| テーマ | `AppColors`・`AppText`・`buildAppTheme()`・`kContentMaxWidth`・`contrastRatio` | 新しい色を足すときは 4.5:1 をテストに足す |
| 部品 | `AppPage(children, top, bottom, showHeader)`・`BrandHeader`・`AppCard`・`PrimaryButton`・`SecondaryButton(selected:)`・`HintText`・`FieldLabel`・`AppBadge`・`StatusBanner(kind: offline/warn)`・`LoadingView`・`DeadEndCard(message, onRestart)`・`NotFoundScreen`・`showConfirm`・`showToast`・`Haptics.success/light`・`FloorChips(showLabel, onChanged)`・`PhraseText`（「、。)）」と「／」で区切り、文節の途中で改行しない）・`AttributionText`・`Attributions.all/places/placeRoute/hq` | |
| 遷移 | `lib/core/router.dart` の `AppRoutes`（core.dart からは出していない。機能は `context.go('/new')` 等の文字列で可） | §8 |

---

## 8. 画面遷移・ディープリンク

| パス | 画面 | 担当 |
|---|---|---|
| `/` | `HomeScreen` | ar_home |
| `/new`（`?demo=1`） | `CreateRoomScreen(startDemo:)` | room |
| `/demo` | → `/new?demo=1` | core |
| `/go` | `GoScreen` | route |
| `/r/:roomId`（`?invite=`） | `RoomScreen`（roomId が `[a-f0-9]{32}` 以外は NotFound） | room |
| `/ar` | `ArScreen`（meet から `context.push`） | ar_home |
| `/hq` | `HqViewerScreen`（meet から `context.push`） | map3d |
| それ以外 | `NotFoundScreen`「ページが見つかりません」 | core |

作成・参加のあと部屋へは `context.go('/r/<id>')`（戻るで作成画面に戻らない）。

ディープリンク（`lib/core/deep_link.dart`・app_links。Flutter 標準のディープリンクは切ってある）:
- `https://shibuya-machimachi.kaeru3160.workers.dev/r/<id>?invite=<t>` → `/r/<id>?invite=<t>`（iOS はユニバーサルリンク、Android は App Links。どちらも §10 のサーバー変更と iOS の Associated Domains が要る）
- `shibuyamachimachi-flutter://r/<id>?invite=` → 同上、`://demo` → `/new?demo=1`、`://go` → `/go`、`://new` → `/new`
- 同じ URL は二重に開かない
- スキームを `shibuyamachimachi-flutter` にしたのは、同じ端末の Capacitor 版（`shibuyamachimachi://`）と取り合わないため。Flutter 版に置き換える時に戻す

---

## 9. 権限の文言（設定済み）

| 権限 | iOS（Info.plist） | Android |
|---|---|---|
| 位置（使用中のみ） | NSLocationWhenInUseUsageDescription「待ち合わせ相手との距離・方角の計算と、道順の案内に使います。お互いが承認するまで位置は送りません。渋谷駅から1.5kmの外では送りません。」 | ACCESS_FINE_LOCATION・ACCESS_COARSE_LOCATION |
| カメラ（AR） | NSCameraUsageDescription「ARで相手のいる方向を示すため、カメラの映像を画面に表示します。映像は送信も保存もしません。」 | CAMERA（required=false） |
| モーション（傾き） | NSMotionUsageDescription「ARで、端末の傾きに合わせて相手のいる方向を表示するために使います。」 | 不要 |
| マイク | NSMicrophoneUsageDescription「このアプリは音声を録音しません（カメラの部品が必要とするための記載です）。」 | 宣言しない |
| 通信 | — | INTERNET |

- バックグラウンド位置は使わない（`NSLocationAlways…` は入れない）
- permission_handler は Podfile で CAMERA・LOCATION_WHENINUSE・SENSORS だけ有効
- 輸出コンプライアンス: `ITSAppUsesNonExemptEncryption = false`

---

## 10. サーバー側で必要な変更（最小案。実施は統合担当・本番反映は `wrp` で指示された工程のみ）

1. **不要**: ネイティブの Origin 無し接続（HTTP・WS とも弾かれない。本番で確認済み）。Flutter **Web** を出すときだけ `APP_ORIGINS` にそのオリジンを足す
2. **iOS ユニバーサルリンク**（`/r/*` を Flutter 版で開く）: `worker/src/app-origin.js`
   ```js
   export const IOS_APP_IDS = Object.freeze([
     "X72629Z4T6.jp.co.ryoseiworld.shibuyamachimachi",          // Capacitor 1.0（審査中・そのまま）
     "X72629Z4T6.jp.co.ryoseiworld.shibuyamachimachi.flutter",  // Flutter 版
   ]);
   // appleAppSiteAssociation(): appIDs: [...IOS_APP_IDS]
   ```
   `worker/test/app-origin.test.js` の期待値も更新。アプリ側は `ios/Runner/Runner.entitlements` に `com.apple.developer.associated-domains = applinks:shibuya-machimachi.kaeru3160.workers.dev` を足し、`CODE_SIGN_ENTITLEMENTS` を設定（署名チーム X72629Z4T6 が要るので、シミュレータ用の骨組みには未設定）
3. **Android App Links**: `GET /.well-known/assetlinks.json`（今は 404）を index.js に1本足す
   ```json
   [{"relation":["delegate_permission/common.handle_all_urls"],
     "target":{"namespace":"android_app","package_name":"jp.co.ryoseiworld.shibuyamachimachi.flutter",
               "sha256_cert_fingerprints":["<リリース署名の SHA-256>"]}}]
   ```
   Content-Type `application/json`。intent-filter（autoVerify）はアプリ側に設定済み
4. （任意）`/route/*` の CORS は Flutter ネイティブには関係なし。変更不要

---

## 11. 検証

```bash
cd flutter
flutter pub get
flutter analyze                      # 0 issues
flutter test                         # core 33件 + 各機能のテスト
flutter build ios --simulator --debug
flutter run --dart-define=API_BASE=http://<Mac の IP>:<port>   # ローカル wrangler に向けるとき（8787・8799 は使わない）
```

- 実機/シミュレータの手動確認: デモ（`/new?demo=1` か「デモで試す」）で 作成→参加→承認→相手が近づく→会えた→停止
- 2台確認: 本番に向けて host（シミュレータ）＋ guest（Web 版ブラウザ）で相互承認まで。Web 版と Flutter 版は同じサーバー・同じ部屋で混在できる
- 長いコマンドは `perl -e 'alarm 1500; exec @ARGV' -- <cmd>`。プロセス停止は PID 指定のみ

---

## 12. 統合担当のやること

1. 各担当ブランチ（`feat/flutter-room` 等）を `feat/flutter` に順に取り込み、`flutter analyze`・`flutter test`・iOS シミュレータビルドを通す
2. 各担当から来た core への依頼（インターフェース追加）を core に入れる。担当フォルダ内の仮実装を core へ移す
3. §10 のサーバー変更（AASA・assetlinks）を別 PR で。本番反映は指示された工程で `wrp`
4. アイコン・起動画面・署名（チーム X72629Z4T6）・Associated Domains を設定
5. Capacitor 版と App Store Connect には触らない

---

## 13. 意図的な簡略化（既知の限界と本格対応の入口）

- WebSocket のハンドシェイクで Sec-WebSocket-Accept を照合していない（TLS 前提）→ 厳密にするなら package:crypto で SHA-1 照合（`room_socket.dart`）
- 圏外では location を送らないので、サーバー側の `self.inArea`/相手から見た `other.inArea` は古い値のまま残る（相手には `lastUpdatedAt` が古くなることで伝わる）→ 圏外を相手に明示したいなら、座標を含まない「圏外になった」メッセージをサーバーに足す
- 止まっていて GPS が更新されないとき、最後の位置を 20 秒ごとに送り直す（相手の画面・判定で「古い」扱いにならないように。送るのは既に送った位置と同じ・active かつ圏内のときだけ）
- flutter_compass は更新停止中 → 自前 MethodChannel（iOS `CLLocationManager.startUpdatingHeading`、Android `TYPE_ROTATION_VECTOR`）が入口
- 地上の階推定（道順）は route.js と同じ簡略化。ビル単位の階対応表や国交省の歩行空間ネットワークで補正するのが入口
