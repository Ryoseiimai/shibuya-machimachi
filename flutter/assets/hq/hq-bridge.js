// 高画質3D の WebView と Flutter をつなぐ小さな橋(Flutter 版だけのファイル)。
//
// Flutter → JS: window.machimachiHQ.setMe(lat, lng, floor) / setPartner(lat, lng, floor, name) / destroy()
//   (Dart の callAsyncJavaScript から呼ぶ。座標はこの WebView の中で描くだけで、どこにも送らない)
// JS → Flutter: callHandler("machimachiHq", { type, ... }) で次の4種類だけを知らせる。座標・名前は載せない。
//   { type: "ready" } / { type: "progress", pct: 0..100 } / { type: "loaded" } / { type: "error", code }
import { mountShibuyaHQ } from "./shibuya3d-hq.js";

const HANDLER_NAME = "machimachiHq";
const pending = [];
let platformReady = false;

// 橋が使えるか。Android は flutterInAppWebViewPlatformReady(= _platformReady)の後、
// iOS は WKScriptMessageHandler が最初から居るので、見つかった時点で使える。
function bridge() {
  const b = window.flutter_inappwebview;
  if (!b || typeof b.callHandler !== "function") return null;
  const iosHandler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.callHandler;
  return platformReady || b._platformReady === true || iosHandler ? b : null;
}

function flush() {
  const b = bridge();
  if (!b) return;
  while (pending.length) b.callHandler(HANDLER_NAME, pending.shift());
}

// 橋ができる前の知らせは溜めておき、できたら順に流す。
function post(message) {
  pending.push(message);
  flush();
}

window.addEventListener("flutterInAppWebViewPlatformReady", () => {
  platformReady = true;
  flush();
});

const container = document.getElementById("hq-mount");
let api = null;
let destroyed = false;

window.machimachiHQ = {
  setMe(lat, lng, floor) {
    if (api && !destroyed) api.setMe(lat, lng, floor);
  },
  setPartner(lat, lng, floor, name) {
    if (api && !destroyed) api.setPartner(lat, lng, floor, name);
  },
  destroy() {
    if (destroyed) return;
    destroyed = true;
    if (api) api.destroy();
    api = null;
  },
};

mountShibuyaHQ(container, {
  showOverlay: false,
  onProgress: (pct) => post({ type: "progress", pct }),
  onLoaded: () => post({ type: "loaded" }),
  onError: (code) => post({ type: "error", code }),
}).then((mounted) => {
  if (destroyed) {
    mounted.destroy();
    return;
  }
  api = mounted;
  post({ type: "ready" });
}).catch(() => {
  // WebGL が作れない等。詳しい理由(例外の文面)は送らず、種類だけ知らせる。
  post({ type: "error", code: "mount" });
});
