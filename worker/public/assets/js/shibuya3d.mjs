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

import {
  Map as MapLibreMap,
  Marker,
  NavigationControl,
  AttributionControl,
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

// focusBothのfitBoundsパディングは、コンテナの実サイズに対する比率で決める(固定px値だと、
// このコンポーネントを小さい枠(渋谷マチマチ本体では.map3d=高さ280pxの縦横比が大きく違う枠)に
// 埋め込んだときに天地/左右のパディング合計がコンテナのサイズを超え、MapLibreのfitBoundsが
// 計算不能になって"Invalid LngLat object: (NaN, ...)"を投げ、後続のsetPartner以降の処理
// (近くのお店の取得含む)が丸ごと止まる不具合があったための対処。最小/最大でクランプし、
// 極端に小さい/大きいコンテナでも安全な範囲に収める。
const FOCUS_PADDING_RATIO = 0.12; // コンテナの幅・高さそれぞれの12%を片側パディングにする
const FOCUS_PADDING_MIN_PX = 12;
const FOCUS_PADDING_MAX_PX = 40;

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

function clampPx(px) {
  return Math.min(FOCUS_PADDING_MAX_PX, Math.max(FOCUS_PADDING_MIN_PX, px));
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

// ---------- CSS / style setup ----------

function ensureMaplibreCss() {
  if (document.querySelector("link[data-shibuya3d-maplibre-css]")) return;
  const link = document.createElement("link");
  link.rel = "stylesheet";
  link.href = MAPLIBRE_CSS_URL;
  link.setAttribute("data-shibuya3d-maplibre-css", "1");
  document.head.appendChild(link);
}

function buildStyle() {
  return {
    version: 8,
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
    },
    layers: [
      { id: "bg", type: "background", paint: { "background-color": "#e9eef1" } },
      { id: "gsi-pale-layer", type: "raster", source: "gsi-pale" },
      {
        id: "buildings-3d",
        type: "fill-extrusion",
        source: "buildings",
        paint: {
          "fill-extrusion-color": [
            "interpolate",
            ["linear"],
            ["get", "height"],
            0, "#d7dee3",
            20, "#b8c4cc",
            60, "#93a4b0",
            120, "#71889a",
            220, "#4c6478",
          ],
          "fill-extrusion-height": ["get", "height"],
          "fill-extrusion-base": 0,
          "fill-extrusion-opacity": BUILDING_OPACITY,
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
        },
      },
    ],
  };
}

// ---------- marker label DOM ----------

function buildLabelEl(text, color) {
  const el = document.createElement("div");
  el.style.cssText = `display:flex;flex-direction:column;align-items:center;pointer-events:none;font-family:-apple-system,'Hiragino Sans',sans-serif;z-index:${LABEL_Z_INDEX};`;

  const card = document.createElement("div");
  card.style.cssText = `background:${color};color:#fff;padding:4px 9px;border-radius:7px;font-size:12px;font-weight:700;white-space:nowrap;box-shadow:0 1px 5px rgba(0,0,0,.45);`;
  card.textContent = text;

  const tail = document.createElement("div");
  tail.style.cssText = `width:0;height:0;border-left:5px solid transparent;border-right:5px solid transparent;border-top:6px solid ${color};margin-top:-1px;`;

  el.appendChild(card);
  el.appendChild(tail);
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
  map.addControl(
    new AttributionControl({
      compact: false,
      customAttribution: [
        '地図: <a href="https://maps.gsi.go.jp/development/ichiran.html" target="_blank" rel="noopener">地理院タイル</a>',
        '店舗情報: © <a href="https://www.openstreetmap.org/copyright" target="_blank" rel="noopener">OpenStreetMap contributors</a>(ODbL)',
        "建物: 出典 国土交通省 3D都市モデルPLATEAU（渋谷区, CC BY 4.0）",
      ],
    }),
    "bottom-right"
  );

  const pinsState = { me: null, partner: null };

  function refreshPinsSource() {
    const features = [];
    for (const role of ["me", "partner"]) {
      const p = pinsState[role];
      if (!p) continue;
      features.push({
        type: "Feature",
        properties: { role, heightM: p.heightM, color: p.color },
        geometry: { type: "Polygon", coordinates: [squarePolygon(p.lat, p.lng, PILLAR_HALF_SIZE_M)] },
      });
    }
    const src = map.getSource("pins");
    if (src) src.setData({ type: "FeatureCollection", features });
  }

  function updateMarkerOffsets() {
    const zoom = map.getZoom();
    const pitchRad = (map.getPitch() * Math.PI) / 180;
    for (const role of ["me", "partner"]) {
      const p = pinsState[role];
      if (!p) continue;
      const mpp = metersPerPixelAt(p.lat, zoom);
      const pixelLift = (p.heightM / mpp) * Math.sin(pitchRad);
      p.marker.setOffset([0, -pixelLift]);
    }
  }
  map.on("render", updateMarkerOffsets);

  function upsertPin(role, lat, lng, floor, displayName) {
    const { heightM, label, basement } = floorInfo(floor);
    const color = role === "me" ? (basement ? ME_BASEMENT_COLOR : ME_COLOR) : basement ? PARTNER_BASEMENT_COLOR : PARTNER_COLOR;
    const text = `${displayName} ・ ${label}`;

    if (pinsState[role]?.marker) pinsState[role].marker.remove();
    const markerEl = buildLabelEl(text, color);
    const marker = new Marker({ element: markerEl, anchor: "bottom" }).setLngLat([lng, lat]).addTo(map);

    pinsState[role] = { lat, lng, heightM, color, marker };
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
    // パディングはコンテナの実サイズの比率(FOCUS_PADDING_RATIO)から計算する(理由は定数の
    // コメント参照)。マーカーのラベルpillが左右にはみ出す分だけ、横方向にも最小限の余白を残す。
    const rect = container.getBoundingClientRect();
    const vPad = clampPx(rect.height * FOCUS_PADDING_RATIO);
    const hPad = clampPx(rect.width * FOCUS_PADDING_RATIO);
    map.fitBounds([[west, south], [east, north]], {
      padding: { top: vPad, bottom: vPad, left: hPad, right: hPad },
      pitch: DEFAULT_PITCH_DEG,
      bearing: map.getBearing(),
      maxZoom: 17,
      duration: 800,
    });
  }

  function destroy() {
    map.off("render", updateMarkerOffsets);
    if (pinsState.me?.marker) pinsState.me.marker.remove();
    if (pinsState.partner?.marker) pinsState.partner.marker.remove();
    map.remove();
  }

  await new Promise((resolve) => map.on("load", resolve));
  opts.onReady?.();

  return {
    setMe: (lat, lng, floor) => upsertPin("me", lat, lng, floor, "自分"),
    setPartner: (lat, lng, floor, name) => upsertPin("partner", lat, lng, floor, name || "相手"),
    focusBoth,
    destroy,
  };
}
