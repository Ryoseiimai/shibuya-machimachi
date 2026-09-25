# 渋谷マチマチ iOSアプリ (`app/`)

App Store版「渋谷マチマチ」(Bundle ID `jp.co.ryoseiworld.shibuyamachimachi`)。Capacitor 8 で作っています。

## 仕組み

- **画面はアプリに同梱**します。`scripts/build-www.mjs` が `worker/src/html.js` の画面と `worker/public/` の
  3D渋谷・AR・地図データ・ライブラリを `www/` に組み立て、アプリはそれを `capacitor://localhost` から読みます
  (Webページを開くだけの「包み」ではありません)。**通信(API・WebSocket)だけ**本番Worker
  `https://shibuya-machimachi.kaeru3160.workers.dev` へ行きます。Worker側は `capacitor://localhost` だけをCORSで許可しています(`worker/src/app-origin.js`)。
- **ネイティブ機能**は `src/native-bridge.js` が `window.Capacitor.Plugins` 経由でつなぎ、`window.MachimachiHost` として
  `worker/public/assets/js/app.js` に渡します(Web版では `MachimachiHost` が無いので従来どおり)。
  - 位置情報: `@capacitor/geolocation`(CoreLocation。使用中のみ)
  - 方位(コンパス): アプリ独自プラグイン `ios/App/App/CompassPlugin.swift`(CoreLocationの方位。許可ボタン不要)
  - 共有シート: `@capacitor/share` / 触覚: `@capacitor/haptics`(「会えた!」のとき)
  - ディープリンク: `@capacitor/app`。招待リンク `https://…/r/<id>?invite=…` はユニバーサルリンク
    (`/.well-known/apple-app-site-association` は Worker が返す)、独自スキーム `shibuyamachimachi://demo` / `shibuyamachimachi://r/<id>?invite=…`
- **デモモード**(`src/demo.js`): 作成画面の「デモで試す」で、サーバーの代わりに端末内で相手「すず」の参加・承認・移動を模擬します。
  何も送信せず、実際の位置も使いません(渋谷の外にいる人・App Reviewが1台で試すため)。

## ビルド

```bash
cd app
npm ci
npm run sync                      # www/ を組み立てて ios/ に反映(npx cap sync ios)
open ios/App/App.xcodeproj        # Xcodeで実行。または下のxcodebuild
```

シミュレータ: `xcodebuild -project ios/App/App.xcodeproj -scheme App -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' CODE_SIGNING_ALLOWED=NO build`

## App Store提出(メンテナ用)

- アーカイブ→アップロード: `xcodebuild archive … -allowProvisioningUpdates` → `xcodebuild -exportArchive -exportOptionsPlist store/ExportOptionsUpload.plist -allowProvisioningUpdates`
  (配布署名はXcodeにサインイン済みのApple IDのクラウド署名。APIキーだけではクラウド署名の権限が無く失敗した)
- 掲載情報: `python3 store/asc_metadata.py <App Apple ID>`(`store/metadata.json` の内容。鍵は `~/.appstoreconnect/`、審査連絡先は `~/.appstoreconnect/review_contact.json` から読む。リポジトリには置かない)
- スクリーンショット: `store/shots/run.sh <シミュレータUDID> <保存先>`(UIテストがデモモードで実画面をたどって撮る)→ `python3 store/asc_screenshots.py <App Apple ID> <png>...`
- 「アプリのプライバシー」はASC APIに無いため、ASCのWeb画面(またはそのセッションの内部API)で申告する:
  正確な位置情報・その他のユーザーコンテンツ(ニックネーム) / アプリの機能 / ユーザーに紐づけない / トラッキングなし

## 既知の限界

- 意図的な簡略化: 対応は iPhone のみ(縦画面)・日本語のみ。
- ユニバーサルリンクはアプリのインストール時にAppleがAASAを取得できた場合だけ効く。効かないときは招待リンクはブラウザ版で開く(ブラウザ版でも同じ流れで参加できる)。
- シミュレータでは方位(コンパス)が取れないため矢印は北基準のまま。実機で確認すること。
