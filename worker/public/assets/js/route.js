// 渋谷マチマチ 歩行ルート案内のエンジン。
// DOM/ブラウザAPIに依存しない純粋関数だけを置く(node:test でそのまま単体テストするため。
// 画面部品は route-panel.js)。道のデータは scripts/build_route_graph.mjs が OpenStreetMap から作った
// /route/graph.json(© OpenStreetMap contributors, ODbL)。
//
// 位置情報の扱い: この経路計算は端末の中だけで完結する(自分の位置も目的地もサーバーへ送らない)。
//
// 使い方:
//   const graph = decodeGraph(json);                     // graph.json → 計算用の配列
//   const r = findRoute(graph, from, to);               // from/to = {lat, lng, level}
//   const g = guide(r.route, {lat, lng}, { level });    // 次の経由点・案内文・残りの道のり・到着/逸脱
//
// 階(level)は OSM の数え方: 0=地上の階(1階), 1=2階, -1=地下1階。画面の "1F"/"B1" とは
// floorLabelToLevel / levelToFloorLabel で相互に変換する。

export const EDGE_TYPE = Object.freeze({ WALK: 0, STEPS: 1, ESCALATOR: 2, ELEVATOR: 3, CROSSING: 4 });
export const EDGE_FLAG_ONEWAY = 1;
export const EDGE_FLAG_LEVEL_GUESSED = 2; // 階段等の両端の階が推測(上り/下りを言わない)

// 配信データの版の印。graph.json / places.json の "version" と必ず一致させる
// (worker/test/route-data.test.js が検査する)。/route/* は1年キャッシュなので、中身を変えたら
// ここも上げて古いキャッシュを読まないようにする。
export const ROUTE_GRAPH_VERSION = "52c88875bd";
export const PLACES_VERSION = "2026-09-26a";

export const OFF_ROUTE_M = 25; // 経路からこれ以上離れたら再計算
export const ARRIVAL_M = 15; // 同じ階でこれ以内なら到着
export const WALK_M_PER_MIN = 80; // 所要時間の目安(分速80m)
export const FLOOR_PROMPT_M = 20; // 階の移動がこれ以内に迫ったら「◯階に着いた」ボタンを出す

const EARTH_RADIUS_M = 6371000;
const DEG = Math.PI / 180;
const LEVEL_MATCH_TOLERANCE = 0.5;
const LEVEL_MISMATCH_PENALTY_M = 30; // 違う階の道に吸着しにくくする重み(地下と地上が真上に重なる駅のため)
const SNAP_MAX_M = 150; // これより遠い道には吸着しない(エリア外・データの無い場所)
const WAYPOINT_MIN_AHEAD_M = 6; // 矢印が指す「次の経由点」は、今の位置からこれ以上先の点
const TURN_SMOOTH_M = 8; // 曲がり角の角度は前後この距離の点で測る(細かいジグザグを無視する)
const TURN_MIN_DEG = 35;
const TURN_SLIGHT_MAX_DEG = 60;
const TURN_SHARP_MIN_DEG = 150;
const MANEUVER_MERGE_M = 6; // これより近い曲がり角は1つにまとめる
const NEAR_MANEUVER_M = 8; // これより近ければ「◯m先」を付けずに言う
const BACKTRACK_PENALTY_M = 3; // 前回より手前の区間に戻りにくくする重み

// 移動のしにくさ(A*のコスト)。直線距離の推定が過大にならないよう、係数は1以上・加算は0以上にする。
const STEPS_COST_FACTOR = 1.5;
const STEPS_COST_EXTRA_M = 5;
const ESCALATOR_COST_FACTOR = 1.2;
const ESCALATOR_COST_EXTRA_M = 5;
const ELEVATOR_COST_BASE_M = 40; // 待ち時間の目安
const ELEVATOR_COST_PER_LEVEL_M = 5;
const CROSSING_COST_EXTRA_M = 10; // 信号待ちの目安

// ---------- 階の表記 ----------

// OSMの階 → 日本語(0→"1階", 1→"2階", -1→"地下1階")。小数の階(中間階)は近い階で言う。
export function levelLabel(level) {
  const l = Math.round(Number(level) || 0);
  return l >= 0 ? `${l + 1}階` : `地下${-l}階`;
}

// 画面の階("B5"〜"10F") → OSMの階("1F"→0, "2F"→1, "B1"→-1)。不正なら null。
export function floorLabelToLevel(label) {
  if (typeof label !== "string") return null;
  const b = label.match(/^B(\d+)$/);
  if (b) return -Number(b[1]);
  const f = label.match(/^(\d+)F$/);
  if (f && Number(f[1]) >= 1) return Number(f[1]) - 1;
  return null;
}

// OSMの階 → 画面の階(0→"1F", -1→"B1")
export function levelToFloorLabel(level) {
  const l = Math.round(Number(level) || 0);
  return l >= 0 ? `${l + 1}F` : `B${-l}`;
}

// ---------- 地理計算(渋谷付近の平面近似。1.5km圏では誤差は無視できる) ----------

export function distanceMeters(lat1, lng1, lat2, lng2) {
  const dLat = (lat2 - lat1) * DEG;
  const dLng = (lng2 - lng1) * DEG;
  const a = Math.sin(dLat / 2) ** 2 + Math.cos(lat1 * DEG) * Math.cos(lat2 * DEG) * Math.sin(dLng / 2) ** 2;
  return EARTH_RADIUS_M * 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
}

export function bearingDegrees(lat1, lng1, lat2, lng2) {
  const y = Math.sin((lng2 - lng1) * DEG) * Math.cos(lat2 * DEG);
  const x = Math.cos(lat1 * DEG) * Math.sin(lat2 * DEG) -
    Math.sin(lat1 * DEG) * Math.cos(lat2 * DEG) * Math.cos((lng2 - lng1) * DEG);
  return ((Math.atan2(y, x) / DEG) + 360) % 360;
}

function normalizeDeg(d) {
  let x = d % 360;
  if (x > 180) x -= 360;
  if (x <= -180) x += 360;
  return x;
}

function makeProjection(lat0, lng0) {
  const kx = Math.cos(lat0 * DEG) * DEG * EARTH_RADIUS_M;
  const ky = DEG * EARTH_RADIUS_M;
  return {
    toXY: (lat, lng) => [(lng - lng0) * kx, (lat - lat0) * ky],
    toLatLng: (x, y) => ({ lat: lat0 + y / ky, lng: lng0 + x / kx }),
  };
}

function closestOnSegment(px, py, ax, ay, bx, by) {
  const dx = bx - ax;
  const dy = by - ay;
  const len2 = dx * dx + dy * dy;
  const t = len2 === 0 ? 0 : Math.max(0, Math.min(1, ((px - ax) * dx + (py - ay) * dy) / len2));
  const qx = ax + t * dx;
  const qy = ay + t * dy;
  return { t, qx, qy, d: Math.hypot(px - qx, py - qy) };
}

function levelMatches(level, la, lb) {
  if (level == null) return true;
  const lo = Math.min(la, lb) - LEVEL_MATCH_TOLERANCE;
  const hi = Math.max(la, lb) + LEVEL_MATCH_TOLERANCE;
  return level >= lo && level <= hi;
}

// ---------- グラフ ----------

export function edgeCost(type, lengthM, la, lb) {
  switch (type) {
    case EDGE_TYPE.STEPS: return lengthM * STEPS_COST_FACTOR + STEPS_COST_EXTRA_M;
    case EDGE_TYPE.ESCALATOR: return lengthM * ESCALATOR_COST_FACTOR + ESCALATOR_COST_EXTRA_M;
    case EDGE_TYPE.ELEVATOR: return lengthM + ELEVATOR_COST_BASE_M + ELEVATOR_COST_PER_LEVEL_M * Math.abs(lb - la);
    case EDGE_TYPE.CROSSING: return lengthM + CROSSING_COST_EXTRA_M;
    default: return lengthM;
  }
}

/**
 * graph.json(scripts/build_route_graph.mjs の出力)を計算用の型付き配列にする。
 * 隣接リストは有向の「弧」: 弧番号 = エッジ番号*2 + 向き(0: a→b, 1: b→a)。一方通行は a→b のみ。
 */
export function decodeGraph(json) {
  if (!json || !Array.isArray(json.nodes) || !Array.isArray(json.edges)) {
    throw new Error("route: グラフデータの形式が正しくありません");
  }
  const stride = json.edgeStride || 6;
  const nodeCount = json.nodes.length / 2;
  const edgeCount = json.edges.length / stride;
  if (!Number.isInteger(nodeCount) || !Number.isInteger(edgeCount)) {
    throw new Error("route: グラフデータの長さが正しくありません");
  }
  const center = Array.isArray(json.center) ? json.center : [json.nodes[0], json.nodes[1]];
  const proj = makeProjection(center[0], center[1]);
  const lat = new Float64Array(nodeCount);
  const lng = new Float64Array(nodeCount);
  const x = new Float64Array(nodeCount);
  const y = new Float64Array(nodeCount);
  for (let i = 0; i < nodeCount; i += 1) {
    lat[i] = json.nodes[i * 2];
    lng[i] = json.nodes[i * 2 + 1];
    const [px, py] = proj.toXY(lat[i], lng[i]);
    x[i] = px;
    y[i] = py;
  }
  const ea = new Int32Array(edgeCount);
  const eb = new Int32Array(edgeCount);
  const etype = new Uint8Array(edgeCount);
  const ela = new Float64Array(edgeCount);
  const elb = new Float64Array(edgeCount);
  const eflags = new Uint8Array(edgeCount);
  const elen = new Float64Array(edgeCount);
  const ecost = new Float64Array(edgeCount);
  const degree = new Int32Array(nodeCount + 1);
  for (let e = 0; e < edgeCount; e += 1) {
    const o = e * stride;
    const a = json.edges[o];
    const b = json.edges[o + 1];
    if (!(a >= 0 && a < nodeCount && b >= 0 && b < nodeCount)) throw new Error("route: エッジのノード番号が範囲外です");
    ea[e] = a;
    eb[e] = b;
    etype[e] = json.edges[o + 2];
    ela[e] = json.edges[o + 3];
    elb[e] = json.edges[o + 4];
    eflags[e] = json.edges[o + 5];
    elen[e] = Math.hypot(x[b] - x[a], y[b] - y[a]);
    ecost[e] = edgeCost(etype[e], elen[e], ela[e], elb[e]);
    degree[a] += 1;
    if (!(eflags[e] & EDGE_FLAG_ONEWAY)) degree[b] += 1;
  }
  const adjStart = new Int32Array(nodeCount + 1);
  for (let i = 0; i < nodeCount; i += 1) adjStart[i + 1] = adjStart[i] + degree[i];
  const fill = adjStart.slice(0, nodeCount);
  const adjArc = new Int32Array(adjStart[nodeCount]);
  for (let e = 0; e < edgeCount; e += 1) {
    adjArc[fill[ea[e]]++] = e * 2;
    if (!(eflags[e] & EDGE_FLAG_ONEWAY)) adjArc[fill[eb[e]]++] = e * 2 + 1;
  }
  return {
    version: json.version || null, nodeCount, edgeCount, proj,
    lat, lng, x, y, ea, eb, etype, ela, elb, eflags, elen, ecost, adjStart, adjArc,
  };
}

/**
 * いちばん近い「歩ける道」(エッジ)に吸着する。階が分かっていれば同じ階の道を優先する。
 * @returns {{edge:number, t:number, lat:number, lng:number, level:number, distanceM:number} | null}
 */
export function snapToGraph(graph, point, { level = null, maxDistanceM = SNAP_MAX_M } = {}) {
  if (!point || !Number.isFinite(point.lat) || !Number.isFinite(point.lng)) return null;
  const [px, py] = graph.proj.toXY(point.lat, point.lng);
  let best = null;
  let bestScore = Infinity;
  for (let e = 0; e < graph.edgeCount; e += 1) {
    if (graph.etype[e] === EDGE_TYPE.ELEVATOR) continue; // エレベーターのかごの中には吸着しない
    const a = graph.ea[e];
    const b = graph.eb[e];
    const c = closestOnSegment(px, py, graph.x[a], graph.y[a], graph.x[b], graph.y[b]);
    if (c.d > maxDistanceM) continue;
    // 階段・エスカレーターは「吸着する点での階」で比べる(地下3階→地下1階のエスカレーターの下端に、
    // 地下1階にいる人を吸着させない)
    const hereLevel = graph.ela[e] + (graph.elb[e] - graph.ela[e]) * c.t;
    const score = c.d + (levelMatches(level, hereLevel, hereLevel) ? 0 : LEVEL_MISMATCH_PENALTY_M);
    if (score < bestScore) {
      bestScore = score;
      best = { edge: e, t: c.t, qx: c.qx, qy: c.qy, distanceM: c.d };
    }
  }
  if (!best) return null;
  const ll = graph.proj.toLatLng(best.qx, best.qy);
  const e = best.edge;
  return {
    edge: e, t: best.t, lat: ll.lat, lng: ll.lng,
    level: graph.ela[e] + (graph.elb[e] - graph.ela[e]) * best.t,
    distanceM: best.distanceM,
  };
}

// 最小ヒープ(値の小さい順)。同じノードが何度入ってもよい(取り出し時に確定済みなら読み飛ばす)。
class MinHeap {
  constructor() { this.keys = []; this.vals = []; }
  get size() { return this.keys.length; }
  push(val, key) {
    const k = this.keys;
    const v = this.vals;
    let i = k.length;
    k.push(key);
    v.push(val);
    while (i > 0) {
      const p = (i - 1) >> 1;
      if (k[p] <= key) break;
      k[i] = k[p]; v[i] = v[p];
      i = p;
    }
    k[i] = key; v[i] = val;
  }
  pop() {
    const k = this.keys;
    const v = this.vals;
    const top = v[0];
    const lastK = k.pop();
    const lastV = v.pop();
    if (k.length) {
      let i = 0;
      const n = k.length;
      for (;;) {
        const l = i * 2 + 1;
        if (l >= n) break;
        const r = l + 1;
        const c = r < n && k[r] < k[l] ? r : l;
        if (k[c] >= lastK) break;
        k[i] = k[c]; v[i] = v[c];
        i = c;
      }
      k[i] = lastK; v[i] = lastV;
    }
    return top;
  }
}

function arcTarget(graph, arc) {
  const e = arc >> 1;
  return arc & 1 ? graph.ea[e] : graph.eb[e];
}

/**
 * from から to までの歩行ルート(A*)。
 * @param from {lat, lng, level?}  現在地(levelは自分で選んだ階。不明ならnull)
 * @param to   {lat, lng, level?, name?} 目的地
 * @returns {{ok:true, route:object} | {ok:false, reason:'no_start'|'no_goal'|'unreachable'}}
 */
export function findRoute(graph, from, to, opts = {}) {
  const start = snapToGraph(graph, from, { level: from.level ?? null, maxDistanceM: opts.maxSnapM });
  if (!start) return { ok: false, reason: "no_start" };
  const goal = snapToGraph(graph, to, { level: to.level ?? null, maxDistanceM: opts.maxSnapM });
  if (!goal) return { ok: false, reason: "no_goal" };

  const N = graph.nodeCount;
  const GOAL = N; // 目的地(道の途中の点)を仮のノード番号Nとして扱う
  const gScore = new Float64Array(N + 1).fill(Infinity);
  const via = new Int32Array(N + 1).fill(-1); // そのノードに来た弧(-2=出発点から直接)
  const closed = new Uint8Array(N + 1);
  const heap = new MinHeap();
  const [gx, gy] = graph.proj.toXY(goal.lat, goal.lng);
  const h = (v) => (v === GOAL ? 0 : Math.hypot(graph.x[v] - gx, graph.y[v] - gy));
  const se = start.edge;
  const fe = goal.edge;
  const oneway = (e) => (graph.eflags[e] & EDGE_FLAG_ONEWAY) !== 0;
  let goalFrom = -1; // 目的地に入った元のノード(-2=出発点から同じ道の上を直接)

  const relaxGoal = (u, cost) => {
    if (cost < gScore[GOAL]) {
      gScore[GOAL] = cost;
      goalFrom = u;
      heap.push(GOAL, cost);
    }
  };
  const relax = (v, cost, arc) => {
    if (cost < gScore[v]) {
      gScore[v] = cost;
      via[v] = arc;
      heap.push(v, cost + h(v));
    }
  };

  if (se === fe) {
    if (goal.t >= start.t) relaxGoal(-2, (goal.t - start.t) * graph.ecost[se]);
    else if (!oneway(se)) relaxGoal(-2, (start.t - goal.t) * graph.ecost[se]);
  }
  relax(graph.eb[se], (1 - start.t) * graph.ecost[se], -2);
  if (!oneway(se)) relax(graph.ea[se], start.t * graph.ecost[se], -3);

  while (heap.size) {
    const u = heap.pop();
    if (closed[u]) continue;
    closed[u] = 1;
    if (u === GOAL) break;
    const gu = gScore[u];
    if (u === graph.ea[fe]) relaxGoal(u, gu + goal.t * graph.ecost[fe]);
    if (u === graph.eb[fe] && !oneway(fe)) relaxGoal(u, gu + (1 - goal.t) * graph.ecost[fe]);
    for (let i = graph.adjStart[u]; i < graph.adjStart[u + 1]; i += 1) {
      const arc = graph.adjArc[i];
      const v = arcTarget(graph, arc);
      if (closed[v]) continue;
      relax(v, gu + graph.ecost[arc >> 1], arc);
    }
  }
  if (!Number.isFinite(gScore[GOAL])) return { ok: false, reason: "unreachable" };

  // 経路の復元: 出発点 → ノード列 → 目的地
  const nodePath = [];
  const arcPath = [];
  if (goalFrom !== -2) {
    let v = goalFrom;
    for (;;) {
      nodePath.push(v);
      const arc = via[v];
      if (arc < 0) { arcPath.push(arc); break; }
      arcPath.push(arc);
      v = arc & 1 ? graph.eb[arc >> 1] : graph.ea[arc >> 1];
    }
    nodePath.reverse();
    arcPath.reverse();
  }
  return { ok: true, route: assembleRoute(graph, start, goal, nodePath, arcPath, goalFrom, to, from) };
}

function assembleRoute(graph, start, goal, nodePath, arcPath, goalFrom, destination, from) {
  const points = [{ lat: start.lat, lng: start.lng, level: start.level }];
  const segments = [];
  const pushPoint = (lat, lng, level, e, fromLevel) => {
    const prev = points[points.length - 1];
    segments.push({
      type: graph.etype[e], fromLevel, toLevel: level,
      guessed: (graph.eflags[e] & EDGE_FLAG_LEVEL_GUESSED) !== 0,
      lengthM: distanceMeters(prev.lat, prev.lng, lat, lng),
    });
    points.push({ lat, lng, level });
  };
  if (goalFrom === -2) {
    pushPoint(goal.lat, goal.lng, goal.level, start.edge, start.level);
  } else {
    const se = start.edge;
    const first = nodePath[0];
    const firstLevel = first === graph.ea[se] ? graph.ela[se] : graph.elb[se];
    pushPoint(graph.lat[first], graph.lng[first], firstLevel, se, start.level);
    for (let i = 1; i < nodePath.length; i += 1) {
      const arc = arcPath[i];
      const e = arc >> 1;
      const forward = (arc & 1) === 0;
      const fromLevel = forward ? graph.ela[e] : graph.elb[e];
      const toLevel = forward ? graph.elb[e] : graph.ela[e];
      const v = nodePath[i];
      pushPoint(graph.lat[v], graph.lng[v], toLevel, e, fromLevel);
    }
    const fe = goal.edge;
    const last = nodePath[nodePath.length - 1];
    const lastLevel = last === graph.ea[fe] ? graph.ela[fe] : graph.elb[fe];
    pushPoint(goal.lat, goal.lng, goal.level, fe, lastLevel);
  }
  assignFloors(segments, points, startFloorFor(start.level, from.level));
  const cum = [0];
  for (const s of segments) cum.push(cum[cum.length - 1] + s.lengthM);
  const route = {
    points,
    segments,
    cum,
    totalM: cum[cum.length - 1],
    destination: {
      lat: destination.lat, lng: destination.lng,
      // level = 案内に沿って階を直していった場合に、着いた時点で画面の階が指しているはずの階(到着判定用)
      level: segments[segments.length - 1].toFloor,
      placeLevel: destination.level ?? null,
      name: destination.name || "",
    },
    startSnapM: start.distanceM,
    goalSnapM: goal.distanceM,
  };
  route.maneuvers = buildManeuvers(route);
  return route;
}

// ---------- 「実際の階」の推定 ----------
// OSMの level は建物ごとの相対値で、渋谷では描いた人によって 0始まり/1始まり が混ざり、
// 谷地形のため「坂の上の道路=別の建物の4階」も普通にある(2026-09-26 実データで確認)。
// そのまま使うと「3階へ進む→1階へ進む」のような嘘の案内が出るため、次の方針で推定する:
//   - 地下(level<0)は数え方がそろっている(B1=-1)ので、そのまま信じる
//   - 地上どうし(level>=0)の階の変化は、階段・エスカレーター・エレベーターの「両端の差」だけを
//     数える(両端の階が推測のもの=EDGE_FLAG_LEVEL_GUESSEDは数えない)。道と建物の境目で数字が
//     飛ぶだけのもの・坂の通路(描き方の違いで向きも怪しい)は無視する
//   - 地上の推定が0(1階)を下回ったら0に止める(地下に入るのは level<0 のデータがあるときだけ)
// 意図的な簡略化: 絶対値が怪しいときは floorChangeText の「上の階へ/下の階へ」で言う
// (本格対応はビル単位の階の対応表、または国交省の歩行空間ネットワークデータで補正する)。

function startFloorFor(rawLevel, userLevel) {
  if (rawLevel < 0) return rawLevel;
  return Math.max(0, Number.isFinite(userLevel) ? userLevel : 0);
}

function nextFloor(floor, rawFrom, rawTo, isChange) {
  if (rawTo < 0 || rawFrom < 0) return rawTo;
  if (!isChange) return floor;
  return Math.max(0, floor + (rawTo - rawFrom));
}

function assignFloors(segments, points, startFloor) {
  let floor = startFloor;
  let rawPrev = segments.length ? segments[0].fromLevel : 0;
  points[0].floor = floor;
  segments.forEach((seg, i) => {
    if (Math.abs(seg.fromLevel - rawPrev) > 0.01) floor = nextFloor(floor, rawPrev, seg.fromLevel, false);
    seg.fromFloor = floor;
    if (Math.abs(seg.toLevel - seg.fromLevel) > 0.01) {
      floor = nextFloor(floor, seg.fromLevel, seg.toLevel, isVerticalType(seg.type) && !seg.guessed);
    }
    seg.toFloor = floor;
    points[i + 1].floor = floor;
    rawPrev = seg.toLevel;
  });
}

// ---------- 案内(曲がり角・階の移動・横断歩道) ----------

const VIA_LABEL = Object.freeze({ escalator: "エスカレーター", steps: "階段", elevator: "エレベーター" });

const VIA_NEUTRAL_TEXT = Object.freeze({ escalator: "エスカレーターに乗る", steps: "階段を通る", elevator: "エレベーターに乗る" });

// 「エスカレーターで2階へ」「階段で地下1階へ」「エレベーターで3階へ」(手段が分からない坂・通路は「2階へ進む」)。
// 行き先の階が推定できないとき(toLevel=null)は向きだけ言う:「階段で下の階へ」「エスカレーターで上の階へ」。
// 向きも怪しいとき(direction=null)は「階段を通る」「エスカレーターに乗る」だけ言う(嘘の上下を言わない)。
export function floorChangeText(via, toLevel, direction = null) {
  const label = VIA_LABEL[via];
  if (toLevel == null) {
    if (direction !== "up" && direction !== "down") return VIA_NEUTRAL_TEXT[via] || "";
    const where = direction === "up" ? "上の階へ" : "下の階へ";
    return label ? `${label}で${where}` : where;
  }
  return label ? `${label}で${levelLabel(toLevel)}へ` : `${levelLabel(toLevel)}へ進む`;
}

// 距離の言い方: 100m未満は5m単位、それ以上は10m単位、1km以上はkm
export function formatDistance(m) {
  const v = Math.max(0, m);
  if (v >= 1000) return `${(v / 1000).toFixed(1)}km`;
  if (v >= 100) return `${Math.round(v / 10) * 10}m`;
  return `${Math.max(5, Math.round(v / 5) * 5)}m`;
}

function pointAtAlong(route, along) {
  const { points, cum } = route;
  const d = Math.max(0, Math.min(route.totalM, along));
  let i = 0;
  while (i < cum.length - 2 && cum[i + 1] < d) i += 1;
  const segLen = cum[i + 1] - cum[i];
  const t = segLen > 0 ? (d - cum[i]) / segLen : 0;
  const a = points[i];
  const b = points[i + 1] || a;
  return { lat: a.lat + (b.lat - a.lat) * t, lng: a.lng + (b.lng - a.lng) * t };
}

function isVerticalType(type) {
  return type === EDGE_TYPE.STEPS || type === EDGE_TYPE.ESCALATOR || type === EDGE_TYPE.ELEVATOR;
}

function chainVia(segments, from, to) {
  let via = null;
  for (let s = from; s <= to; s += 1) {
    const t = segments[s].type;
    if (t === EDGE_TYPE.ELEVATOR) return "elevator";
    if (t === EDGE_TYPE.ESCALATOR) via = "escalator";
    else if (t === EDGE_TYPE.STEPS && via !== "escalator") via = "steps";
  }
  return via || "walk";
}

function turnLabel(delta) {
  const side = delta > 0 ? "右" : "左";
  const a = Math.abs(delta);
  if (a < TURN_SLIGHT_MAX_DEG) return `斜め${side}`;
  if (a >= TURN_SHARP_MIN_DEG) return `大きく${side}`;
  return side;
}

const KIND_ORDER = Object.freeze({ floor: 0, turn: 1, crossing: 2, arrive: 3 });
const LEVEL_EPS = 0.01;

// 階の移動に関わる区間か(階段等で実際に上下する/推定の階が変わる/区間の入口で推定の階が変わる)
function isFloorSegment(segments, i) {
  const seg = segments[i];
  const prevFloor = i > 0 ? segments[i - 1].toFloor : seg.fromFloor;
  const rawChange = isVerticalType(seg.type) && Math.abs(seg.toLevel - seg.fromLevel) > LEVEL_EPS;
  return rawChange || Math.abs(seg.toFloor - seg.fromFloor) > LEVEL_EPS || Math.abs(seg.fromFloor - prevFloor) > LEVEL_EPS;
}

/**
 * 経路上の「案内すべき地点」を順に並べる。
 *   floor:    階の移動(連続する階段・エスカレーター・エレベーターは1つにまとめ、行き先の階を言う。
 *             行き先の階が推定できないときは direction(up/down) だけ持つ)
 *   turn:     曲がり角(前後8mの向きの差が35度以上)
 *   crossing: 横断歩道
 *   arrive:   到着
 */
export function buildManeuvers(route) {
  const { segments, points, cum } = route;
  const out = [];
  const inChain = new Uint8Array(points.length);
  let s = 0;
  while (s < segments.length) {
    if (!isFloorSegment(segments, s)) { s += 1; continue; }
    let end = s;
    while (end + 1 < segments.length && (isFloorSegment(segments, end + 1) || isVerticalType(segments[end + 1].type))) end += 1;
    const before = s > 0 ? segments[s - 1].toFloor : segments[s].fromFloor;
    const after = segments[end].toFloor;
    const via = chainVia(segments, s, end);
    let sureDelta = 0;
    let guessedMove = false;
    for (let k = s; k <= end; k += 1) {
      const x = segments[k];
      if (!isVerticalType(x.type)) continue;
      if (x.guessed) guessedMove = guessedMove || Math.abs(x.toLevel - x.fromLevel) > LEVEL_EPS;
      else sureDelta += x.toLevel - x.fromLevel;
    }
    let maneuver = null;
    if (Math.round(after) !== Math.round(before)) {
      maneuver = { toLevel: after, direction: after > before ? "up" : "down" };
    } else if (via !== "walk" && Math.abs(sureDelta) >= 0.5) {
      maneuver = { toLevel: null, direction: sureDelta > 0 ? "up" : "down" };
    } else if (via !== "walk" && guessedMove) {
      maneuver = { toLevel: null, direction: null };
    }
    if (maneuver) {
      out.push({ kind: "floor", index: s, alongM: cum[s], endAlongM: cum[end + 1], via, fromLevel: before, ...maneuver });
      for (let p = s; p <= end + 1; p += 1) inChain[p] = 1;
    }
    s = end + 1;
  }

  let lastTurnAlong = -Infinity;
  for (let i = 1; i < points.length - 1; i += 1) {
    if (inChain[i]) continue;
    const isCrossingStart = segments[i].type === EDGE_TYPE.CROSSING && segments[i - 1].type !== EDGE_TYPE.CROSSING;
    let turn = null;
    if (segments[i - 1].lengthM > 0.5 && segments[i].lengthM > 0.5) {
      const back = pointAtAlong(route, cum[i] - TURN_SMOOTH_M);
      const ahead = pointAtAlong(route, cum[i] + TURN_SMOOTH_M);
      const p = points[i];
      const delta = normalizeDeg(bearingDegrees(p.lat, p.lng, ahead.lat, ahead.lng) - bearingDegrees(back.lat, back.lng, p.lat, p.lng));
      if (Math.abs(delta) >= TURN_MIN_DEG && cum[i] - lastTurnAlong >= MANEUVER_MERGE_M) turn = delta;
    }
    if (turn !== null) {
      out.push({ kind: "turn", index: i, alongM: cum[i], label: turnLabel(turn), crossing: isCrossingStart });
      lastTurnAlong = cum[i];
    } else if (isCrossingStart) {
      out.push({ kind: "crossing", index: i, alongM: cum[i] });
    }
  }
  out.push({ kind: "arrive", index: points.length - 1, alongM: route.totalM });
  out.sort((a, b) => a.alongM - b.alongM || KIND_ORDER[a.kind] - KIND_ORDER[b.kind]);
  return out;
}

// 案内地点までの距離つきの案内文(「20m先を右」「エスカレーターで2階へ」「あと80mで到着」)
export function maneuverText(m, distanceM) {
  const near = distanceM < NEAR_MANEUVER_M;
  const ahead = `${formatDistance(distanceM)}先`;
  switch (m.kind) {
    case "floor": {
      const text = floorChangeText(m.via, m.toLevel, m.direction);
      return near ? text : `${ahead}、${text}`;
    }
    case "turn": {
      const cross = m.crossing ? "、横断歩道を渡る" : "";
      return near ? `${m.label}へ${cross}` : `${ahead}を${m.label}${cross}`;
    }
    case "crossing":
      return near ? "横断歩道を渡る" : `${ahead}で横断歩道を渡る`;
    default:
      return distanceM < ARRIVAL_M ? "もうすぐ到着" : `あと${formatDistance(distanceM)}で到着`;
  }
}

export function remainingText(remainingM) {
  const minutes = Math.max(1, Math.round(remainingM / WALK_M_PER_MIN));
  return `残り${formatDistance(remainingM)}・約${minutes}分`;
}

/**
 * 今の位置(と自分で選んだ階)から、案内に必要なものを全部まとめて返す。
 * @param route  findRoute(...).route
 * @param pos    {lat, lng} 自分の今の位置(端末の中だけで使う)
 * @param opts   { level: 自分で選んだ階(不明ならnull), progressIndex: 前回の返り値のprogressIndex }
 */
export function guide(route, pos, { level = null, progressIndex = 0 } = {}) {
  const { points, segments, cum } = route;
  const proj = makeProjection(pos.lat, pos.lng);
  let best = { i: 0, t: 0, d: Infinity, score: Infinity };
  for (let i = 0; i < segments.length; i += 1) {
    const a = points[i];
    const b = points[i + 1];
    const [ax, ay] = proj.toXY(a.lat, a.lng);
    const [bx, by] = proj.toXY(b.lat, b.lng);
    const c = closestOnSegment(0, 0, ax, ay, bx, by);
    const seg = segments[i];
    let score = c.d;
    if (!levelMatches(level, seg.fromFloor, seg.toFloor)) score += LEVEL_MISMATCH_PENALTY_M;
    if (i < progressIndex - 1) score += BACKTRACK_PENALTY_M;
    if (score < best.score) best = { i, t: c.t, d: c.d, score };
  }
  const along = cum[best.i] + best.t * (cum[best.i + 1] - cum[best.i]);
  const remainingM = Math.max(0, route.totalM - along);
  const dest = route.destination;
  const end = points[points.length - 1];
  // 目的地の点そのもの、または経路の終点(目的地に一番近い歩ける道の上)のどちらかに15m以内
  const toDest = Math.min(
    distanceMeters(pos.lat, pos.lng, dest.lat, dest.lng),
    distanceMeters(pos.lat, pos.lng, end.lat, end.lng),
  );
  const sameFloorAsDest = level == null || dest.level == null || Math.abs(level - dest.level) < LEVEL_MATCH_TOLERANCE;
  const arrived = toDest <= ARRIVAL_M && sameFloorAsDest;

  let waypoint = null;
  for (let j = best.i + 1; j < points.length; j += 1) {
    if (cum[j] - along >= WAYPOINT_MIN_AHEAD_M) { waypoint = points[j]; break; }
  }
  if (!waypoint) waypoint = { lat: dest.lat, lng: dest.lng, level: dest.level };

  const next = route.maneuvers.find((m) => (m.kind === "floor" ? m.endAlongM > along + 0.5 : m.alongM > along + 0.5 || m.kind === "arrive"));
  const distanceM = next ? Math.max(0, next.alongM - along) : remainingM;
  const seg = segments[best.i];
  return {
    arrived,
    offRoute: best.d >= OFF_ROUTE_M,
    distanceToRouteM: best.d,
    alongM: along,
    remainingM,
    progressIndex: best.i,
    routeLevel: seg.fromFloor + (seg.toFloor - seg.fromFloor) * best.t,
    waypoint,
    bearingDeg: bearingDegrees(pos.lat, pos.lng, waypoint.lat, waypoint.lng),
    instruction: next
      ? { kind: next.kind, text: arrived ? "到着しました" : maneuverText(next, distanceM), distanceM }
      : { kind: "arrive", text: "到着しました", distanceM: 0 },
    // 階の移動が近い(行き先の階が分かっている)ときだけ「◯階に着いた」ボタンを出す。
    // endPoint = 階の移動が終わる地点(着いたボタンを押したら、GPSが動くまでここにいるものとして案内を続ける)
    floorPrompt: next && next.kind === "floor" && next.toLevel != null && distanceM <= FLOOR_PROMPT_M
      ? { toLevel: next.toLevel, via: next.via, endPoint: pointAtAlong(route, next.endAlongM) }
      : null,
  };
}

// 3D渋谷に線を描くための [lng, lat] 列
export function routeLineCoordinates(route) {
  return route.points.map((p) => [p.lng, p.lat]);
}

// ---------- データの読み込み(ブラウザ用。fetchは呼び出し側から渡せる) ----------

const PLACE_ID_RE = /^[a-z0-9-]{1,40}$/;

// places.json の中身を検査して、使える形(id/name/lat/lng/level)だけにする
export function parsePlaces(json) {
  if (!json || !Array.isArray(json.places)) throw new Error("route: 場所データの形式が正しくありません");
  return json.places
    .filter((p) => p && PLACE_ID_RE.test(p.id) && typeof p.name === "string" && Number.isFinite(p.lat) && Number.isFinite(p.lng))
    .map((p) => Object.freeze({
      id: p.id, name: p.name, lat: p.lat, lng: p.lng,
      level: Number.isFinite(p.level) ? p.level : 0, hint: typeof p.hint === "string" ? p.hint : "",
    }));
}

const dataCache = new Map();
function cached(key, loader) {
  if (!dataCache.has(key)) {
    const p = loader().catch((err) => { dataCache.delete(key); throw err; });
    dataCache.set(key, p);
  }
  return dataCache.get(key);
}

async function fetchJson(url, fetchFn) {
  const res = await fetchFn(url);
  if (!res.ok) throw new Error(`route: ${url} の読み込みに失敗しました(${res.status})`);
  return res.json();
}

// baseUrl: Web版は ""(同じオリジン)。iOSアプリは本番WorkerのURL(画面はアプリ内、データは本番から取る)。
export function loadRouteGraph(baseUrl = "", fetchFn = globalThis.fetch) {
  return cached(`graph:${baseUrl}`, async () => decodeGraph(await fetchJson(`${baseUrl}/route/graph.json?v=${ROUTE_GRAPH_VERSION}`, fetchFn)));
}

export function loadPlaces(baseUrl = "", fetchFn = globalThis.fetch) {
  return cached(`places:${baseUrl}`, async () => parsePlaces(await fetchJson(`${baseUrl}/route/places.json?v=${PLACES_VERSION}`, fetchFn)));
}
