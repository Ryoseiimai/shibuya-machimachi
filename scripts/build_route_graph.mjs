#!/usr/bin/env node
// 渋谷マチマチ: 歩行ルート案内用の「歩ける道のグラフ」(worker/public/route/graph.json)を
// OpenStreetMap のデータから作る前処理スクリプト。
//
// 使い方(リポジトリのルートで):
//   node scripts/build_route_graph.mjs --fetch --save-raw /tmp/raw_osm.json
//       Overpass API に1回だけ問い合わせて取得し、グラフを作る(生データも保存しておくと再実行が速い)
//   node scripts/build_route_graph.mjs --input /tmp/raw_osm.json
//       取得済みのOverpass結果(JSON)からグラフだけ作り直す(ネットワークに出ない)
//
// 出力: worker/public/route/graph.json(© OpenStreetMap contributors, ODbL)
//   nodes: [緯度, 経度, 緯度, 経度, ...](小数6桁)
//   edges: [ノードa, ノードb, 種別, aでの階, bでの階, フラグ, ...](6個で1本)
//     種別 = EDGE_TYPES(道/階段/エスカレーター/エレベーター/横断歩道)
//     階   = OSMのlevel(0=地上の階, -1=地下1階, 1=2階)。階段・エスカレーター・エレベーターは
//            両端で階が違う(=階移動のエッジ)。
//     フラグ = EDGE_FLAG_ONEWAY(a→bにしか進めない。上り/下り専用のエスカレーター等)
//
// 意図的な簡略化(本格対応の入口はそれぞれのコメント):
//   - OSMの level は建物ごとの相対値で、渋谷は谷地形のため「別の建物の4階が道路の地上」
//     ということが普通にある。ここでは level をそのまま使い、補正はしない。
//   - 道路は車道の中心線も歩行可として扱う(歩道が別に描かれていれば両方入る)。
//   - 一方通行は歩行者向けのもの(エスカレーター・oneway:foot・歩行者用通路のoneway)だけ守る。
//   - 最大の「強連結成分」(どのノードからどのノードへも行ける塊)だけを残し、
//     つながっていない館内の島などは捨てる(到達不能ルートを出さないため)。
import fs from "node:fs";
import path from "node:path";
import zlib from "node:zlib";
import crypto from "node:crypto";
import { fileURLToPath } from "node:url";

// 渋谷駅(worker/src/constants.js の SHIBUYA_STATION と同じ点)と、その半径(アプリの対象エリア)。
export const CENTER = Object.freeze({ lat: 35.658, lng: 139.7016 });
export const RADIUS_M = 1500;
// 端の道が途中で切れて行き止まりだらけにならないよう、半径より少し外側まで残す。
const CLIP_RADIUS_M = 1600;
// Overpassに投げる矩形は、半径+余白を含む範囲(aroundより軽い bbox 指定にする。around は
// 2026-09-26 の取得時に公開サーバーで504になったため)。
const BBOX_MARGIN_M = 100;

export const EDGE_TYPES = Object.freeze({ WALK: 0, STEPS: 1, ESCALATOR: 2, ELEVATOR: 3, CROSSING: 4 });
export const EDGE_FLAG_ONEWAY = 1;
// 階段・エスカレーターの両端の階を推測で決めた(はっきりしたlevelタグの道につながっていない)印。
// 案内では上り/下りを言わず「階段を通る」とだけ言う(route.js)。
export const EDGE_FLAG_LEVEL_GUESSED = 2;
export const GRAPH_FORMAT = "shibuya-machimachi-route-graph/1";

const COORD_DECIMALS = 6;
const LEVEL_DECIMALS = 2;
// 道の形を間引く許容誤差(m)。これ以下のズレしか生まない途中の点は捨てる(矢印の向きには影響しない程度)。
const SIMPLIFY_TOLERANCE_M = 2;
const EARTH_RADIUS_M = 6371000;
const VERSION_HASH_LENGTH = 10;

const OVERPASS_URL = "https://overpass-api.de/api/interpreter";
const OVERPASS_TIMEOUT_S = 180;
const USER_AGENT = "shibuya-machimachi-route-builder/1.0 (+https://github.com/Ryoseiimai/shibuya-machimachi)";

const WALKABLE_HIGHWAYS = new Set([
  "footway", "pedestrian", "path", "steps", "living_street", "residential", "service",
  "unclassified", "tertiary", "tertiary_link", "secondary", "secondary_link", "primary",
  "primary_link", "trunk", "trunk_link", "corridor", "elevator", "cycleway", "track", "road", "platform",
]);
// 車道(歩行者は一方通行を無視してよい種別)。
const ROAD_HIGHWAYS = new Set([
  "living_street", "residential", "service", "unclassified", "tertiary", "tertiary_link",
  "secondary", "secondary_link", "primary", "primary_link", "trunk", "trunk_link", "road", "track",
]);
const BIG_ROAD_HIGHWAYS = new Set(["trunk", "trunk_link", "primary", "primary_link"]);
const FOOT_DENIED = new Set(["no", "private", "use_sidepath"]);
const FOOT_ALLOWED = new Set(["yes", "designated", "permissive"]);
const ACCESS_DENIED = new Set(["no", "private"]);
const SIDEWALK_PRESENT = new Set(["both", "left", "right", "yes", "separate"]);

const highwayPattern = [...WALKABLE_HIGHWAYS].join("|");

// 渋谷駅から半径(+余白)を覆う矩形 [south, west, north, east]
export function bboxAround(center, radiusM) {
  const dLat = (radiusM / EARTH_RADIUS_M) * (180 / Math.PI);
  const dLng = dLat / Math.cos((center.lat * Math.PI) / 180);
  const r = (v) => Number(v.toFixed(4));
  return [r(center.lat - dLat), r(center.lng - dLng), r(center.lat + dLat), r(center.lng + dLng)];
}

export function buildOverpassQuery(center = CENTER, radiusM = RADIUS_M) {
  const [s, w, n, e] = bboxAround(center, radiusM + BBOX_MARGIN_M);
  return `[out:json][timeout:${OVERPASS_TIMEOUT_S}][bbox:${s},${w},${n},${e}];
(
  way["highway"~"^(${highwayPattern})$"];
  way["indoor"="corridor"];
  way["conveying"];
)->.w;
.w out body geom qt;
node["highway"="elevator"];
out body qt;
`;
}

export function distanceMeters(lat1, lng1, lat2, lng2) {
  const toRad = (d) => (d * Math.PI) / 180;
  const dLat = toRad(lat2 - lat1);
  const dLng = toRad(lng2 - lng1);
  const a = Math.sin(dLat / 2) ** 2 + Math.cos(toRad(lat1)) * Math.cos(toRad(lat2)) * Math.sin(dLng / 2) ** 2;
  return EARTH_RADIUS_M * 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
}

// OSMの level タグを数値の配列(昇順・重複なし)にする。
//   "0;1" → [0,1] / "-2;0;6;10" → [-2,0,6,10] / "0,1"(区切りの誤記) → [0,1]
//   "1-3" → [1,2,3] / "-2--1" → [-2,-1] / "3.5" → [3.5] / 数値でないもの → []
export function parseLevels(value) {
  if (typeof value !== "string" || !value.trim()) return [];
  const out = new Set();
  for (const raw of value.split(/[;,]/)) {
    const part = raw.trim();
    if (!part) continue;
    const range = part.match(/^(-?\d+(?:\.\d+)?)\s*-\s*(-?\d+(?:\.\d+)?)$/);
    if (range) {
      const lo = Math.min(Number(range[1]), Number(range[2]));
      const hi = Math.max(Number(range[1]), Number(range[2]));
      if (Number.isInteger(lo) && Number.isInteger(hi)) {
        for (let l = lo; l <= hi; l += 1) out.add(l);
      } else {
        out.add(lo);
        out.add(hi);
      }
      continue;
    }
    const n = Number(part);
    if (part !== "" && Number.isFinite(n)) out.add(n);
  }
  return [...out].sort((a, b) => a - b);
}

// level タグが無い道の階。地下道(tunnel=yes / location=underground で layer がマイナス)だけ
// layer を階とみなし、それ以外は地上(0)。歩道橋(layer=1)は屋外なので地上扱いのまま。
export function defaultLevel(tags) {
  const layer = Number(tags.layer);
  const underground = tags.tunnel === "yes" || tags.location === "underground";
  if (underground && Number.isFinite(layer) && layer < 0) return layer;
  return 0;
}

function hasSidewalk(tags) {
  return SIDEWALK_PRESENT.has(tags.sidewalk) || SIDEWALK_PRESENT.has(tags["sidewalk:both"]) ||
    SIDEWALK_PRESENT.has(tags["sidewalk:left"]) || SIDEWALK_PRESENT.has(tags["sidewalk:right"]);
}

// 歩いて通れる道か(私有地・立入禁止・歩行者禁止・車専用トンネルなどを除く)。
export function isWalkableWay(tags) {
  if (!tags) return false;
  const hw = tags.highway;
  const conveying = typeof tags.conveying === "string" && tags.conveying !== "no";
  const indoorCorridor = tags.indoor === "corridor";
  if (hw && !WALKABLE_HIGHWAYS.has(hw)) return false;
  if (!hw && !indoorCorridor && !conveying) return false;
  if (FOOT_DENIED.has(tags.foot)) return false;
  const footAllowed = FOOT_ALLOWED.has(tags.foot);
  if (ACCESS_DENIED.has(tags.access) && !footAllowed) return false;
  if (hw === "service" && tags.service === "drive-through") return false;
  if (BIG_ROAD_HIGHWAYS.has(hw) && tags.tunnel === "yes" && !footAllowed && !hasSidewalk(tags)) return false;
  return true;
}

// 道の種類 → エッジ種別と、歩行者向けの一方通行('forward'=描いた向きだけ, 'backward'=逆向きだけ)。
export function classifyWay(tags) {
  const hw = tags.highway;
  if (hw === "elevator") return { kind: "elevator", oneway: null };
  const conveying = typeof tags.conveying === "string" && tags.conveying !== "no";
  if (conveying && hw !== "footway" && hw !== "corridor") {
    // 意図的な簡略化: conveying=yes/both/reversible は向きが決まっていないので両方向に通れる扱い。
    const oneway = tags.conveying === "forward" ? "forward" : tags.conveying === "backward" ? "backward" : null;
    return { kind: "escalator", oneway };
  }
  const oneway = footOneway(tags);
  if (hw === "steps") return { kind: "steps", oneway };
  if (tags.footway === "crossing" || (hw === "footway" && typeof tags.crossing === "string" && tags.crossing !== "no")) {
    return { kind: "crossing", oneway };
  }
  return { kind: "walk", oneway };
}

function footOneway(tags) {
  const footTag = tags["oneway:foot"];
  if (footTag === "yes") return "forward";
  if (footTag === "-1") return "backward";
  if (ROAD_HIGHWAYS.has(tags.highway)) return null; // 車道の一方通行は歩行者には関係ない
  if (tags.oneway === "yes") return "forward";
  if (tags.oneway === "-1") return "backward";
  return null;
}

const KIND_TO_TYPE = Object.freeze({
  walk: EDGE_TYPES.WALK, steps: EDGE_TYPES.STEPS, escalator: EDGE_TYPES.ESCALATOR,
  elevator: EDGE_TYPES.ELEVATOR, crossing: EDGE_TYPES.CROSSING,
});

// ---------- 形の間引き(Douglas–Peucker, 渋谷付近の平面近似でm単位) ----------

function toLocalXY(lat, lng) {
  const kx = Math.cos((CENTER.lat * Math.PI) / 180) * (Math.PI / 180) * EARTH_RADIUS_M;
  const ky = (Math.PI / 180) * EARTH_RADIUS_M;
  return [(lng - CENTER.lng) * kx, (lat - CENTER.lat) * ky];
}

function pointSegmentDistance(p, a, b) {
  const dx = b[0] - a[0];
  const dy = b[1] - a[1];
  const len2 = dx * dx + dy * dy;
  const t = len2 === 0 ? 0 : Math.max(0, Math.min(1, ((p[0] - a[0]) * dx + (p[1] - a[1]) * dy) / len2));
  const x = a[0] + t * dx - p[0];
  const y = a[1] + t * dy - p[1];
  return Math.sqrt(x * x + y * y);
}

// coords[i..j] のうち残す添字(両端は必ず残す)を keep に立てる。
function douglasPeucker(xy, i, j, tolerance, keep) {
  let maxD = -1;
  let idx = -1;
  for (let k = i + 1; k < j; k += 1) {
    const d = pointSegmentDistance(xy[k], xy[i], xy[j]);
    if (d > maxD) { maxD = d; idx = k; }
  }
  if (idx !== -1 && maxD > tolerance) {
    keep[idx] = true;
    douglasPeucker(xy, i, idx, tolerance, keep);
    douglasPeucker(xy, idx, j, tolerance, keep);
  }
}

// ---------- 本体 ----------

// Overpassの結果(JSON)から、歩ける道のピース(半径外で分割済み)を取り出す。
function extractPieces(osm, center, clipRadiusM) {
  const pieces = [];
  const elevatorWays = [];
  for (const el of osm.elements || []) {
    if (el.type !== "way" || !el.tags || !Array.isArray(el.nodes) || !Array.isArray(el.geometry)) continue;
    if (el.nodes.length !== el.geometry.length || el.nodes.length < 2) continue;
    if (!isWalkableWay(el.tags)) continue;
    const { kind, oneway } = classifyWay(el.tags);
    const target = kind === "elevator" ? elevatorWays : pieces;
    let run = [];
    const flush = () => {
      if (run.length >= 2) target.push({ wayId: el.id, tags: el.tags, kind, oneway, nodes: run.map((r) => r.id), coords: run.map((r) => r.c) });
      run = [];
    };
    for (let i = 0; i < el.nodes.length; i += 1) {
      const g = el.geometry[i];
      if (!g || !Number.isFinite(g.lat) || !Number.isFinite(g.lon)) { flush(); continue; }
      const inside = distanceMeters(center.lat, center.lng, g.lat, g.lon) <= clipRadiusM;
      if (!inside) { flush(); continue; }
      run.push({ id: String(el.nodes[i]), c: [g.lat, g.lon] });
    }
    flush();
  }
  return { pieces, elevatorWays };
}

function isVerticalPiece(piece) {
  return piece.kind === "steps" || piece.kind === "escalator" || piece.levels.length > 1;
}

function mostCommon(values) {
  const counts = new Map();
  for (const v of values) counts.set(v, (counts.get(v) || 0) + 1);
  let best = null;
  let bestCount = 0;
  for (const [v, c] of counts) if (c > bestCount) { best = v; bestCount = c; }
  return best;
}

// 階段・エスカレーター等(縦に移動するピース)の各点の階を決める。
//   1) その点につながる平らな道の階(ピースのlevel候補に含まれるもの)
//   2) その点につながる別の縦ピースとlevel候補が1つだけ重なればその階
//   3) 端点がまだ決まらなければ incline(up/down) → もう片端の残り → 候補の最小/最大(推測)
//   4) 途中の点は、決まった点どうしの間を距離で按分(小数の階になる)
// 返り値の guessed=true は「levelタグの無い道につながる/最小・最大で決めた」など、上り下りの向きに
// 自信がないもの(渋谷では、タグの無い歩道橋デッキを地上(0)とみなして向きが逆になる例がある)。
function assignVerticalLevels(piece, incidence) {
  const set = piece.levels;
  const n = piece.nodes.length;
  const anchors = new Array(n).fill(null);
  const sure = new Array(n).fill(false);
  for (let i = 0; i < n; i += 1) {
    const others = (incidence.get(piece.nodes[i]) || []).filter((p) => p !== piece);
    const flat = others.filter((p) => !p.vertical && (set.length === 0 || set.includes(p.flatLevel)));
    if (flat.length) {
      anchors[i] = mostCommon(flat.map((p) => p.flatLevel));
      sure[i] = flat.some((p) => p.levelExplicit && p.flatLevel === anchors[i]);
      continue;
    }
    const shared = [];
    for (const p of others) {
      if (!p.vertical || set.length === 0) continue;
      const common = set.filter((l) => p.levels.includes(l));
      if (common.length === 1) shared.push(common[0]);
    }
    if (shared.length) { anchors[i] = mostCommon(shared); sure[i] = true; }
  }
  if (set.length >= 2) {
    const lo = set[0];
    const hi = set[set.length - 1];
    const incline = piece.tags.incline;
    const up = incline === "up" || /^\+?\d/.test(incline || "");
    const down = incline === "down" || /^-\d/.test(incline || "");
    const byIncline = up || down;
    if (anchors[0] === null && anchors[n - 1] === null) {
      if (down) { anchors[0] = hi; anchors[n - 1] = lo; }
      else { anchors[0] = lo; anchors[n - 1] = hi; } // up、または不明(推測)
      sure[0] = sure[n - 1] = byIncline;
    } else if (anchors[0] === null) {
      anchors[0] = anchors[n - 1] === lo ? hi : lo;
      sure[0] = sure[n - 1] && set.length === 2;
    } else if (anchors[n - 1] === null) {
      anchors[n - 1] = anchors[0] === lo ? hi : lo;
      sure[n - 1] = sure[0] && set.length === 2;
    }
    // 候補が2つ(例 "0;1")で片端がはっきりしていれば、もう片端が残りの階と一致していれば確か
    // (例: levelの無い道(0とみなす) ─ 階段 ─ level=1のデッキ)
    if (set.length === 2) {
      const other = (l) => (l === lo ? hi : lo);
      if (sure[0] && !sure[n - 1] && anchors[n - 1] === other(anchors[0])) sure[n - 1] = true;
      if (sure[n - 1] && !sure[0] && anchors[0] === other(anchors[n - 1])) sure[0] = true;
    }
  }
  // levelタグの候補が、つながる道のどの階とも合わない(例: 地下2階と地下1階を結ぶのに "0;1")ときは、
  // タグを捨てて、つながる道の階をそのまま両端の階にする(向きは推測扱い)
  if (set.length && anchors.every((a, i) => a === null || (!sure[i] && (i === 0 || i === n - 1)))) {
    const neighborLevel = (i) => {
      const flat = (incidence.get(piece.nodes[i]) || []).filter((p) => p !== piece && !p.vertical);
      return flat.length ? mostCommon(flat.map((p) => p.flatLevel)) : null;
    };
    const first = neighborLevel(0);
    const last = neighborLevel(n - 1);
    if (first !== null && last !== null && !set.includes(first) && !set.includes(last)) {
      anchors.fill(null);
      sure.fill(false);
      anchors[0] = first;
      anchors[n - 1] = last;
    }
  }
  const known = [];
  for (let i = 0; i < n; i += 1) if (anchors[i] !== null) known.push(i);
  const fallback = set.length ? set[0] : piece.flatLevel;
  if (!known.length) return { levels: new Array(n).fill(fallback), guessed: true };
  const guessed = !sure[0] || !sure[n - 1];
  const cum = [0];
  for (let i = 1; i < n; i += 1) {
    const [la, lo1] = piece.coords[i - 1];
    const [lb, lo2] = piece.coords[i];
    cum.push(cum[i - 1] + distanceMeters(la, lo1, lb, lo2));
  }
  const levels = new Array(n);
  for (let i = 0; i < n; i += 1) {
    if (anchors[i] !== null) { levels[i] = anchors[i]; continue; }
    const prev = [...known].reverse().find((k) => k < i);
    const next = known.find((k) => k > i);
    if (prev === undefined) { levels[i] = anchors[next]; continue; }
    if (next === undefined) { levels[i] = anchors[prev]; continue; }
    const span = cum[next] - cum[prev];
    const t = span > 0 ? (cum[i] - cum[prev]) / span : 0;
    levels[i] = anchors[prev] + (anchors[next] - anchors[prev]) * t;
  }
  return { levels, guessed };
}

function roundLevel(l) {
  const f = 10 ** LEVEL_DECIMALS;
  return Math.round(l * f) / f;
}

// 最大の強連結成分(有向グラフとして、どこからどこへも行ける塊)のノード集合を返す(反復版Tarjan)。
export function largestStronglyConnected(nodeCount, arcsFrom) {
  const index = new Int32Array(nodeCount).fill(-1);
  const low = new Int32Array(nodeCount);
  const onStack = new Uint8Array(nodeCount);
  const stack = [];
  let counter = 0;
  let best = [];
  for (let root = 0; root < nodeCount; root += 1) {
    if (index[root] !== -1) continue;
    const work = [[root, 0]];
    index[root] = low[root] = counter++;
    stack.push(root);
    onStack[root] = 1;
    while (work.length) {
      const frame = work[work.length - 1];
      const v = frame[0];
      const outs = arcsFrom[v];
      if (frame[1] < outs.length) {
        const w = outs[frame[1]++];
        if (index[w] === -1) {
          index[w] = low[w] = counter++;
          stack.push(w);
          onStack[w] = 1;
          work.push([w, 0]);
        } else if (onStack[w]) {
          low[v] = Math.min(low[v], index[w]);
        }
        continue;
      }
      work.pop();
      if (work.length) {
        const parent = work[work.length - 1][0];
        low[parent] = Math.min(low[parent], low[v]);
      }
      if (low[v] === index[v]) {
        const comp = [];
        let w;
        do { w = stack.pop(); onStack[w] = 0; comp.push(w); } while (w !== v);
        if (comp.length > best.length) best = comp;
      }
    }
  }
  return new Set(best);
}

/**
 * Overpassの結果(JSON)から歩行グラフを作る。
 * @returns {{nodes: Array<{lat:number,lng:number}>, edges: Array<{a:number,b:number,type:number,la:number,lb:number,flags:number}>, stats: object}}
 */
export function buildGraph(osm, { center = CENTER, clipRadiusM = CLIP_RADIUS_M, simplifyToleranceM = SIMPLIFY_TOLERANCE_M } = {}) {
  const { pieces, elevatorWays } = extractPieces(osm, center, clipRadiusM);
  const elevatorNodeIds = new Set();
  for (const el of osm.elements || []) {
    if (el.type === "node" && el.tags && el.tags.highway === "elevator") elevatorNodeIds.add(String(el.id));
  }

  // ピースごとの階と、点(OSMノード)→それを通るピースの対応表
  const incidence = new Map();
  for (const p of pieces) {
    p.levels = parseLevels(p.tags.level);
    p.vertical = isVerticalPiece(p);
    p.flatLevel = p.levels.length ? p.levels[0] : defaultLevel(p.tags);
    p.levelExplicit = p.levels.length > 0;
    for (const id of p.nodes) {
      if (!incidence.has(id)) incidence.set(id, []);
      const list = incidence.get(id);
      if (!list.includes(p)) list.push(p);
    }
  }
  for (const p of pieces) {
    if (p.vertical) {
      const { levels, guessed } = assignVerticalLevels(p, incidence);
      p.nodeLevels = levels;
      p.levelGuessed = guessed;
    } else {
      p.nodeLevels = new Array(p.nodes.length).fill(p.flatLevel);
      p.levelGuessed = false;
    }
  }

  const coordOf = new Map();
  for (const p of pieces) p.nodes.forEach((id, i) => coordOf.set(id, p.coords[i]));

  // 分岐点(2本以上のピースが通る点)・端点・エレベーターの点は必ず残し、それ以外を間引く
  const rawEdges = [];
  for (const p of pieces) {
    const n = p.nodes.length;
    const keep = new Array(n).fill(false);
    keep[0] = keep[n - 1] = true;
    for (let i = 1; i < n - 1; i += 1) {
      const id = p.nodes[i];
      if ((incidence.get(id) || []).length > 1 || elevatorNodeIds.has(id)) keep[i] = true;
      if (p.vertical) keep[i] = true; // 階段等は短いので全点残す(階の按分を崩さない)
    }
    if (!p.vertical) {
      const xy = p.coords.map(([lat, lng]) => toLocalXY(lat, lng));
      let start = 0;
      for (let i = 1; i < n; i += 1) {
        if (!keep[i]) continue;
        douglasPeucker(xy, start, i, simplifyToleranceM, keep);
        start = i;
      }
    }
    const type = KIND_TO_TYPE[p.kind];
    let prev = 0;
    for (let i = 1; i < n; i += 1) {
      if (!keep[i]) continue;
      if (p.nodes[prev] !== p.nodes[i]) {
        let a = p.nodes[prev];
        let b = p.nodes[i];
        let la = p.nodeLevels[prev];
        let lb = p.nodeLevels[i];
        const oneway = p.oneway === "forward" || p.oneway === "backward";
        if (p.oneway === "backward") { [a, b] = [b, a]; [la, lb] = [lb, la]; }
        const flags = (oneway ? EDGE_FLAG_ONEWAY : 0) | (p.levelGuessed && la !== lb ? EDGE_FLAG_LEVEL_GUESSED : 0);
        rawEdges.push({ a, b, type, la: roundLevel(la), lb: roundLevel(lb), flags });
      }
      prev = i;
    }
  }

  // エレベーター(点): つながる道の階が2種類以上なら、階ごとに点を分けて「エレベーター」エッジで結ぶ
  let virtualCounter = 0;
  const elevatorEdges = [];
  const levelAtEnd = (e, id) => (e.a === id ? e.la : e.lb);
  const byNode = new Map();
  for (const e of rawEdges) {
    for (const id of [e.a, e.b]) {
      if (!elevatorNodeIds.has(id)) continue;
      if (!byNode.has(id)) byNode.set(id, []);
      byNode.get(id).push(e);
    }
  }
  for (const [id, edges] of byNode) {
    const groups = new Map();
    for (const e of edges) {
      const l = levelAtEnd(e, id);
      if (!groups.has(l)) groups.set(l, []);
      groups.get(l).push(e);
    }
    if (groups.size < 2) continue;
    const reps = [];
    for (const [level, list] of groups) {
      const vid = `${id}@${level}#${virtualCounter++}`;
      coordOf.set(vid, coordOf.get(id));
      for (const e of list) {
        if (e.a === id && e.la === level) e.a = vid;
        if (e.b === id && e.lb === level) e.b = vid;
      }
      reps.push({ vid, level });
    }
    for (let i = 0; i < reps.length; i += 1) {
      for (let j = i + 1; j < reps.length; j += 1) {
        elevatorEdges.push({ a: reps[i].vid, b: reps[j].vid, type: EDGE_TYPES.ELEVATOR, la: reps[i].level, lb: reps[j].level, flags: 0 });
      }
    }
  }

  // エレベーター(かご/シャフトを線や面で描いたもの): 別の階の道とつながる点どうしを結ぶ
  const endpointLevels = new Map();
  for (const e of rawEdges) {
    for (const [id, l] of [[e.a, e.la], [e.b, e.lb]]) {
      if (!endpointLevels.has(id)) endpointLevels.set(id, new Set());
      endpointLevels.get(id).add(l);
    }
  }
  for (const w of elevatorWays) {
    const attach = new Map(); // level → node id(階ごとに代表1点)
    for (const id of new Set(w.nodes)) {
      const levels = endpointLevels.get(id);
      if (!levels) continue;
      for (const l of levels) if (!attach.has(l)) attach.set(l, id);
    }
    const reps = [...attach.entries()];
    for (let i = 0; i < reps.length; i += 1) {
      for (let j = i + 1; j < reps.length; j += 1) {
        if (reps[i][1] === reps[j][1]) continue;
        elevatorEdges.push({ a: reps[i][1], b: reps[j][1], type: EDGE_TYPES.ELEVATOR, la: reps[i][0], lb: reps[j][0], flags: 0 });
      }
    }
  }

  const allEdges = rawEdges.concat(elevatorEdges);

  // ノード番号を振って、最大の強連結成分だけ残す
  const idToIndex = new Map();
  const ids = [];
  const indexOf = (id) => {
    if (!idToIndex.has(id)) { idToIndex.set(id, ids.length); ids.push(id); }
    return idToIndex.get(id);
  };
  for (const e of allEdges) { e.ai = indexOf(e.a); e.bi = indexOf(e.b); }
  const arcsFrom = ids.map(() => []);
  for (const e of allEdges) {
    arcsFrom[e.ai].push(e.bi);
    if (!(e.flags & EDGE_FLAG_ONEWAY)) arcsFrom[e.bi].push(e.ai);
  }
  const keepSet = largestStronglyConnected(ids.length, arcsFrom);

  const finalIndex = new Map();
  const nodes = [];
  const edges = [];
  const seen = new Set();
  const nodeIndex = (i) => {
    if (!finalIndex.has(i)) {
      const [lat, lng] = coordOf.get(ids[i]);
      finalIndex.set(i, nodes.length);
      nodes.push({ lat: Number(lat.toFixed(COORD_DECIMALS)), lng: Number(lng.toFixed(COORD_DECIMALS)) });
    }
    return finalIndex.get(i);
  };
  for (const e of allEdges) {
    if (!keepSet.has(e.ai) || !keepSet.has(e.bi)) continue;
    const a = nodeIndex(e.ai);
    const b = nodeIndex(e.bi);
    const key = e.flags & EDGE_FLAG_ONEWAY
      ? `${a}>${b}|${e.type}|${e.la}|${e.lb}`
      : a < b ? `${a}-${b}|${e.type}|${e.la}|${e.lb}` : `${b}-${a}|${e.type}|${e.lb}|${e.la}`;
    if (seen.has(key)) continue;
    seen.add(key);
    edges.push({ a, b, type: e.type, la: e.la, lb: e.lb, flags: e.flags });
  }

  const typeCounts = {};
  for (const [name, code] of Object.entries(EDGE_TYPES)) typeCounts[name] = edges.filter((e) => e.type === code).length;
  const floorChanges = edges.filter((e) => e.la !== e.lb).length;
  return {
    nodes,
    edges,
    stats: {
      pieces: pieces.length,
      elevatorWays: elevatorWays.length,
      nodesBeforePrune: ids.length,
      nodes: nodes.length,
      edges: edges.length,
      floorChangeEdges: floorChanges,
      onewayEdges: edges.filter((e) => e.flags & EDGE_FLAG_ONEWAY).length,
      levelGuessedEdges: edges.filter((e) => e.flags & EDGE_FLAG_LEVEL_GUESSED).length,
      typeCounts,
    },
  };
}

// グラフ → 配信用JSON(版の印=中身のハッシュ付き)
export function encodeGraph(graph, meta = {}) {
  const nodes = [];
  for (const n of graph.nodes) nodes.push(n.lat, n.lng);
  const edges = [];
  for (const e of graph.edges) edges.push(e.a, e.b, e.type, e.la, e.lb, e.flags);
  const version = crypto.createHash("sha256").update(JSON.stringify([nodes, edges])).digest("hex").slice(0, VERSION_HASH_LENGTH);
  return {
    format: GRAPH_FORMAT,
    version,
    attribution: "© OpenStreetMap contributors (ODbL)",
    license: "ODbL-1.0 https://www.openstreetmap.org/copyright",
    osmBase: meta.osmBase || null,
    center: [CENTER.lat, CENTER.lng],
    radiusM: RADIUS_M,
    edgeTypes: Object.keys(EDGE_TYPES).map((k) => k.toLowerCase()),
    edgeStride: 6,
    nodes,
    edges,
  };
}

async function fetchOverpass(query) {
  const body = new URLSearchParams({ data: query });
  const res = await fetch(process.env.OVERPASS_URL || OVERPASS_URL, {
    method: "POST",
    headers: { "User-Agent": USER_AGENT, "Content-Type": "application/x-www-form-urlencoded" },
    body,
  });
  if (!res.ok) throw new Error(`Overpass API エラー: HTTP ${res.status}`);
  return res.json();
}

function parseArgs(argv) {
  const args = { fetch: false, input: null, saveRaw: null, out: null };
  for (let i = 0; i < argv.length; i += 1) {
    const a = argv[i];
    if (a === "--fetch") args.fetch = true;
    else if (a === "--input") args.input = argv[++i];
    else if (a === "--save-raw") args.saveRaw = argv[++i];
    else if (a === "--out") args.out = argv[++i];
    else if (a === "--print-query") args.printQuery = true;
    else throw new Error(`不明な引数: ${a}`);
  }
  return args;
}

async function main() {
  const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
  const args = parseArgs(process.argv.slice(2));
  if (args.printQuery) { process.stdout.write(buildOverpassQuery()); return; }
  if (!args.fetch && !args.input) throw new Error("--fetch か --input <Overpass結果.json> を指定してください");
  let osm;
  if (args.input) {
    osm = JSON.parse(fs.readFileSync(args.input, "utf8"));
  } else {
    osm = await fetchOverpass(buildOverpassQuery());
    if (args.saveRaw) fs.writeFileSync(args.saveRaw, JSON.stringify(osm));
  }
  const graph = buildGraph(osm);
  const encoded = encodeGraph(graph, { osmBase: osm.osm3s && osm.osm3s.timestamp_osm_base });
  const outPath = args.out || path.join(repoRoot, "worker", "public", "route", "graph.json");
  fs.mkdirSync(path.dirname(outPath), { recursive: true });
  const text = JSON.stringify(encoded);
  fs.writeFileSync(outPath, text + "\n");
  const gz = zlib.gzipSync(text, { level: 9 }).length;
  console.log(JSON.stringify({ out: outPath, version: encoded.version, bytes: text.length, gzipBytes: gz, ...graph.stats }, null, 2));
}

if (process.argv[1] && fileURLToPath(import.meta.url) === path.resolve(process.argv[1])) {
  main().catch((err) => {
    console.error(err);
    process.exit(1);
  });
}
