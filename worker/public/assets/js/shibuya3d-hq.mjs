// 渋谷マチマチ「高画質で見る」ビュー: PLATEAU 渋谷区(13113) LOD2 テクスチャ付き建築物モデルを
// 3D Tiles 1.0でストリーミング表示する。既定のshibuya3d.mjs(MapLibre GL、灰色の箱)とは別の
// 重い部品なので、ボタンを押したときだけ動的importで読み込む(worker/public/assets/js/app.js参照)。
//
// レンダラ: three.js(worker/public/vendor/three/、既存vendor) + 3d-tiles-renderer
// (worker/public/vendor/3d-tiles-renderer/、npm 3d-tiles-renderer@0.5.3のbuild/index.three.js
// +renderer-CUfHAmYW.js を、bare specifier importをこのvendor構成への相対pathに書き換えて
// 自ホスト。CesiumJSより軽量なためこちらを選んだ。VERSION.txt参照)。Cesium Ion・APIキーは
// 一切使わない(PLATEAUの配信は認証不要の公開GCSバケット、CORS: Access-Control-Allow-Origin: *)。
//
// データソース: 国交省PLATEAU データカタログAPI
// (https://api.plateauview.mlit.go.jp/datacatalog/plateau-datasets, id=13113_bldg_lod2)から
// 特定した渋谷区13113の建築物モデルLOD2(テクスチャあり, 2025年度版)のtileset.json。
// 出典表記は呼び出し元(worker/src/html.js)側で表示する(このモジュールは描画のみ担当)。
//
// PLATEAUのb3dmタイルはextensionsRequired: CESIUM_RTC / EXT_texture_webp /
// KHR_draco_mesh_compression を使う(2026-09-25 実タイルを取得して確認済み)。three.jsの
// GLTFLoaderはEXT_texture_webpとDracoは標準対応だが、CESIUM_RTC(glTF拡張としての方)は
// 非対応(コンソール警告のみで無視される)ため、3d-tiles-renderer本体の小さな公式プラグイン
// (GLTFCesiumRTCExtension、Apache-2.0)を個別に自ホストして登録している。
//
// 意図的な簡略化: (1) 地理院タイルのベース地図は貼らない(three.js側では地形/衛星写真の
// ドレープ描画をこの部品専用に作り込む時間がなく、素の空色背景+平面の地面ディスクのみ)。
// (2) 2人のピンはこのファイル内で floorInfo 相当のロジックを簡易に再実装している
// (shibuya3d.mjs非export関数を使い回さず、モジュール間の結合を避けるための重複。
// 本格的に共通化するなら共有ヘルパーファイルへ切り出すのが次の一手)。
// (3) 大きな地心座標(ECEF、原点から約637万m)による三角形頂点のfloat32精度は
// カメラ相対レンダリングまでは実装していない(見た目の粗い基準)。

import * as THREE from "../../vendor/three/three.module.js";
import { GLTFLoader } from "../../vendor/three/examples/jsm/loaders/GLTFLoader.js";
import { DRACOLoader } from "../../vendor/three/examples/jsm/loaders/DRACOLoader.js";
import { TilesRenderer, GlobeControls, WGS84_ELLIPSOID } from "../../vendor/3d-tiles-renderer/index.three.js";
import { GLTFCesiumRTCExtension } from "../../vendor/3d-tiles-renderer/GLTFCesiumRTCExtension.js";

const MODULE_URL = import.meta.url;
const DRACO_DECODER_PATH = new URL("../../vendor/three/examples/jsm/libs/draco/gltf/", MODULE_URL).href;

// PLATEAU データカタログAPI(id=13113_bldg_lod2, texture:true)から取得したtileset.json直リンク。
// GCSバケット(assets.cms.plateau.reearth.io)がAccess-Control-Allow-Origin: *を返すため
// フロントから直接fetchできる(2026-09-25確認)。
const TILESET_URL = "https://assets.cms.plateau.reearth.io/assets/16/b016d3-42ef-4428-ad99-d229310b39fd/13113_shibuya-ku_pref_2025_citygml_1_op_bldg_3dtiles_13113_shibuya-ku_lod2/tileset.json";

const STATION = { lat: 35.659, lng: 139.7005 };
const DEG2RAD = Math.PI / 180;
const EARTH_RADIUS_M = 6378137; // 範囲判定用(WGS84赤道半径。駅から数百mの判定なので球近似で足りる)
const FLOOR_HEIGHT_M = 3.5;
const BASEMENT_PILLAR_HEIGHT_M = 5;
// PLATEAUの3D Tilesは楕円体高(標高＋ジオイド高)で置かれているため、楕円体高0に地面を置くと建物が約50m浮く。
// 意図的な簡略化: 地面とピンの基準を「渋谷駅付近の楕円体高」一定値に置く(ジオイド高 約36.7m＋駅付近の標高 約15m)。
// 渋谷は谷地形なので坂の上の建物は最大20m程度浮いて見える。本格対応はPLATEAU地形(DEM)を読み込んで地点ごとの高さを使うこと。
const GROUND_ELLIPSOIDAL_HEIGHT_M = 52;
const ACCENT_COLOR = "#c8431f";
const ME_COLOR = "#1e88e5";
const PARTNER_COLOR = "#fb8c00";

const INTRO_ELEVATION_DEG = 30; // MapLibre側の「ピッチ60度」に相当する見下ろし角(90-60=水平線から30度)
const INTRO_DISTANCE_M = 550; // 900mだと視野に入るタイル数が多すぎ、駅周辺の詳細タイルへの収束が遅かった(2026-09-25実測)
const INTRO_RAD_PER_SEC = 3 * DEG2RAD; // ゆっくり回り込む速さ(360度を約2分)

// モバイル回線・非力な端末では詳細度を落として転送量・負荷を抑える(タスク仕様の
// 「スマホで重い場合の注意書き」に対応する実措置)。ポインタが「coarse」(タッチ操作)かどうかで判定する。
const IS_COARSE_POINTER = typeof matchMedia === "function" && matchMedia("(pointer: coarse)").matches;
const MB = 1024 * 1024;

// 端末ごとの負荷の上限。PLATEAUの最も細かいタイル(約200m四方)はテクスチャが1枚2048〜4096px四方
// (展開すると17〜67MB/枚、駅から500m以内の38枚中23枚が4096px。2026-09-25実タイルで確認)。
// 以前のタッチ端末設定(キャッシュ700MB・テクスチャ原寸・同時ダウンロード25/同時展開5・区全体が対象)では、
// iPhone 16実機のアプリで読み込み54〜56%付近でWebViewの中身(WebContentプロセス)がメモリ超過で落ち、
// 作成画面に戻った。タッチ端末は「落ちないこと」を最優先に、読む範囲・テクスチャ解像度・同時処理数・キャッシュを絞る。
// このタイルセットは親タイルの幾何誤差が大きく(231〜316)、視野内はほぼ必ず最細のタイルまで細分化されるため、
// errorTargetを上げても読む量はほとんど減らない(範囲の限定とテクスチャ縮小が効く)。
const TOUCH_LIMITS = Object.freeze({
  errorTarget: 28, // 3d-tiles-rendererの許容スクリーン空間誤差(px)。小さいほど高精細・高負荷
  maxCameraDistanceM: 1100, // ズームアウトの上限
  areaRadiusM: 500, // 渋谷駅からこの半径にかかるタイルだけ読む(区全体を読みに行かない)
  leafTextureMaxPx: 1024, // 最も細かいタイルのテクスチャの長辺上限(4096→1024でメモリ1/16)
  parentTextureMaxPx: 512, // 読み込み中・遠景に出る粗いタイルのテクスチャの長辺上限
  cacheMaxBytes: 220 * MB, // タイルキャッシュの上限(テクスチャ・形状の推定バイト数)
  cacheMinBytes: 150 * MB, // 使っていないタイルをここまで捨てる
  downloadJobs: 4, // 同時ダウンロード数(既定25)
  parseJobs: 2, // 同時展開数(既定5)。展開中は縮小前の原寸テクスチャがメモリに乗るため絞る
  dracoWorkers: 2, // 形状の展開用Worker数(既定4)
});
// 意図的な簡略化: PCは従来どおり(範囲・テクスチャ・同時処理数はライブラリ既定)。
// PCでも重い場合は TOUCH_LIMITS と同じ項目を埋めるのが入口。
const DESKTOP_LIMITS = Object.freeze({
  errorTarget: 14,
  maxCameraDistanceM: 1800, // ズームアウトで区全体(143MB)を読みに行かないための上限
  areaRadiusM: null,
  leafTextureMaxPx: null,
  parentTextureMaxPx: null,
  // 既定のLRUキャッシュ上限(0.4GB)はテクスチャ付き建物だとすぐ埋まり(2026-09-25実測:
  // タイル111件・平均約4MB/件で早くも上限超過)、以後の候補タイルがすべて"refused"されて
  // 詳細タイルへ絶対に収束しなくなる(activeが1件のまま増えない不具合として現れた)ため広げる。
  cacheMaxBytes: 1600 * MB,
  cacheMinBytes: null,
  downloadJobs: null,
  parseJobs: null,
  dracoWorkers: null,
});
const LIMITS = IS_COARSE_POINTER ? TOUCH_LIMITS : DESKTOP_LIMITS;

function floorHeightM(floor) {
  const f = Number.isFinite(floor) ? Math.trunc(floor) : 1;
  if (f <= -1) return BASEMENT_PILLAR_HEIGHT_M;
  return (f === 0 ? 1 : f) * FLOOR_HEIGHT_M;
}

function setupGltfLoader(tiles) {
  const dracoLoader = new DRACOLoader();
  dracoLoader.setDecoderPath(DRACO_DECODER_PATH);
  dracoLoader.setDecoderConfig({ type: "wasm" });
  if (LIMITS.dracoWorkers) dracoLoader.setWorkerLimit(LIMITS.dracoWorkers);

  const gltfLoader = new GLTFLoader(tiles.manager);
  gltfLoader.setDRACOLoader(dracoLoader);
  gltfLoader.register(() => new GLTFCesiumRTCExtension());

  tiles.manager.addHandler(/\.(gltf|glb)$/, gltfLoader);
  tiles.manager.addHandler(/\.drc$/, dracoLoader);
  return { gltfLoader, dracoLoader };
}

// ---- 読む範囲の限定: tileset.json を取得した直後に、中心から半径radiusMにかからないタイルを木から外す ----
// (3d-tiles-rendererのプラグインのfetchData。ルートのtileset.jsonだけを横取りし、他のURLはnullを返して既定の取得に任せる)
function regionDistanceM(region, center) {
  const [west, south, east, north] = region;
  const lat = center.lat * DEG2RAD;
  const lng = center.lng * DEG2RAD;
  const nearestLat = Math.min(Math.max(lat, south), north);
  const nearestLng = Math.min(Math.max(lng, west), east);
  const dy = (nearestLat - lat) * EARTH_RADIUS_M;
  const dx = (nearestLng - lng) * EARTH_RADIUS_M * Math.cos(lat);
  return Math.hypot(dx, dy);
}

function pruneTileToRadius(tile, center, radiusM) {
  if (!Array.isArray(tile.children)) return;
  // regionで範囲が分からないタイル(このデータには無い)は残す
  tile.children = tile.children.filter((child) => {
    const region = child.boundingVolume && child.boundingVolume.region;
    return !region || regionDistanceM(region, center) <= radiusM;
  });
  for (const child of tile.children) pruneTileToRadius(child, center, radiusM);
}

function createAreaLimitPlugin(tilesetUrl, center, radiusM) {
  return {
    name: "MACHIMACHI_AREA_LIMIT",
    fetchData(url, options) {
      if (url !== tilesetUrl) return null;
      return fetch(url, options).then((res) => {
        if (!res.ok) throw new Error(`tileset.jsonの取得に失敗しました(HTTP ${res.status})`);
        return res.json();
      }).then((tileset) => {
        pruneTileToRadius(tileset.root, center, radiusM);
        return tileset;
      });
    },
  };
}

// ---- テクスチャの縮小: タイルの形状・テクスチャが展開された直後(GPUへ送る前)に長辺をmaxPxへ縮める ----
async function shrinkImage(image, maxPx) {
  const scale = maxPx / Math.max(image.width, image.height);
  const width = Math.max(1, Math.round(image.width * scale));
  const height = Math.max(1, Math.round(image.height * scale));
  if (typeof createImageBitmap === "function") {
    try {
      const bitmap = await createImageBitmap(image, {
        resizeWidth: width, resizeHeight: height, resizeQuality: "medium",
        premultiplyAlpha: "none", colorSpaceConversion: "none",
      });
      if (bitmap.width === width && bitmap.height === height) return bitmap;
      bitmap.close(); // 縮小指定を無視する環境。下のcanvasで縮める
    } catch (err) {
      console.warn("高画質3D: createImageBitmapで縮小できないためcanvasで縮小します", err);
    }
  }
  const canvas = document.createElement("canvas");
  canvas.width = width;
  canvas.height = height;
  const ctx = canvas.getContext("2d");
  if (!ctx) throw new Error("高画質3D: テクスチャ縮小用のcanvasが使えません");
  ctx.drawImage(image, 0, 0, width, height);
  return canvas;
}

function collectTextures(scene) {
  const textures = new Set();
  scene.traverse((obj) => {
    const materials = Array.isArray(obj.material) ? obj.material : obj.material ? [obj.material] : [];
    for (const material of materials) {
      for (const key of Object.keys(material)) {
        const value = material[key];
        if (value && value.isTexture) textures.add(value);
      }
    }
  });
  return textures;
}

function createTextureLimitPlugin(leafMaxPx, parentMaxPx) {
  return {
    name: "MACHIMACHI_TEXTURE_LIMIT",
    async processTileModel(scene, tile) {
      const isLeaf = !tile.children || tile.children.length === 0;
      const maxPx = isLeaf ? leafMaxPx : parentMaxPx;
      for (const texture of collectTextures(scene)) {
        const image = texture.image;
        if (!image || Math.max(image.width || 0, image.height || 0) <= maxPx) continue;
        // 縮小に失敗したら例外をそのまま投げ、そのタイルは読み込み失敗にする(原寸のまま載せてメモリ超過で落ちるより良い)
        texture.image = await shrinkImage(image, maxPx);
        texture.needsUpdate = true;
        if (typeof ImageBitmap !== "undefined" && image instanceof ImageBitmap) image.close();
      }
    },
  };
}

function buildProgressOverlay(container) {
  const overlay = document.createElement("div");
  overlay.style.cssText = "position:absolute;inset:0;display:flex;flex-direction:column;align-items:center;justify-content:center;gap:10px;background:rgba(20,24,28,0.82);color:#fff;font-family:-apple-system,'Hiragino Sans',sans-serif;z-index:5;pointer-events:none;transition:opacity .4s ease;";
  overlay.innerHTML = `
    <div style="font-size:14px;font-weight:700;">高画質モデルを読み込み中…</div>
    <div style="width:220px;height:6px;border-radius:3px;background:rgba(255,255,255,0.25);overflow:hidden;">
      <div data-role="bar" style="width:0%;height:100%;background:${ACCENT_COLOR};transition:width .2s ease;"></div>
    </div>
    <div data-role="pct" style="font-size:12px;opacity:0.85;">0%</div>
    <div style="font-size:11px;opacity:0.75;max-width:240px;text-align:center;line-height:1.5;">テクスチャ付きの3D建物データ(数十MB)を読み込みます。モバイル回線では時間がかかることがあるため、Wi-Fi推奨です。</div>
  `;
  container.appendChild(overlay);
  return overlay;
}

function buildPinLabelEl(text, color) {
  const el = document.createElement("div");
  el.style.cssText = `position:absolute;left:0;top:0;transform:translate(-50%,-100%);display:flex;flex-direction:column;align-items:center;pointer-events:none;font-family:-apple-system,'Hiragino Sans',sans-serif;white-space:nowrap;`;
  const card = document.createElement("div");
  card.style.cssText = `background:${color};color:#fff;padding:4px 9px;border-radius:7px;font-size:12px;font-weight:700;box-shadow:0 1px 5px rgba(0,0,0,.5),0 0 10px 2px ${color}99;`;
  card.textContent = text;
  el.appendChild(card);
  return el;
}

/**
 * Mount the PLATEAU LOD2 textured-tiles high-quality Shibuya view into `container`
 * (must be a positioned element that already has a size; a <canvas> and label layer
 * are created inside it).
 * @returns {Promise<{setMe:Function, setPartner:Function, destroy:Function}>}
 */
export async function mountShibuyaHQ(container, opts = {}) {
  if (!container) throw new Error("mountShibuyaHQ: container element not found");
  // container.style.position(インラインstyleのみを見る)は、呼び出し元がstylesheetで
  // position:absolute/fixedを指定しているケース(html.jsの#hq-mount等)では常に空文字列になり、
  // ここで安易に上書きすると元のposition指定を破壊して高さ0にたたむバグになる
  // (2026-09-25実機デバッグで発見: canvas.height=1pxになり画面が真っ暗になっていた)。
  // 必ずgetComputedStyleで実際の指定を見て、"static"(=何も指定されていない)の時だけ補う。
  if (getComputedStyle(container).position === "static") container.style.position = "relative";

  const canvas = document.createElement("canvas");
  canvas.style.cssText = "position:absolute;inset:0;width:100%;height:100%;display:block;";
  container.appendChild(canvas);

  const labelLayer = document.createElement("div");
  labelLayer.style.cssText = "position:absolute;inset:0;overflow:hidden;pointer-events:none;";
  container.appendChild(labelLayer);

  const progressOverlay = buildProgressOverlay(container);
  container.dataset.hqStatus = "loading";

  const renderer = new THREE.WebGLRenderer({ canvas, antialias: true, logarithmicDepthBuffer: true });
  renderer.setPixelRatio(Math.min(window.devicePixelRatio || 1, 2));
  renderer.outputColorSpace = THREE.SRGBColorSpace;

  const scene = new THREE.Scene();
  scene.background = new THREE.Color("#bfe1f5");
  scene.fog = new THREE.Fog("#dfeaf0", 900, 4500);

  const camera = new THREE.PerspectiveCamera(60, 1, 1, 20000);

  scene.add(new THREE.AmbientLight(0xffffff, 1.15));
  const sun = new THREE.DirectionalLight(0xffffff, 2.1);
  sun.position.set(0.4, 1, 0.6);
  scene.add(sun);

  // 地面代わりの円盤(実際のPLATEAU地形/地理院タイルのドレープは今回未実装。意図的な簡略化。
  // ファイル冒頭コメント参照)。ステーション地点のENUフレームに合わせて向きを合わせる。
  const ellipsoid = WGS84_ELLIPSOID;
  const stationMatrix = new THREE.Matrix4();
  ellipsoid.getEastNorthUpFrame(STATION.lat * DEG2RAD, STATION.lng * DEG2RAD, GROUND_ELLIPSOIDAL_HEIGHT_M, stationMatrix);
  const stationPos = new THREE.Vector3().setFromMatrixPosition(stationMatrix);
  const stationUp = new THREE.Vector3(0, 0, 1).transformDirection(stationMatrix);

  const ground = new THREE.Mesh(
    new THREE.CircleGeometry(1600, 48),
    new THREE.MeshStandardMaterial({ color: "#8a9198", roughness: 1 }),
  );
  ground.quaternion.setFromUnitVectors(new THREE.Vector3(0, 0, 1), stationUp);
  ground.position.copy(stationPos);
  ground.position.addScaledVector(stationUp, -1); // 建物と重ならないよう僅かに沈める
  scene.add(ground);

  const tiles = new TilesRenderer(TILESET_URL);
  tiles.errorTarget = LIMITS.errorTarget;
  // 注意: 3d-tiles-renderer 0.5.3 のLRUキャッシュ・ダウンロード/展開キューはモジュール共有の1個ずつ
  // (全TilesRendererで同じもの)。このアプリで同時に作るのは1個だけなので、ここで上書きしてよい。
  // 最小値を先に下げてから最大値を設定する(最小>最大の瞬間を作らない)。
  if (LIMITS.cacheMinBytes) tiles.lruCache.minBytesSize = LIMITS.cacheMinBytes;
  tiles.lruCache.maxBytesSize = LIMITS.cacheMaxBytes;
  if (LIMITS.downloadJobs) tiles.downloadQueue.maxJobsPerOrigin = LIMITS.downloadJobs;
  if (LIMITS.parseJobs) tiles.parseQueue.maxJobs = LIMITS.parseJobs;
  if (LIMITS.areaRadiusM) tiles.registerPlugin(createAreaLimitPlugin(TILESET_URL, STATION, LIMITS.areaRadiusM));
  if (LIMITS.leafTextureMaxPx) {
    tiles.registerPlugin(createTextureLimitPlugin(LIMITS.leafTextureMaxPx, LIMITS.parentTextureMaxPx || LIMITS.leafTextureMaxPx));
  }
  const { dracoLoader } = setupGltfLoader(tiles);
  scene.add(tiles.group);

  const controls = new GlobeControls(scene, camera, renderer.domElement);
  controls.setEllipsoid(tiles.ellipsoid, tiles.group);
  controls.enableDamping = true;
  controls.dampingFactor = 0.12;
  controls.minDistance = 40;
  controls.maxDistance = LIMITS.maxCameraDistanceM;
  controls.enabled = false; // introRotation()の間はこちらでカメラを動かさない(stopIntroで有効化)

  function positionCameraAt(azimuthRad, distanceM, elevationDeg) {
    const elevRad = elevationDeg * DEG2RAD;
    const east = distanceM * Math.cos(elevRad) * Math.sin(azimuthRad);
    const north = distanceM * Math.cos(elevRad) * Math.cos(azimuthRad);
    const up = distanceM * Math.sin(elevRad);
    const eastAxis = new THREE.Vector3(1, 0, 0).transformDirection(stationMatrix);
    const northAxis = new THREE.Vector3(0, 1, 0).transformDirection(stationMatrix);
    camera.position.copy(stationPos)
      .addScaledVector(eastAxis, east)
      .addScaledVector(northAxis, north)
      .addScaledVector(stationUp, up);
    camera.up.copy(stationUp);
    camera.lookAt(stationPos);
  }

  let introActive = true;
  let introAzimuthRad = 0;
  function stopIntro() {
    if (!introActive) return;
    introActive = false;
    controls.enabled = true;
  }
  for (const evtName of ["pointerdown", "wheel", "touchstart"]) {
    canvas.addEventListener(evtName, stopIntro, { once: true, passive: true });
  }
  controls.addEventListener("start", stopIntro);
  positionCameraAt(introAzimuthRad, INTRO_DISTANCE_M, INTRO_ELEVATION_DEG);

  function resize() {
    const w = container.clientWidth || 1;
    const h = container.clientHeight || 1;
    renderer.setSize(w, h, false);
    camera.aspect = w / h;
    camera.updateProjectionMatrix();
  }
  resize();
  const resizeObserver = new ResizeObserver(resize);
  resizeObserver.observe(container);

  // ---- ピン(自分・相手): ECEF座標に立てる発光ピラー + HTMLラベル(画面投影で追従) ----
  const pins = {};
  function pinWorldPos(lat, lng, floor) {
    const m = new THREE.Matrix4();
    ellipsoid.getEastNorthUpFrame(lat * DEG2RAD, lng * DEG2RAD, GROUND_ELLIPSOIDAL_HEIGHT_M, m);
    const ground2 = new THREE.Vector3().setFromMatrixPosition(m);
    const up2 = new THREE.Vector3(0, 0, 1).transformDirection(m);
    const heightM = floorHeightM(floor);
    const top = ground2.clone().addScaledVector(up2, heightM);
    return { ground: ground2, top, up: up2 };
  }
  function upsertPin(role, lat, lng, floor, displayName) {
    // Part A(shibuya3d.mjs)と異なり、ここでは実データ到着(位置更新)だけではintroを止めない
    // (「操作したら止める」の「操作」はポインタ/ホイール入力だけを指す。全画面の「見せる」ビューなので、
    // 位置が届いた程度で自動回転をやめるとGlobeControlsに制御が移り、まだユーザーが一度も
    // 触っていないのに"start"イベントなしでカメラが不安定になる。2026-09-25実機デバッグで
    // 発覚: 位置到着即introOff+controls.enabled=trueにすると、直後のcontrols.update()が
    // 実際の建物ジオメトリに対してカメラ姿勢を再調整し、意図しない角度に飛ぶことがあった)。
    const color = role === "me" ? ME_COLOR : PARTNER_COLOR;
    const { ground: groundPos, top, up } = pinWorldPos(lat, lng, floor);
    const heightM = Math.max(top.distanceTo(groundPos), 0.5);

    if (pins[role]) {
      scene.remove(pins[role].mesh);
      pins[role].mesh.geometry.dispose();
      pins[role].mesh.material.dispose();
      pins[role].labelEl.remove();
    }
    const mesh = new THREE.Mesh(
      new THREE.CylinderGeometry(2.6, 2.6, heightM, 14),
      new THREE.MeshStandardMaterial({ color, emissive: color, emissiveIntensity: 1.3, roughness: 0.4 }),
    );
    mesh.quaternion.setFromUnitVectors(new THREE.Vector3(0, 1, 0), up);
    mesh.position.copy(groundPos).addScaledVector(up, heightM / 2);
    scene.add(mesh);

    const label = floor <= -1 ? `B${Math.abs(Math.trunc(floor))}` : `${Math.trunc(floor) || 1}F`;
    const labelEl = buildPinLabelEl(`${displayName} ・ ${label}`, color);
    labelLayer.appendChild(labelEl);

    pins[role] = { mesh, top, labelEl };
    refreshConnectorLine();
  }

  let connector = null;
  function refreshConnectorLine() {
    if (connector) {
      scene.remove(connector);
      connector.geometry.dispose();
      connector.material.dispose();
      connector = null;
    }
    if (!pins.me || !pins.partner) return;
    const geom = new THREE.BufferGeometry().setFromPoints([pins.me.top, pins.partner.top]);
    const mat = new THREE.LineDashedMaterial({ color: ACCENT_COLOR, dashSize: 8, gapSize: 6, linewidth: 1 });
    connector = new THREE.Line(geom, mat);
    connector.computeLineDistances();
    scene.add(connector);
  }

  const projected = new THREE.Vector3();
  function updateLabels() {
    for (const role of Object.keys(pins)) {
      const p = pins[role];
      projected.copy(p.top).project(camera);
      const behindCamera = projected.z > 1;
      const x = (projected.x * 0.5 + 0.5) * container.clientWidth;
      const y = (-projected.y * 0.5 + 0.5) * container.clientHeight;
      p.labelEl.style.display = behindCamera ? "none" : "block";
      p.labelEl.style.transform = `translate(${x}px, ${y}px) translate(-50%, -100%)`;
    }
  }

  // ---- 進捗表示: tiles.statsを毎フレーム見て、「ダウンロード中/キュー中/パース中」が
  // 0件の状態がPROGRESS_IDLE_MSだけ続いたら「読み込み完了」とみなして隠す。 ----
  // 意図的な簡略化(2026-09-25実機デバッグで判明): 'tiles-load-end'イベント+固定500ms待ちの
  // 素朴な実装は誤検知した(このタイルセットは区全体をカバーする深い階層で、粗いタイル1件が
  // 届いた直後に一瞬キューが空になる瞬間があり、そこで「完了」と誤判定して駅周辺の詳細タイルが
  // 届く前にオーバーレイを消してしまっていた)。tiles.statsの実カウントを直接見る方が確実。
  const PROGRESS_IDLE_MS = 700;
  const PROGRESS_MAX_WAIT_MS = 45000; // 収束しない場合の安全上限(スマホ回線・広い範囲を見た場合等)
  const mountedAtMs = performance.now();
  let idleSinceMs = null;
  let everLoaded = false;
  function hideProgressOverlay() {
    if (everLoaded) return;
    everLoaded = true;
    progressOverlay.style.opacity = "0";
    container.dataset.hqStatus = "ready";
    setTimeout(() => progressOverlay.remove(), 450);
  }
  function updateProgressUI() {
    if (everLoaded) return;
    const s = tiles.stats || {};
    const pending = (s.downloading || 0) + (s.queued || 0) + (s.parsing || 0);
    const loaded = s.loaded || 0;
    const total = pending + loaded;
    const pct = total > 0 ? Math.round((loaded / total) * 100) : 0;
    const bar = progressOverlay.querySelector('[data-role="bar"]');
    const pctEl = progressOverlay.querySelector('[data-role="pct"]');
    if (bar) bar.style.width = pct + "%";
    if (pctEl) pctEl.textContent = pct + "%";

    const now = performance.now();
    if (pending === 0 && loaded > 0) {
      if (idleSinceMs == null) idleSinceMs = now;
    } else {
      idleSinceMs = null;
    }
    const idleLongEnough = idleSinceMs != null && now - idleSinceMs >= PROGRESS_IDLE_MS;
    if (idleLongEnough || now - mountedAtMs >= PROGRESS_MAX_WAIT_MS) hideProgressOverlay();
  }

  let destroyed = false;
  const clock = new THREE.Clock();
  function animate() {
    if (destroyed) return;
    requestAnimationFrame(animate);
    const dt = Math.min(clock.getDelta(), 0.1);
    if (introActive) {
      introAzimuthRad += INTRO_RAD_PER_SEC * dt;
      positionCameraAt(introAzimuthRad, INTRO_DISTANCE_M, INTRO_ELEVATION_DEG);
    } else {
      controls.update(dt);
    }
    camera.updateMatrixWorld();
    tiles.setCamera(camera);
    tiles.setResolutionFromRenderer(camera, renderer);
    tiles.update();
    updateProgressUI();
    updateLabels();
    renderer.render(scene, camera);
  }
  requestAnimationFrame(animate);

  opts.onReady?.();

  // 閉じるときに呼ぶ。描画ループを止め、タイル(テクスチャ・形状)・形状展開用Worker・WebGLの
  // 描画領域をすべて手放す。自分が作った要素だけを外す(閉じた直後に開き直した新しい表示を消さないため)。
  function destroy() {
    if (destroyed) return;
    destroyed = true;
    resizeObserver.disconnect();
    controls.dispose();
    tiles.dispose(); // 読み込んだタイルのテクスチャ(ImageBitmapも)・形状・マテリアルを解放
    dracoLoader.dispose(); // 形状の展開用Workerを終了
    for (const role of Object.keys(pins)) {
      pins[role].mesh.geometry.dispose();
      pins[role].mesh.material.dispose();
    }
    if (connector) {
      connector.geometry.dispose();
      connector.material.dispose();
    }
    ground.geometry.dispose();
    ground.material.dispose();
    renderer.dispose();
    renderer.forceContextLoss(); // WebGLの描画領域をすぐ返す(次に開くと新しく作る)
    canvas.remove();
    labelLayer.remove();
    progressOverlay.remove();
    delete container.dataset.hqStatus;
  }

  return {
    setMe: (lat, lng, floor) => {
      if (!destroyed) upsertPin("me", lat, lng, floor, "自分");
    },
    setPartner: (lat, lng, floor, name) => {
      if (!destroyed) upsertPin("partner", lat, lng, floor, name || "相手");
    },
    destroy,
  };
}
