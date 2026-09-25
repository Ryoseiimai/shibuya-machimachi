// 渋谷マチマチ iOSアプリ(Capacitor)のネイティブ機能の橋渡し。
// worker/public/assets/js/app.js は window.MachimachiHost があればこれを使い、無ければ(Web版)
// 従来どおりブラウザのAPIを使う。このファイルはアプリ同梱の index.html でだけ読み込む
// (app/scripts/build-www.mjs が app.js より前に同期スクリプトとして差し込む)。
//
// ネイティブ機能は Capacitor が注入する window.Capacitor.Plugins 経由で呼ぶ(バンドラ不要):
//   位置情報 = Geolocation(CoreLocation) / 方位 = Compass(このアプリ独自、AppDelegate.swift)
//   共有 = Share(共有シート) / 触覚 = Haptics / ディープリンク = App(appUrlOpen)
(function () {
  "use strict";
  var Cap = window.Capacitor || null;
  var Plugins = (Cap && Cap.Plugins) || {};
  var apiMeta = document.querySelector('meta[name="api-base"]');
  var API_BASE = apiMeta ? apiMeta.getAttribute("content") : "";
  var API_HOST = API_BASE ? new URL(API_BASE).host : "";
  var URL_SCHEME = "shibuyamachimachi:";
  var ROOM_PATH_RE = /^\/r\/([a-f0-9]{32})\/?$/;
  // デモの部屋ID(端末内だけの架空の部屋。app.jsの/r/:roomId判定に合う32桁16進)
  var DEMO_ROOM_ID = "de" + new Array(31).join("0");
  var LAST_OPENED_URL_KEY = "sm:lastOpenedUrl";

  // 起動直後の画面: アプリは "/"(index.html)から始まるので作成画面(/new)に置き換える。
  // デモの部屋は端末のメモリ上にしか無いため、再読み込みされたら作成画面に戻す。
  (function initialRoute() {
    var p = location.pathname;
    if (p === "/" || p === "/index.html") history.replaceState(null, "", "/new" + location.search);
    else if (p === "/r/" + DEMO_ROOM_ID) history.replaceState(null, "", "/new");
  })();

  // Capacitor はデバッグビルドで console を Xcode のログへ転送するが、Error はJSON化すると "{}" になり
  // 中身が読めない。メッセージとスタックの文字列に変えてから渡す(リリースビルドでは転送自体されない)。
  (function readableConsoleErrors() {
    var original = console.error;
    console.error = function () {
      var args = Array.prototype.map.call(arguments, function (a) {
        if (a instanceof Error) return a.name + ": " + a.message + (a.stack ? "\n" + a.stack : "");
        if (a && a.error instanceof Error) return "error event: " + a.error.message;
        return a;
      });
      return original.apply(console, args);
    };
  })();

  // 3D渋谷(MapLibre GL)のWeb Workerの場所を明示する。MapLibreは自分のURLが http(s) のときしか
  // Workerの場所を自動で決めないため、アプリ(capacitor://)ではこれが無いと建物・ピンが描けない。
  // shibuya3d.mjs と同じURLのモジュールなので、ここでの設定がそのまま地図に効く。
  var MAPLIBRE_URL = "/vendor/maplibre-gl/maplibre-gl.mjs";
  var MAPLIBRE_WORKER_URL = new URL("/vendor/maplibre-gl/maplibre-gl-worker.mjs", location.href).href;
  import(MAPLIBRE_URL).then(function (maplibre) {
    if (maplibre && maplibre.setWorkerUrl) maplibre.setWorkerUrl(MAPLIBRE_WORKER_URL);
  }).catch(function (err) {
    console.error(err);
  });

  var demo = null; // demo.js が有効化したときだけ入る(fetch/WebSocket/位置を端末内の模擬に差し替える)

  function nativeWatchPosition(onPos, onErr, opts) {
    var G = Plugins.Geolocation;
    if (!G) {
      if (navigator.geolocation) return navigator.geolocation.watchPosition(onPos, onErr, opts);
      return null;
    }
    return G.watchPosition(opts || {}, function (pos, err) {
      if (err || !pos) {
        if (onErr) onErr(err);
        return;
      }
      onPos(pos);
    });
  }

  function watchHeading(onHeading) {
    var C = Plugins.Compass;
    if (!C) return false;
    C.addListener("heading", function (e) {
      if (e && typeof e.heading === "number" && e.heading >= 0) onHeading(e.heading);
    });
    C.start().catch(function () {});
    return true;
  }

  function share(opts) {
    if (demo) return demo.share(opts);
    var S = Plugins.Share;
    if (S) {
      return S.share({ title: opts.title, text: opts.text, url: opts.url, dialogTitle: "招待リンクを送る" }).catch(function () {});
    }
    if (navigator.share) return navigator.share(opts).catch(function () {});
    return Promise.resolve();
  }

  function haptic(kind) {
    var H = Plugins.Haptics;
    if (!H) return;
    var p = kind === "success" ? H.notification({ type: "SUCCESS" }) : H.impact({ style: "LIGHT" });
    if (p && p.catch) p.catch(function () {});
  }

  // 招待リンク(https://<本番>/r/<id>?invite=...)・独自スキーム(shibuyamachimachi://r/<id>?invite=...,
  // shibuyamachimachi://demo)を、アプリ内の画面のパスに変換する。対象外のURLは null。
  function routeForUrl(raw) {
    var u;
    try {
      u = new URL(raw);
    } catch (e) {
      return null;
    }
    var path = null;
    if (u.protocol === URL_SCHEME) path = "/" + u.host + u.pathname;
    else if (u.protocol === "https:" && u.host === API_HOST) path = u.pathname;
    if (!path) return null;
    if (path === "/demo" || path === "/demo/") return "/new?demo=1";
    var m = path.match(ROOM_PATH_RE);
    var invite = u.searchParams.get("invite");
    if (m && invite) return "/r/" + m[1] + "?invite=" + encodeURIComponent(invite);
    if (path === "/new" || path === "/") return "/new";
    return null;
  }

  function openUrl(raw) {
    var target = routeForUrl(raw);
    if (!target) return;
    // 同じURLで何度も画面を作り直さない(起動時のURLは再読み込みのたびに取得できてしまうため)
    try {
      if (sessionStorage.getItem(LAST_OPENED_URL_KEY) === raw) return;
      sessionStorage.setItem(LAST_OPENED_URL_KEY, raw);
    } catch (e) {
      /* sessionStorageが使えなくても遷移はする */
    }
    location.href = target;
  }

  if (Plugins.App) {
    Plugins.App.addListener("appUrlOpen", function (e) {
      if (e && e.url) openUrl(e.url);
    });
    var launch = Plugins.App.getLaunchUrl && Plugins.App.getLaunchUrl();
    if (launch && launch.then) {
      launch.then(function (r) {
        if (r && r.url) openUrl(r.url);
      }).catch(function () {});
    }
  }

  window.MachimachiHost = {
    apiBase: API_BASE,
    demoRoomId: DEMO_ROOM_ID,
    fetch: function (url, init) {
      return demo ? demo.fetch(url, init) : window.fetch(url, init);
    },
    createSocket: function (url) {
      return demo ? demo.createSocket(url) : new WebSocket(url);
    },
    geolocation: {
      watchPosition: function (onPos, onErr, opts) {
        return demo ? demo.watchPosition(onPos) : nativeWatchPosition(onPos, onErr, opts);
      },
    },
    watchHeading: watchHeading,
    share: share,
    haptic: haptic,
    setDemo: function (d) {
      demo = d;
    },
    isDemo: function () {
      return !!demo;
    },
    routeForUrl: routeForUrl,
  };
})();
