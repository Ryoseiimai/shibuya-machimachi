// Shibuya 3D map + nearby-shops component.
//
// Single ESM file. Only external dependency is MapLibre GL JS, self-hosted from
// ../../vendor/maplibre-gl/ (vendored via npm, see worker/package.json devDependencies
// and public/vendor/maplibre-gl/VERSION.txt) so this file can be dropped into any
// page/app without a bundler and without depending on a third-party CDN at runtime
// (2026-09-24 security review: CDN script/style sources were an unpinned supply-chain
// dependency and a CSP script-src weak point). Data files (building footprints, shop
// POIs) live next to this file under ../data/ and are resolved relative to this
// module's own URL, so the component works regardless of which page imports it.
//
// Public API:
//   mountShibuya3D(el, { onReady }) -> Promise<{ setMe, setPartner, focusBoth, destroy }>
//   nearestShops(lat, lng, n) -> Promise<Array<{ name, distanceM, level }>>
//
// NOTE (intentional simplification): building footprints use the flattest ring
// with the smallest average Z from the PLATEAU LOD1 solid as a 2D footprint;
// extrusion height comes from the measuredHeight attribute, not the solid's own
// Z extent (PLATEAU LOD1 solids encode absolute elevation incl. terrain, which
// this flat, non-terrain map does not model). See scripts/fetch_buildings.py.
//
// This copy lives inside shibuya-machimachi's worker/public/assets/js/ (served as a
// static asset) and has small visual tuning diffs from the standalone component repo
// (shibuya-machimachi-3d), made during integration after reviewing screenshots where
// pins looked buried in nearby buildings: default/focus pitch 60->50 degrees, building
// fill-extrusion-opacity 0.88->0.6, and an explicit z-index on marker labels. See
// DEFAULT_PITCH_DEG / BUILDING_OPACITY / LABEL_Z_INDEX below. Not back-ported upstream.
//
// 2026-09-25 見た目最高品質化: 建物の白〜淡いグレーのグラデ+光源+空、主要ランドマークの
// ラベル/強調、ピンの発光演出、2人を結ぶ点線、初回のゆっくりした回り込みカメラを追加。
// 詳細は各定数のコメントを参照(「高画質で見る」ボタンから開く別ビュー本体はshibuya3d-hq.mjs、
// PLATEAU LOD2テクスチャ付き3D Tiles担当で、このファイルは軽量な既定ビューのみを扱う)。

import {
  Map as MapLibreMap,
  Marker,
  NavigationControl,
} from "../../vendor/maplibre-gl/maplibre-gl.mjs";

const MODULE_URL = import.meta.url;
const MAPLIBRE_CSS_URL = new URL("../../vendor/maplibre-gl/maplibre-gl.css", MODULE_URL).href;
const GSI_PALE_TILES_URL = "https://cyberjapandata.gsi.go.jp/xyz/pale/{z}/{x}/{y}.png";
const DEFAULT_BUILDINGS_URL = new URL("../data/buildings_shibuya_1500m.geojson", MODULE_URL).href;
const DEFAULT_POIS_URL = new URL("../data/pois_shibuya_1500m.geojson", MODULE_URL).href;

export const STATION = { lat: 35.659, lng: 139.7005 }; // Shibuya station (Hachiko exit approx.)
const COVERAGE_RADIUS_M = 1500;
const PAN_MARGIN_M = 1700; // slightly beyond the data radius so edge pins/buildings aren't clipped by maxBounds

const FLOOR_HEIGHT_M = 3.5; // approx. meters per above-ground floor, per task spec
const BASEMENT_PILLAR_HEIGHT_M = 5; // fixed marker height for basement floors (see floorInfo)
const PILLAR_HALF_SIZE_M = 4; // pillar footprint is an 8m x 8m square

// 組み込み時の見え方調整(渋谷マチマチ本体への統合時のスクショで、初期カメラが近すぎて
// ピンが建物に埋もれて見えた問題への対処): ピッチを60→50度に、建物を半透明にして
// ピン・ラベルが建物の陰に隠れにくくする。マジックナンバー化して1箇所で管理する。
const DEFAULT_PITCH_DEG = 50;
const BUILDING_OPACITY = 0.6;
const LABEL_Z_INDEX = "50"; // ラベルを常に最前面にする(念のため明示。DOM Markerは既定でcanvasより上)

// このアプリ唯一のブランドアクセント色(worker/src/html.jsの--brand-orangeと同じ値)。
// 3D内で新しい色を増やさず、強調したい箇所は必ずこの色だけを使う(2026-09-25 見た目最高品質化の方針)。
const ACCENT_COLOR = "#c8431f";

// 主要ランドマークのうち、PLATEAU/OSM由来のbuildings_shibuya_1500m.geojsonのname属性と
// 実際に一致する建物だけ、ポリゴンの色そのものをACCENT_COLORで強調する(=データに基づく強調)。
const LANDMARK_ACCENT_NAMES = ["渋谷ヒカリエ", "渋谷ストリーム"];

// 主要ランドマークのラベル表示専用データ(強調用ではなくラベル配置用)。上のLANDMARK_ACCENT_NAMESの
// 2件はbuildings geojson側に実座標があるためそちらの重心を使い、残り4件(スクランブルスクエア/
// SHIBUYA109/フクラス/ハチ公像)はPLATEAU/OSMデータにname属性がないため、公知の概算座標・高さを
// ここに直接持たせる(意図的な簡略化: 建物ポリゴンとの自動突合はしない。ラベルの位置精度は
// 数十m程度の誤差を許容する「目印」用途。本格的に合わせるならOSMのlanduse/POIデータの入口を
// scripts/fetch_buildings.py側に増やすのが次の一手)。
const LANDMARKS = [
  { name: "渋谷スクランブルスクエア", lat: 35.6585, lng: 139.7016, heightM: 230 },
  { name: "渋谷ヒカリエ", lat: 35.659213, lng: 139.703826, heightM: 173.6 },
  { name: "SHIBUYA109", lat: 35.659, lng: 139.6983, heightM: 45 },
  { name: "渋谷ストリーム", lat: 35.657282, lng: 139.703035, heightM: 171.3 },
  { name: "渋谷フクラス", lat: 35.6595, lng: 139.698, heightM: 130 },
  { name: "ハチ公像", lat: 35.659, lng: 139.7004, heightM: 2 },
];

// 初回マウント時、ピン(=自分・相手の位置)がまだ無い間だけ再生する、ゆっくり回り込む
// 演出カメラ。ユーザーが地図を操作するか、実データ(setMe/setPartner)が届いた時点で即停止する
// (「操作したら止める」という仕様どおり。回り続けると距離を読みたいユーザーの邪魔になるため)。
const INTRO_PITCH_DEG = 60;
const INTRO_BEARING_DEG_PER_SEC = 3; // 360度を約2分かけて一周する速さ

// focusBothのfitBoundsパディングは、コンテナの実サイズに対する比率で決める(固定px値だと、
// このコンポーネントを小さい枠(渋谷マチマチ本体では.map3d=高さ280pxの縦横比が大きく違う枠)に
// 埋め込んだときに天地/左右のパディング合計がコンテナのサイズを超え、MapLibreのfitBoundsが
// 計算不能になって"Invalid LngLat object: (NaN, ...)"を投げ、後続のsetPartner以降の処理
// (近くのお店の取得含む)が丸ごと止まる不具合があったための対処。最小/最大でクランプし、
// 極端に小さい/大きいコンテナでも安全な範囲に収める。
const FOCUS_PADDING_RATIO = 0.12; // コンテナの幅・高さそれぞれの12%を片側パディングにする
const FOCUS_PADDING_MIN_PX = 12;
const FOCUS_PADDING_MAX_PX = 40;
// focusBoth時、ラベル(buildLabelElのカード)が横方向にfitBoundsの外へはみ出さないよう、
// ラベル文字幅から見積もった半分の幅もパディング候補に加える(見た目のチューニング)。
// コンテナ幅の半分を超えないよう最終的に安全クランプする(下のsafeSidePadding参照。
// 超えるとMapLibreのfitBoundsが"Invalid LngLat"を投げて後続処理が丸ごと止まる不具合の再発防止)。
const FOCUS_LABEL_PADDING_MAX_PX = 90;
const LABEL_FONT = "700 12px -apple-system, 'Hiragino Sans', sans-serif"; // buildLabelElのcardと同じ
const LABEL_CARD_HORIZONTAL_PADDING_PX = 9 * 2; // buildLabelElの `padding: 4px 9px` の左右分

// 近接時、2つのラベルが画面上で重なりそうならどちらかを縦にずらして両方読めるようにする。
const LABEL_STACK_DISTANCE_PX = 56; // これより画面上の距離が近ければ「重なりそう」とみなす
const LABEL_STACK_OFFSET_PX = 34; // ずらす量(ラベルの高さ+隙間の概算)

const ME_COLOR = "#1e88e5";
const ME_BASEMENT_COLOR = "#37474f";
const PARTNER_COLOR = "#fb8c00";
const PARTNER_BASEMENT_COLOR = "#6a1b9a";

const EARTH_CIRCUMFERENCE_CONST = 156543.03392; // meters/pixel at zoom 0, equator (Web Mercator)

// ---------- small geo helpers ----------

function haversineMeters(lat1, lon1, lat2, lon2) {
  const R = 6371000;
  const p1 = (lat1 * Math.PI) / 180;
  const p2 = (lat2 * Math.PI) / 180;
  const dphi = ((lat2 - lat1) * Math.PI) / 180;
  const dlmb = ((lon2 - lon1) * Math.PI) / 180;
  const a = Math.sin(dphi / 2) ** 2 + Math.cos(p1) * Math.cos(p2) * Math.sin(dlmb / 2) ** 2;
  return 2 * R * Math.asin(Math.sqrt(a));
}

function metersToDegreesAt(lat) {
  const dLat = 1 / 111320;
  const dLng = 1 / (111320 * Math.cos((lat * Math.PI) / 180));
  return { dLat, dLng };
}

function squarePolygon(lat, lng, halfSizeM) {
  const { dLat, dLng } = metersToDegreesAt(lat);
  const corners = [
    [-1, -1],
    [1, -1],
    [1, 1],
    [-1, 1],
    [-1, -1],
  ];
  return corners.map(([sx, sy]) => [
    lng + sx * halfSizeM * dLng,
    lat + sy * halfSizeM * dLat,
  ]);
}

function computeMaxBounds() {
  const { dLat, dLng } = metersToDegreesAt(STATION.lat);
  const latSpan = PAN_MARGIN_M * dLat;
  const lngSpan = PAN_MARGIN_M * dLng;
  return [
    [STATION.lng - lngSpan, STATION.lat - latSpan],
    [STATION.lng + lngSpan, STATION.lat + latSpan],
  ];
}

function metersPerPixelAt(lat, zoom) {
  return (EARTH_CIRCUMFERENCE_CONST * Math.cos((lat * Math.PI) / 180)) / Math.pow(2, zoom);
}

function clampPx(px, max = FOCUS_PADDING_MAX_PX) {
  return Math.min(max, Math.max(FOCUS_PADDING_MIN_PX, px));
}

// 左右いずれかのパディングが、コンテナ幅の半分を超えないように最終クランプする
// (超えるとfitBoundsのpadding.left+padding.right >= コンテナ幅になり"Invalid LngLat"で
// 落ちる。焦点距離ゼロにならないよう安全マージンも引く)。
function safeSidePadding(px, containerSizePx) {
  const maxAllowed = Math.max(FOCUS_PADDING_MIN_PX, containerSizePx / 2 - FOCUS_PADDING_MIN_PX);
  return Math.min(Math.max(px, FOCUS_PADDING_MIN_PX), maxAllowed);
}

let labelMeasureCtx = null;
function measureLabelHalfWidthPx(text) {
  if (!text) return 0;
  if (!labelMeasureCtx) labelMeasureCtx = document.createElement("canvas").getContext("2d");
  labelMeasureCtx.font = LABEL_FONT;
  const textWidth = labelMeasureCtx.measureText(text).width;
  return (textWidth + LABEL_CARD_HORIZONTAL_PADDING_PX) / 2;
}

// floor (integer, e.g. -5..10, matching "B5"-"10F") -> pillar height + label.
function floorInfo(floor) {
  const f = Number.isFinite(floor) ? Math.trunc(floor) : 1;
  if (f <= -1) {
    return { heightM: BASEMENT_PILLAR_HEIGHT_M, label: `B${Math.abs(f)}`, basement: true };
  }
  // floor 0 has no standard meaning in JP building numbering (1F follows directly
  // from ground); treat it as 1F rather than a 0m-tall pillar.
  const floorNum = f === 0 ? 1 : f;
  return { heightM: floorNum * FLOOR_HEIGHT_M, label: `${floorNum}F`, basement: false };
}

// #rrggbb -> "rgba(r,g,b,a)"。ピンのグロー(box-shadow/drop-shadow)に使う。
// ACCENT_COLOR/ME_COLOR/PARTNER_COLOR等、常に#rrggbb形式の定数にしか適用しないため
// 3桁hexや色名には対応しない(意図的な簡略化。ユーザー入力を扱わないので十分)。
function hexToRgba(hex, alpha) {
  const n = parseInt(hex.slice(1), 16);
  const r = (n >> 16) & 255, g = (n >> 8) & 255, b = n & 255;
  return `rgba(${r},${g},${b},${alpha})`;
}

// ---------- CSS / style setup ----------

function ensureMaplibreCss() {
  if (document.querySelector("link[data-shibuya3d-maplibre-css]")) return;
  const link = document.createElement("link");
  link.rel = "stylesheet";
  link.href = MAPLIBRE_CSS_URL;
  link.setAttribute("data-shibuya3d-maplibre-css", "1");
  document.head.appendChild(link);
}

// ピン先端の発光アニメーション用の@keyframesを1回だけ注入する(buildLabelElのglow要素が使う)。
let pulseStyleInjected = false;
function ensurePulseKeyframes() {
  if (pulseStyleInjected) return;
  pulseStyleInjected = true;
  const style = document.createElement("style");
  style.setAttribute("data-shibuya3d-pulse", "1");
  style.textContent = `@keyframes shibuya3d-pin-pulse{0%,100%{opacity:.6;transform:scale(1);}50%{opacity:1;transform:scale(1.3);}}`;
  document.head.appendChild(style);
}

function buildStyle() {
  return {
    version: 8,
    // 上品な白灰色の建物に立体感を出すための光源(側面の陰影)と、地平線側を淡く霞ませる空。
    // どちらもMapLibre GL JSの標準style spec機能(light/sky)で、追加の外部リソースは不要。
    light: { anchor: "viewport", color: "#ffffff", intensity: 0.38, position: [1.4, 210, 42] },
    sky: {
      "sky-color": "#bfe1f5",
      "horizon-color": "#eef3f1",
      "fog-color": "#eef3f1",
      "sky-horizon-blend": 0.5,
      "horizon-fog-blend": 0.65,
    },
    sources: {
      "gsi-pale": {
        type: "raster",
        tiles: [GSI_PALE_TILES_URL],
        tileSize: 256,
        maxzoom: 18,
        attribution: "地理院タイル",
      },
      buildings: {
        type: "geojson",
        data: DEFAULT_BUILDINGS_URL,
      },
      pins: {
        type: "geojson",
        data: { type: "FeatureCollection", features: [] },
      },
      "pins-glow": {
        type: "geojson",
        data: { type: "FeatureCollection", features: [] },
      },
      "pins-line": {
        type: "geojson",
        data: { type: "FeatureCollection", features: [] },
      },
    },
    layers: [
      { id: "bg", type: "background", paint: { "background-color": "#eef1f3" } },
      { id: "gsi-pale-layer", type: "raster", source: "gsi-pale" },
      {
        id: "buildings-3d",
        type: "fill-extrusion",
        source: "buildings",
        paint: {
          // 白〜淡いグレーの上品なグラデ(建物の高さ基準)。ランドマーク2件(LANDMARK_ACCENT_NAMES、
          // buildings geojsonのname属性と一致するもののみ)だけ、このアプリ唯一のアクセント色
          // (ACCENT_COLOR)で塗って強調する。新しい色は増やさない。
          "fill-extrusion-color": [
            "case",
            ["in", ["get", "name"], ["literal", LANDMARK_ACCENT_NAMES]],
            ACCENT_COLOR,
            [
              "interpolate", ["linear"], ["get", "height"],
              0, "#f7f8fa",
              20, "#eef0f3",
              60, "#dee2e6",
              120, "#c7cdd3",
              220, "#a6aeb7",
            ],
          ],
          "fill-extrusion-height": ["get", "height"],
          "fill-extrusion-base": 0,
          "fill-extrusion-opacity": BUILDING_OPACITY,
          "fill-extrusion-vertical-gradient": true,
        },
      },
      // ピンの足元の発光ハロー(外側=柔らかくぼかした大きい光暈、内側=芯の強い光)。
      // fill-extrusionの「光る柱」を、地面に落ちる光だまりで補強する(pins-3dより先に描く)。
      {
        id: "pins-glow-outer",
        type: "circle",
        source: "pins-glow",
        paint: {
          "circle-color": ["get", "color"],
          "circle-radius": ["interpolate", ["linear"], ["zoom"], 14, 12, 19, 48],
          "circle-blur": 1,
          "circle-opacity": 0.32,
        },
      },
      {
        id: "pins-glow-inner",
        type: "circle",
        source: "pins-glow",
        paint: {
          "circle-color": ["get", "color"],
          "circle-radius": ["interpolate", ["linear"], ["zoom"], 14, 4, 19, 16],
          "circle-blur": 0.5,
          "circle-opacity": 0.55,
        },
      },
      // 2人のピンの間を結ぶ点線(地表面。アクセント色のみ使用)。
      {
        id: "pins-line",
        type: "line",
        source: "pins-line",
        layout: { "line-cap": "round", "line-join": "round" },
        paint: {
          "line-color": ACCENT_COLOR,
          "line-width": 2.4,
          "line-dasharray": [1.4, 1.6],
          "line-opacity": 0.85,
        },
      },
      {
        id: "pins-3d",
        type: "fill-extrusion",
        source: "pins",
        paint: {
          "fill-extrusion-color": ["get", "color"],
          "fill-extrusion-height": ["get", "heightM"],
          "fill-extrusion-base": 0,
          "fill-extrusion-opacity": 0.96,
          "fill-extrusion-vertical-gradient": true,
        },
      },
    ],
  };
}

// ---------- marker label DOM ----------

function buildLabelEl(text, color) {
  const el = document.createElement("div");
  // shibuya3d-pin: 自分/相手のピンだけに付ける印(MapLibreのMarkerは渡した要素にmaplibregl-marker
  // クラスを足すだけなので、ランドマークラベル(shibuya3d-landmark、下のbuildLandmarkLabelEl)と
  // 見分けが付くようにする。e2e/tests/flow.spec.jsがこのクラスでピン数(=2)を数えている。
  el.className = "shibuya3d-pin";
  el.style.cssText = `display:flex;flex-direction:column;align-items:center;pointer-events:none;font-family:-apple-system,'Hiragino Sans',sans-serif;z-index:${LABEL_Z_INDEX};`;

  const card = document.createElement("div");
  // 通常の影に加えて、ピンの色でうっすら光らせる(box-shadowを2重に。新しい色は増やさずcolor自体を使う)。
  card.style.cssText = `background:${color};color:#fff;padding:4px 9px;border-radius:7px;font-size:12px;font-weight:700;white-space:nowrap;box-shadow:0 1px 5px rgba(0,0,0,.45), 0 0 10px 1px ${hexToRgba(color, 0.55)};`;
  card.textContent = text;

  const tail = document.createElement("div");
  // ピンの先端(=柱の頂点、updateMarkerOffsetsでの持ち上げ位置)にdrop-shadowで光暈を足し、
  // 「光る柱」の光源に見せる。filterはレイアウトサイズに影響しないため、anchor:"bottom"の
  // 基準位置(このtailの下端)はズレない。
  tail.style.cssText = `width:0;height:0;border-left:5px solid transparent;border-right:5px solid transparent;border-top:6px solid ${color};margin-top:-1px;filter:drop-shadow(0 0 5px ${color}) drop-shadow(0 0 11px ${hexToRgba(color, 0.8)});`;

  const glow = document.createElement("div");
  glow.style.cssText = `position:absolute;left:50%;bottom:-4px;width:10px;height:10px;margin-left:-5px;border-radius:50%;background:${color};box-shadow:0 0 8px 3px ${color};animation:shibuya3d-pin-pulse 2.4s ease-in-out infinite;pointer-events:none;`;
  el.style.position = "relative"; // glow(position:absolute)の基準にする。通常フローの高さには影響しない
  ensurePulseKeyframes();

  el.appendChild(card);
  el.appendChild(tail);
  el.appendChild(glow);
  return el;
}

// ランドマークのラベルは人物ピンより控えめに(小さく・低コントラスト)し、主役(2人のピン)を
// 邪魔しないようにする。発光演出も付けない。
function buildLandmarkLabelEl(text) {
  const el = document.createElement("div");
  el.className = "shibuya3d-landmark";
  el.style.cssText = `pointer-events:none;font-family:-apple-system,'Hiragino Sans',sans-serif;z-index:40;`;
  const card = document.createElement("div");
  card.style.cssText = `background:rgba(255,255,255,0.88);color:#4a4038;padding:2px 8px;border-radius:6px;font-size:10.5px;font-weight:700;white-space:nowrap;box-shadow:0 1px 3px rgba(0,0,0,.25);border:1px solid rgba(0,0,0,0.06);`;
  card.textContent = text;
  el.appendChild(card);
  return el;
}

// ---------- POI (Overpass-derived) loading + nearestShops ----------

let poisPromise = null;
function loadPois() {
  if (!poisPromise) {
    poisPromise = fetch(DEFAULT_POIS_URL).then((res) => {
      if (!res.ok) throw new Error(`nearestShops: failed to load POI data (${res.status})`);
      return res.json();
    });
  }
  return poisPromise;
}

/**
 * Return the n nearest named shops/amenities (from OSM, see data/pois_shibuya_1500m.geojson)
 * to a given lat/lng, sorted by distance ascending.
 * @returns {Promise<Array<{name:string, distanceM:number, level:string|null}>>}
 */
export async function nearestShops(lat, lng, n = 3) {
  const fc = await loadPois();
  const withDist = fc.features.map((f) => {
    const [flng, flat] = f.geometry.coordinates;
    return {
      name: f.properties.name,
      distanceM: Math.round(haversineMeters(lat, lng, flat, flng)),
      level: f.properties.level ?? null,
    };
  });
  withDist.sort((a, b) => a.distanceM - b.distanceM);
  return withDist.slice(0, n);
}

// ---------- main mount function ----------

/**
 * Mount the 3D Shibuya map into `el` (an Element, or a CSS selector string).
 * The element must already have a size (width/height) via CSS.
 * @returns {Promise<{setMe:Function, setPartner:Function, focusBoth:Function, destroy:Function}>}
 */
export async function mountShibuya3D(el, opts = {}) {
  const container = typeof el === "string" ? document.querySelector(el) : el;
  if (!container) throw new Error("mountShibuya3D: container element not found");

  ensureMaplibreCss();

  const map = new MapLibreMap({
    container,
    style: buildStyle(),
    center: [STATION.lng, STATION.lat],
    zoom: 15.6,
    pitch: DEFAULT_PITCH_DEG,
    maxPitch: 60,
    bearing: -17,
    maxBounds: computeMaxBounds(),
    minZoom: 14,
    maxZoom: 19,
    dragRotate: true,
    touchZoomRotate: true,
    pitchWithRotate: true,
    attributionControl: false,
  });

  map.addControl(new NavigationControl({ visualizePitch: true }), "top-right");
  // 出典表記(PLATEAU/地理院タイル/OSM)は、このコンポーネントを埋め込むページ側の外側フッター
  // (渋谷マチマチではworker/src/html.jsの.attribution-footer)で一元的に表示する。地図内蔵の
  // AttributionControlは追加しない(attributionControl:falseと合わせて二重表示を避けるため。
  // 2026-09-24 UXレビュー対応)。埋め込み先には必ず同等の出典表記を外側に置くこと。

  const pinsState = { me: null, partner: null };

  function refreshPinsSource() {
    const features = [];
    const glowFeatures = [];
    for (const role of ["me", "partner"]) {
      const p = pinsState[role];
      if (!p) continue;
      features.push({
        type: "Feature",
        properties: { role, heightM: p.heightM, color: p.color },
        geometry: { type: "Polygon", coordinates: [squarePolygon(p.lat, p.lng, PILLAR_HALF_SIZE_M)] },
      });
      glowFeatures.push({
        type: "Feature",
        properties: { role, color: p.color },
        geometry: { type: "Point", coordinates: [p.lng, p.lat] },
      });
    }
    const src = map.getSource("pins");
    if (src) src.setData({ type: "FeatureCollection", features });
    const glowSrc = map.getSource("pins-glow");
    if (glowSrc) glowSrc.setData({ type: "FeatureCollection", features: glowFeatures });

    const lineFeatures = [];
    if (pinsState.me && pinsState.partner) {
      lineFeatures.push({
        type: "Feature",
        properties: {},
        geometry: {
          type: "LineString",
          coordinates: [
            [pinsState.me.lng, pinsState.me.lat],
            [pinsState.partner.lng, pinsState.partner.lat],
          ],
        },
      });
    }
    const lineSrc = map.getSource("pins-line");
    if (lineSrc) lineSrc.setData({ type: "FeatureCollection", features: lineFeatures });
  }

  function updateMarkerOffsets() {
    const zoom = map.getZoom();
    const pitchRad = (map.getPitch() * Math.PI) / 180;
    const baseLift = {};
    for (const role of ["me", "partner"]) {
      const p = pinsState[role];
      if (!p) continue;
      const mpp = metersPerPixelAt(p.lat, zoom);
      baseLift[role] = (p.heightM / mpp) * Math.sin(pitchRad);
    }

    // 近接時: 2人のピンが画面上で近いと、ラベル同士が重なって両方読めなくなる。
    // 画面奥(=projectしたy座標が小さい方、遠景)にいる側のラベルだけ追加で持ち上げて縦にずらす。
    const extraLift = { me: 0, partner: 0 };
    if (pinsState.me && pinsState.partner) {
      const meScreen = map.project([pinsState.me.lng, pinsState.me.lat]);
      const partnerScreen = map.project([pinsState.partner.lng, pinsState.partner.lat]);
      const dx = meScreen.x - partnerScreen.x;
      const dy = meScreen.y - partnerScreen.y;
      if (Math.sqrt(dx * dx + dy * dy) < LABEL_STACK_DISTANCE_PX) {
        const raiseRole = meScreen.y <= partnerScreen.y ? "me" : "partner";
        extraLift[raiseRole] = LABEL_STACK_OFFSET_PX;
      }
    }

    for (const role of ["me", "partner"]) {
      const p = pinsState[role];
      if (!p) continue;
      p.marker.setOffset([0, -(baseLift[role] + extraLift[role])]);
    }

    // ランドマークラベルも同じ考え方で、建物の概算の高さぶんだけ画面上で持ち上げる
    // (屋上付近にラベルが浮かんで見えるようにする。人物ピンより優先度は低いので重なり回避はしない)。
    for (const lm of landmarkMarkers) {
      const mpp = metersPerPixelAt(lm.lat, zoom);
      const lift = (lm.heightM / mpp) * Math.sin(pitchRad);
      lm.marker.setOffset([0, -lift]);
    }
  }
  map.on("render", updateMarkerOffsets);

  const landmarkMarkers = LANDMARKS.map((lm) => {
    const marker = new Marker({ element: buildLandmarkLabelEl(lm.name), anchor: "bottom" })
      .setLngLat([lm.lng, lm.lat])
      .addTo(map);
    return { ...lm, marker };
  });

  // ---- 初回だけ再生する、ゆっくり回り込む演出カメラ(ピッチ60度)。 ----
  // 操作(ドラッグ/ズーム/回転/ピッチのユーザー操作開始イベント)か、実データ到着(setMe/setPartner)で
  // 即停止する。停止後にDEFAULT_PITCH_DEG(50度、既存のピン視認性チューニング)へ戻すのはfocusBoth
  // (実データ到着時に呼ばれる)に任せる。
  let introActive = true;
  let introRafId = null;
  function stopIntro() {
    if (!introActive) return;
    introActive = false;
    if (introRafId != null) cancelAnimationFrame(introRafId);
  }
  function startIntro() {
    let lastTs = null;
    function tick(ts) {
      if (!introActive) return;
      if (lastTs != null) {
        const dtSec = (ts - lastTs) / 1000;
        map.setBearing(map.getBearing() + INTRO_BEARING_DEG_PER_SEC * dtSec);
      }
      lastTs = ts;
      introRafId = requestAnimationFrame(tick);
    }
    map.setPitch(INTRO_PITCH_DEG);
    introRafId = requestAnimationFrame(tick);
  }
  for (const evt of ["dragstart", "zoomstart", "rotatestart", "pitchstart", "boxzoomstart"]) {
    map.on(evt, (e) => {
      if (e && e.originalEvent) stopIntro(); // ユーザー操作由来のイベントのみ(プログラムからのsetBearing等では発火しない)
    });
  }

  function upsertPin(role, lat, lng, floor, displayName) {
    stopIntro();
    const { heightM, label, basement } = floorInfo(floor);
    const color = role === "me" ? (basement ? ME_BASEMENT_COLOR : ME_COLOR) : basement ? PARTNER_BASEMENT_COLOR : PARTNER_COLOR;
    const text = `${displayName} ・ ${label}`;

    if (pinsState[role]?.marker) pinsState[role].marker.remove();
    const markerEl = buildLabelEl(text, color);
    const marker = new Marker({ element: markerEl, anchor: "bottom" }).setLngLat([lng, lat]).addTo(map);

    pinsState[role] = { lat, lng, heightM, color, marker, text };
    refreshPinsSource();
    updateMarkerOffsets();
  }

  function focusBoth() {
    const pts = [];
    if (pinsState.me) pts.push([pinsState.me.lng, pinsState.me.lat]);
    if (pinsState.partner) pts.push([pinsState.partner.lng, pinsState.partner.lat]);

    if (pts.length === 0) {
      map.flyTo({ center: [STATION.lng, STATION.lat], zoom: 15.6, pitch: DEFAULT_PITCH_DEG });
      return;
    }
    if (pts.length === 1) {
      map.flyTo({ center: pts[0], zoom: 17, pitch: DEFAULT_PITCH_DEG });
      return;
    }
    let west = pts[0][0], east = pts[0][0], south = pts[0][1], north = pts[0][1];
    for (const [lng, lat] of pts) {
      west = Math.min(west, lng);
      east = Math.max(east, lng);
      south = Math.min(south, lat);
      north = Math.max(north, lat);
    }
    // パディングはコンテナの実サイズの比率(FOCUS_PADDING_RATIO)から決める(理由は定数の
    // コメント参照)。マーカーのラベルpillが左右にはみ出す分だけ、横方向にも最小限の余白を残す
    // (ラベル文字幅から見積もった半分の幅を下限にする。2026-09-24 UXレビュー対応)。
    const rect = container.getBoundingClientRect();
    const vPad = safeSidePadding(clampPx(rect.height * FOCUS_PADDING_RATIO), rect.height);
    const labelHalfWidths = [pinsState.me?.text, pinsState.partner?.text]
      .filter(Boolean)
      .map(measureLabelHalfWidthPx);
    const labelPad = labelHalfWidths.length ? clampPx(Math.max(...labelHalfWidths), FOCUS_LABEL_PADDING_MAX_PX) : 0;
    const hPad = safeSidePadding(Math.max(clampPx(rect.width * FOCUS_PADDING_RATIO), labelPad), rect.width);
    map.fitBounds([[west, south], [east, north]], {
      padding: { top: vPad, bottom: vPad, left: hPad, right: hPad },
      pitch: DEFAULT_PITCH_DEG,
      bearing: map.getBearing(),
      maxZoom: 17,
      duration: 800,
    });
  }

  function destroy() {
    stopIntro();
    map.off("render", updateMarkerOffsets);
    if (pinsState.me?.marker) pinsState.me.marker.remove();
    if (pinsState.partner?.marker) pinsState.partner.marker.remove();
    for (const lm of landmarkMarkers) lm.marker.remove();
    map.remove();
  }

  await new Promise((resolve) => map.on("load", resolve));
  startIntro();
  opts.onReady?.();

  return {
    setMe: (lat, lng, floor) => upsertPin("me", lat, lng, floor, "自分"),
    setPartner: (lat, lng, floor, name) => upsertPin("partner", lat, lng, floor, name || "相手"),
    focusBoth,
    destroy,
  };
}
