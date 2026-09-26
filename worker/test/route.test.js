// 道順案内エンジン(worker/public/assets/js/route.js)の単体テスト。
// 渋谷駅付近に「北へ◯m・東へ◯m」で置いた小さな合成グラフで、最短経路・階をまたぐ経路・到達不能・
// 次の経由点(矢印の向き)・案内文・再計算(経路から外れた判定)・到着判定を確かめる。
import { test } from "node:test";
import assert from "node:assert/strict";
import {
  EDGE_TYPE,
  EDGE_FLAG_ONEWAY,
  EDGE_FLAG_LEVEL_GUESSED,
  OFF_ROUTE_M,
  ARRIVAL_M,
  decodeGraph,
  snapToGraph,
  findRoute,
  guide,
  levelLabel,
  floorLabelToLevel,
  levelToFloorLabel,
  floorChangeText,
  formatDistance,
  remainingText,
  parsePlaces,
  routeLineCoordinates,
} from "../public/assets/js/route.js";

const CENTER = { lat: 35.658, lng: 139.7016 };
const M_PER_DEG_LAT = 6371000 * (Math.PI / 180);
const M_PER_DEG_LNG = M_PER_DEG_LAT * Math.cos((CENTER.lat * Math.PI) / 180);

// 渋谷駅から北へnorthM・東へeastM の点
function at(northM, eastM, level = 0) {
  return { lat: CENTER.lat + northM / M_PER_DEG_LAT, lng: CENTER.lng + eastM / M_PER_DEG_LNG, level };
}

// points: [[north, east], ...] / edges: [[a, b, type?, la?, lb?, flags?], ...]
function makeGraph(points, edges) {
  const nodes = [];
  for (const [n, e] of points) {
    const p = at(n, e);
    nodes.push(p.lat, p.lng);
  }
  const flat = [];
  for (const [a, b, type = EDGE_TYPE.WALK, la = 0, lb = la, flags = 0] of edges) flat.push(a, b, type, la, lb, flags);
  return decodeGraph({ version: "test", center: [CENTER.lat, CENTER.lng], edgeStride: 6, nodes, edges: flat });
}

function mustRoute(graph, from, to) {
  const r = findRoute(graph, from, to);
  assert.equal(r.ok, true, `経路が見つかる(reason=${r.reason})`);
  return r.route;
}

test("階の表記: OSMの階(0=1階) ⇔ 画面の階(1F/B1) ⇔ 日本語", () => {
  assert.equal(levelLabel(0), "1階");
  assert.equal(levelLabel(1), "2階");
  assert.equal(levelLabel(-1), "地下1階");
  assert.equal(floorLabelToLevel("1F"), 0);
  assert.equal(floorLabelToLevel("10F"), 9);
  assert.equal(floorLabelToLevel("B3"), -3);
  assert.equal(floorLabelToLevel("0F"), null);
  assert.equal(floorLabelToLevel("x"), null);
  assert.equal(levelToFloorLabel(0), "1F");
  assert.equal(levelToFloorLabel(-2), "B2");
});

test("案内文: 階の移動は手段と行き先の階を言う(分からないときは上下だけ/手段だけ)", () => {
  assert.equal(floorChangeText("escalator", 1), "エスカレーターで2階へ");
  assert.equal(floorChangeText("steps", -1), "階段で地下1階へ");
  assert.equal(floorChangeText("elevator", 2), "エレベーターで3階へ");
  assert.equal(floorChangeText("walk", 0), "1階へ進む");
  assert.equal(floorChangeText("steps", null, "down"), "階段で下の階へ");
  assert.equal(floorChangeText("escalator", null, null), "エスカレーターに乗る");
  assert.equal(formatDistance(23), "25m");
  assert.equal(formatDistance(3), "5m");
  assert.equal(formatDistance(247), "250m");
  assert.equal(formatDistance(1234), "1.2km");
  assert.equal(remainingText(240), "残り240m・約3分");
});

test("decodeGraph: 長さを計算し、一方通行は逆向きの弧を作らない", () => {
  const g = makeGraph([[0, 0], [0, 100], [100, 100]], [[0, 1], [1, 2, EDGE_TYPE.ESCALATOR, 0, 1, EDGE_FLAG_ONEWAY]]);
  assert.equal(g.nodeCount, 3);
  assert.equal(g.edgeCount, 2);
  assert.ok(Math.abs(g.elen[0] - 100) < 0.5, `約100m(${g.elen[0]})`);
  // ノード2から出る弧は無い(1→2の一方通行だけ)
  assert.equal(g.adjStart[3] - g.adjStart[2], 0);
  assert.throws(() => decodeGraph({ nodes: [1], edges: [] }));
});

test("snapToGraph: いちばん近い道に吸着し、階が分かれば同じ階の道を優先する", () => {
  // 同じ場所に1階の道(0-1)と地下1階の道(2-3)が重なっている駅のような状況
  const g = makeGraph(
    [[0, 0], [0, 100], [2, 0], [2, 100]],
    [[0, 1, EDGE_TYPE.WALK, 0, 0], [2, 3, EDGE_TYPE.WALK, -1, -1]],
  );
  const onGround = snapToGraph(g, at(1, 50), { level: 0 });
  const underground = snapToGraph(g, at(1, 50), { level: -1 });
  assert.equal(onGround.edge, 0);
  assert.equal(underground.edge, 1);
  assert.ok(Math.abs(onGround.t - 0.5) < 0.01);
  assert.equal(snapToGraph(g, at(2000, 0)), null, "遠すぎる点は吸着しない");
});

test("findRoute: 2本の道のうち短い方を選ぶ(A*)", () => {
  // 0→1→3 は約141m(斜め2本)、0→2→3 は遠回り(北に200m上がってから戻る)
  const g = makeGraph(
    [[0, 0], [50, 50], [200, 0], [0, 100]],
    [[0, 1], [1, 3], [0, 2], [2, 3]],
  );
  const route = mustRoute(g, at(0, 0), at(0, 100));
  assert.ok(route.totalM < 150, `短い方(約141m): ${route.totalM}`);
  assert.equal(route.points.length, 3);
  assert.deepEqual(routeLineCoordinates(route).length, 3);
});

test("findRoute: 一方通行のエスカレーターは逆向きに使わない(遠回りの階段を選ぶ)", () => {
  // 1階(0)の道 0-1、上り専用エスカレーター 1→2(0→1)、2階の道 2-3、遠回りの階段 3-4-0
  const g = makeGraph(
    [[0, 0], [0, 50], [0, 60], [0, 110], [80, 60]],
    [
      [0, 1, EDGE_TYPE.WALK, 0, 0],
      [1, 2, EDGE_TYPE.ESCALATOR, 0, 1, EDGE_FLAG_ONEWAY],
      [2, 3, EDGE_TYPE.WALK, 1, 1],
      [3, 4, EDGE_TYPE.STEPS, 1, 0],
      [4, 0, EDGE_TYPE.WALK, 0, 0],
    ],
  );
  const up = mustRoute(g, at(0, 0, 0), at(0, 110, 1));
  assert.ok(up.segments.some((s) => s.type === EDGE_TYPE.ESCALATOR), "上りはエスカレーター");
  const down = mustRoute(g, at(0, 110, 1), at(0, 0, 0));
  assert.ok(!down.segments.some((s) => s.type === EDGE_TYPE.ESCALATOR), "下りでは上り専用エスカレーターを使わない");
  assert.ok(down.segments.some((s) => s.type === EDGE_TYPE.STEPS), "下りは階段");
});

test("findRoute: つながっていない道・遠すぎる出発点は到達不能として理由を返す", () => {
  const g = makeGraph([[0, 0], [0, 100], [300, 0], [300, 100]], [[0, 1], [2, 3]]);
  assert.deepEqual(findRoute(g, at(0, 10), at(300, 90)), { ok: false, reason: "unreachable" });
  assert.equal(findRoute(g, at(3000, 0), at(0, 90)).reason, "no_start");
  assert.equal(findRoute(g, at(0, 10), at(3000, 0)).reason, "no_goal");
});

test("階をまたぐ経路: エスカレーターで上がる区間を「エスカレーターで2階へ」と案内し、近づくと着いたボタンを出す", () => {
  const g = makeGraph(
    [[0, 0], [0, 60], [0, 75], [0, 140]],
    [
      [0, 1, EDGE_TYPE.WALK, 0, 0],
      [1, 2, EDGE_TYPE.ESCALATOR, 0, 1],
      [2, 3, EDGE_TYPE.WALK, 1, 1],
    ],
  );
  const route = mustRoute(g, at(0, 0, 0), at(0, 140, 1));
  const floor = route.maneuvers.find((m) => m.kind === "floor");
  assert.ok(floor, "階の移動の案内がある");
  assert.equal(floor.via, "escalator");
  assert.equal(floor.toLevel, 1);
  assert.equal(route.destination.level, 1);

  const far = guide(route, at(0, 0), { level: 0 });
  assert.match(far.instruction.text, /^60m先、エスカレーターで2階へ$/);
  assert.equal(far.floorPrompt, null);

  const near = guide(route, at(0, 55), { level: 0 });
  assert.equal(near.instruction.text, "エスカレーターで2階へ");
  assert.equal(near.floorPrompt.toLevel, 1);
  assert.equal(near.floorPrompt.via, "escalator");
  // 着いたボタンを押した後に案内を続ける地点 = エスカレーターの上端(東へ75m)
  const top = at(0, 75);
  assert.ok(Math.abs(near.floorPrompt.endPoint.lat - top.lat) < 1e-6 && Math.abs(near.floorPrompt.endPoint.lng - top.lng) < 1e-6);

  // 2階に着いた(階を直した)ら、その先の案内=到着までの案内になる
  const upstairs = guide(route, at(0, 90), { level: 1 });
  assert.equal(upstairs.instruction.kind, "arrive");
  assert.match(upstairs.instruction.text, /到着/);
});

test("階をまたぐ経路: 地上から階段で地下へ下りる区間を「階段で地下1階へ」と案内する", () => {
  const g = makeGraph(
    [[0, 0], [0, 40], [0, 50], [0, 120]],
    [
      [0, 1, EDGE_TYPE.WALK, 0, 0],
      [1, 2, EDGE_TYPE.STEPS, 0, -1],
      [2, 3, EDGE_TYPE.WALK, -1, -1],
    ],
  );
  const route = mustRoute(g, at(0, 0, 0), at(0, 120, -1));
  const floor = route.maneuvers.find((m) => m.kind === "floor");
  assert.equal(floor.via, "steps");
  assert.equal(floor.toLevel, -1);
  assert.equal(guide(route, at(0, 38), { level: 0 }).instruction.text, "階段で地下1階へ");
});

test("地上どうしで数字が飛ぶだけ(建物ごとの階の数え方の違い)では、嘘の階移動を案内しない", () => {
  // 道(0) → 建物の通路(level 3。描いた人の数え方で3になっているだけ) → 道(0)
  const g = makeGraph(
    [[0, 0], [0, 50], [0, 100], [0, 150]],
    [[0, 1, EDGE_TYPE.WALK, 0, 0], [1, 2, EDGE_TYPE.WALK, 3, 3], [2, 3, EDGE_TYPE.WALK, 0, 0]],
  );
  const route = mustRoute(g, at(0, 0, 0), at(0, 150, 0));
  assert.equal(route.maneuvers.filter((m) => m.kind === "floor").length, 0);
  assert.equal(route.destination.level, 0);
});

test("両端の階が推測の階段は、上り/下りを言わず「階段を通る」とだけ案内する", () => {
  const g = makeGraph(
    [[0, 0], [0, 40], [0, 50], [0, 120]],
    [
      [0, 1, EDGE_TYPE.WALK, 0, 0],
      [1, 2, EDGE_TYPE.STEPS, 0, 1, EDGE_FLAG_LEVEL_GUESSED],
      [2, 3, EDGE_TYPE.WALK, 1, 1],
    ],
  );
  const route = mustRoute(g, at(0, 0, 0), at(0, 120, 0));
  const floor = route.maneuvers.find((m) => m.kind === "floor");
  assert.equal(floor.toLevel, null);
  assert.equal(floor.direction, null);
  assert.equal(guide(route, at(0, 38), { level: 0 }).instruction.text, "階段を通る");
});

test("矢印は目的地への直線ではなく、歩ける道に沿った次の経由点を指す", () => {
  // 東へ100m進んでから北へ100m(目的地は北東。直線の方角は約45度だが、まず東(90度)へ進む道)
  const g = makeGraph([[0, 0], [0, 100], [100, 100]], [[0, 1], [1, 2]]);
  const route = mustRoute(g, at(0, 0), at(100, 100));
  const g0 = guide(route, at(0, 0), { level: 0 });
  assert.ok(Math.abs(g0.bearingDeg - 90) < 2, `東を指す: ${g0.bearingDeg}`);
  assert.equal(g0.instruction.kind, "turn");
  assert.equal(g0.instruction.text, "100m先を左");
  assert.ok(Math.abs(g0.remainingM - 200) < 2, `残り約200m: ${g0.remainingM}`);
  // 角を曲がった後は北を指す
  const g1 = guide(route, at(30, 100), { level: 0 });
  assert.ok(Math.abs(g1.bearingDeg - 0) < 2 || Math.abs(g1.bearingDeg - 360) < 2, `北を指す: ${g1.bearingDeg}`);
});

test("経路から25m以上外れたら再計算の合図(offRoute)を出す", () => {
  const g = makeGraph([[0, 0], [0, 200]], [[0, 1]]);
  const route = mustRoute(g, at(0, 0), at(0, 200));
  assert.equal(guide(route, at(10, 100), { level: 0 }).offRoute, false);
  assert.equal(guide(route, at(OFF_ROUTE_M + 5, 100), { level: 0 }).offRoute, true);
  // 外れた位置から計算し直すと、また経路の上(offRoute=false)になる
  const g2 = makeGraph([[0, 0], [0, 200], [60, 100], [0, 100]], [[0, 3], [3, 1], [3, 2]]);
  const rerouted = mustRoute(g2, at(55, 100), at(0, 200));
  assert.equal(guide(rerouted, at(55, 100), { level: 0 }).offRoute, false);
});

test("到着判定: 同じ階で15m以内なら到着、階が違えば到着にしない", () => {
  const g = makeGraph([[0, 0], [0, 100]], [[0, 1, EDGE_TYPE.WALK, 0, 0]]);
  const route = mustRoute(g, at(0, 0, 0), at(0, 100, 0));
  assert.equal(guide(route, at(0, 100 - ARRIVAL_M + 3), { level: 0 }).arrived, true);
  assert.equal(guide(route, at(0, 100 - ARRIVAL_M - 10), { level: 0 }).arrived, false);
  assert.equal(guide(route, at(0, 95), { level: 2 }).arrived, false, "真上の別の階にいるときは到着ではない");
  assert.equal(guide(route, at(0, 95), { level: 0 }).instruction.text, "到着しました");
});

test("parsePlaces: 形式の正しい場所だけを残す(idは英小文字・数字・ハイフン)", () => {
  const places = parsePlaces({
    places: [
      { id: "hachiko", name: "ハチ公像", lat: 35.659, lng: 139.7006, level: 0, hint: "広場" },
      { id: "Bad ID", name: "x", lat: 1, lng: 2 },
      { id: "nolevel", name: "x", lat: 35.6, lng: 139.7 },
      { id: "nan", name: "x", lat: "35", lng: 139.7 },
    ],
  });
  assert.deepEqual(places.map((p) => p.id), ["hachiko", "nolevel"]);
  assert.equal(places[1].level, 0, "階が無ければ地上(0)");
  assert.throws(() => parsePlaces({}));
});
