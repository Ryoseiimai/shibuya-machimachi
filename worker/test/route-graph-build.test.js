// 道のグラフを作る前処理(scripts/build_route_graph.mjs)の単体テスト。
// Overpass APIの結果と同じ形の小さな合成データで、歩けない道の除外・階の展開・階移動エッジ
// (階段・エスカレーター・エレベーター)・一方通行・つながっていない島の除外・形の間引きを確かめる。
import { test } from "node:test";
import assert from "node:assert/strict";
import {
  parseLevels,
  defaultLevel,
  isWalkableWay,
  classifyWay,
  buildGraph,
  encodeGraph,
  buildOverpassQuery,
  EDGE_TYPES,
  EDGE_FLAG_ONEWAY,
  EDGE_FLAG_LEVEL_GUESSED,
} from "../../scripts/build_route_graph.mjs";

const CENTER = { lat: 35.658, lng: 139.7016 };
const M_PER_DEG_LAT = 6371000 * (Math.PI / 180);
const M_PER_DEG_LNG = M_PER_DEG_LAT * Math.cos((CENTER.lat * Math.PI) / 180);

// 合成のOverpass結果を組み立てる: nodes = { id: [north, east] }, ways = [{ id, nodes: [...], tags }]
function osm(nodes, ways, extraElements = []) {
  const coord = (id) => {
    const [n, e] = nodes[id];
    return { lat: CENTER.lat + n / M_PER_DEG_LAT, lon: CENTER.lng + e / M_PER_DEG_LNG };
  };
  return {
    osm3s: { timestamp_osm_base: "2026-09-26T00:00:00Z" },
    elements: [
      ...ways.map((w) => ({ type: "way", id: w.id, nodes: w.nodes, geometry: w.nodes.map(coord), tags: w.tags })),
      ...extraElements,
    ],
  };
}

function edgesOfType(graph, type) {
  return graph.edges.filter((e) => e.type === type);
}

test("parseLevels: ;区切り・範囲・小数・誤記の,区切りを数値の配列にする", () => {
  assert.deepEqual(parseLevels("0;1"), [0, 1]);
  assert.deepEqual(parseLevels("-2;0;6;10"), [-2, 0, 6, 10]);
  assert.deepEqual(parseLevels("1;0"), [0, 1]);
  assert.deepEqual(parseLevels("0,1"), [0, 1]);
  assert.deepEqual(parseLevels("1-3"), [1, 2, 3]);
  assert.deepEqual(parseLevels("-2--1"), [-2, -1]);
  assert.deepEqual(parseLevels("3.5"), [3.5]);
  assert.deepEqual(parseLevels("abc"), []);
  assert.deepEqual(parseLevels(undefined), []);
});

test("defaultLevel: levelが無い地下道(tunnel + layerがマイナス)だけlayerを階にし、他は地上(0)", () => {
  assert.equal(defaultLevel({ tunnel: "yes", layer: "-1" }), -1);
  assert.equal(defaultLevel({ location: "underground", layer: "-2" }), -2);
  assert.equal(defaultLevel({ bridge: "yes", layer: "1" }), 0);
  assert.equal(defaultLevel({}), 0);
});

test("isWalkableWay: 私有地・立入禁止・歩行者禁止・高速道路を除き、館内の通路は含める", () => {
  assert.equal(isWalkableWay({ highway: "footway" }), true);
  assert.equal(isWalkableWay({ indoor: "corridor" }), true);
  assert.equal(isWalkableWay({ highway: "steps", conveying: "forward" }), true);
  assert.equal(isWalkableWay({ highway: "motorway" }), false);
  assert.equal(isWalkableWay({ highway: "service", access: "private" }), false);
  assert.equal(isWalkableWay({ highway: "service", access: "no", foot: "yes" }), true);
  assert.equal(isWalkableWay({ highway: "footway", foot: "no" }), false);
  assert.equal(isWalkableWay({ highway: "trunk", tunnel: "yes" }), false);
  assert.equal(isWalkableWay({ building: "yes" }), false);
});

test("classifyWay: エスカレーター(上り/下り専用)・階段・横断歩道・エレベーターを見分ける", () => {
  assert.deepEqual(classifyWay({ highway: "steps", conveying: "forward" }), { kind: "escalator", oneway: "forward" });
  assert.deepEqual(classifyWay({ highway: "steps", conveying: "backward" }), { kind: "escalator", oneway: "backward" });
  assert.deepEqual(classifyWay({ highway: "steps", conveying: "yes" }), { kind: "escalator", oneway: null });
  assert.deepEqual(classifyWay({ highway: "steps" }), { kind: "steps", oneway: null });
  assert.equal(classifyWay({ highway: "footway", footway: "crossing" }).kind, "crossing");
  assert.equal(classifyWay({ highway: "elevator" }).kind, "elevator");
  assert.equal(classifyWay({ highway: "residential", oneway: "yes" }).oneway, null, "車道の一方通行は歩行者には関係ない");
  assert.equal(classifyWay({ highway: "footway", oneway: "yes" }).oneway, "forward");
});

test("buildGraph: 階段の両端の階を、つながる道のlevelから決めて階移動エッジにする", () => {
  // 地上の道 1-2(levelなし=0) → 階段 2-3(level 0;1、向きは描いた順とは逆) → 2階のデッキ 3-4(level 1)
  const data = osm(
    { 1: [0, 0], 2: [0, 50], 3: [0, 60], 4: [0, 120] },
    [
      { id: 10, nodes: [1, 2], tags: { highway: "footway" } },
      { id: 11, nodes: [3, 2], tags: { highway: "steps", level: "0;1" } },
      { id: 12, nodes: [3, 4], tags: { highway: "footway", level: "1" } },
    ],
  );
  const g = buildGraph(data);
  const steps = edgesOfType(g, EDGE_TYPES.STEPS);
  assert.equal(steps.length, 1);
  const [s] = steps;
  const levelAt = (nodeIndex) => (s.a === nodeIndex ? s.la : s.lb);
  const ground = g.nodes.findIndex((n) => Math.abs(n.lng - (CENTER.lng + 50 / M_PER_DEG_LNG)) < 1e-6);
  const deck = g.nodes.findIndex((n) => Math.abs(n.lng - (CENTER.lng + 60 / M_PER_DEG_LNG)) < 1e-6);
  assert.equal(levelAt(ground), 0, "道の側は0(地上)");
  assert.equal(levelAt(deck), 1, "デッキの側は1(2階)");
  assert.equal(s.flags & EDGE_FLAG_LEVEL_GUESSED, 0, "はっきりしたlevelの道につながるので推測ではない");
  assert.equal(g.stats.floorChangeEdges, 1);
});

test("buildGraph: 上り専用エスカレーター(conveying=forward)は一方通行のエッジになる", () => {
  const data = osm(
    { 1: [0, 0], 2: [0, 50], 3: [0, 60], 4: [0, 120] },
    [
      { id: 10, nodes: [1, 2], tags: { highway: "footway", level: "0" } },
      { id: 11, nodes: [2, 3], tags: { highway: "steps", conveying: "forward", level: "0;1" } },
      { id: 12, nodes: [3, 4], tags: { highway: "footway", level: "1" } },
      // 片道だけだと強連結でなくなるので、戻り用の階段も置く
      { id: 13, nodes: [4, 1], tags: { highway: "steps", level: "0;1" } },
    ],
  );
  const g = buildGraph(data);
  const esc = edgesOfType(g, EDGE_TYPES.ESCALATOR);
  assert.equal(esc.length, 1);
  assert.equal(esc[0].flags & EDGE_FLAG_ONEWAY, EDGE_FLAG_ONEWAY);
  assert.equal(esc[0].la, 0);
  assert.equal(esc[0].lb, 1);
});

test("buildGraph: エレベーターの点は、つながる道の階ごとに分けてエレベーターのエッジで結ぶ", () => {
  // 地下1階の通路 1-2 と 地上の道 2-3 が、エレベーターの点2を共有している
  const data = osm(
    { 1: [0, 0], 2: [0, 40], 3: [0, 90] },
    [
      { id: 10, nodes: [1, 2], tags: { highway: "footway", indoor: "yes", level: "-1" } },
      { id: 11, nodes: [2, 3], tags: { highway: "footway" } },
    ],
    [{ type: "node", id: 2, lat: CENTER.lat, lon: CENTER.lng + 40 / M_PER_DEG_LNG, tags: { highway: "elevator", level: "-1;0" } }],
  );
  const g = buildGraph(data);
  const elevators = edgesOfType(g, EDGE_TYPES.ELEVATOR);
  assert.equal(elevators.length, 1);
  assert.deepEqual([elevators[0].la, elevators[0].lb].sort(), [-1, 0]);
  assert.equal(g.nodes.length, 4, "エレベーターの点が階ごとに2つに分かれる");
});

test("buildGraph: 歩けない道(私有地)とつながっていない島は入らず、まっすぐな道の途中の点は間引く", () => {
  const data = osm(
    { 1: [0, 0], 2: [0, 25], 3: [0, 50], 4: [0, 75], 5: [0, 100], 6: [300, 0], 7: [300, 50], 8: [0, 150] },
    [
      { id: 10, nodes: [1, 2, 3, 4, 5], tags: { highway: "residential" } }, // 一直線に5点
      { id: 11, nodes: [6, 7], tags: { highway: "footway" } }, // 離れた島
      { id: 12, nodes: [5, 8], tags: { highway: "service", access: "private" } },
    ],
  );
  const g = buildGraph(data);
  assert.equal(g.edges.length, 1, "一直線の道は1本のエッジに間引かれる");
  assert.equal(g.nodes.length, 2);
  assert.ok(g.nodes.every((n) => n.lat < CENTER.lat + 100 / M_PER_DEG_LAT), "300m北の島は入らない");
});

test("buildGraph: 渋谷駅から半径1.6kmより外の点は切り落とす", () => {
  const data = osm(
    { 1: [0, 0], 2: [0, 1000], 3: [0, 2000] },
    [{ id: 10, nodes: [1, 2, 3], tags: { highway: "footway" } }],
  );
  const g = buildGraph(data);
  assert.equal(g.nodes.length, 2);
  assert.ok(g.nodes.every((n) => n.lng < CENTER.lng + 1700 / M_PER_DEG_LNG));
});

test("encodeGraph: 座標は小数6桁、版の印は中身のハッシュ、出典はOSM(ODbL)", () => {
  const data = osm({ 1: [0, 0], 2: [0, 33.3333] }, [{ id: 10, nodes: [1, 2], tags: { highway: "footway" } }]);
  const encoded = encodeGraph(buildGraph(data), { osmBase: "2026-09-26T00:00:00Z" });
  assert.equal(encoded.format, "shibuya-machimachi-route-graph/1");
  assert.match(encoded.version, /^[0-9a-f]{10}$/);
  assert.match(encoded.attribution, /OpenStreetMap contributors/);
  assert.match(encoded.attribution, /ODbL/);
  for (const v of encoded.nodes) assert.ok(String(v).split(".")[1].length <= 6, `小数6桁以内: ${v}`);
  assert.equal(encoded.edges.length, 6);
  assert.equal(encodeGraph(buildGraph(data)).version, encoded.version, "同じ中身なら同じ版の印");
});

test("buildOverpassQuery: 渋谷駅まわりの矩形で、歩ける道・館内の通路・エスカレーター・エレベーターを取る", () => {
  const q = buildOverpassQuery();
  assert.match(q, /\[bbox:35\.64\d*,139\.68\d*,35\.67\d*,139\.71\d*\]/);
  assert.match(q, /footway\|/);
  assert.match(q, /way\["indoor"="corridor"\]/);
  assert.match(q, /way\["conveying"\]/);
  assert.match(q, /node\["highway"="elevator"\]/);
  assert.doesNotMatch(q, /motorway/);
});
