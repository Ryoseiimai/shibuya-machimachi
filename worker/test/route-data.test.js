// 配信している道のデータ(worker/public/route/graph.json・places.json)の検査。
// 版の印(route.jsの定数)とのズレ、サイズ、定番スポットどうしが全部たどり着けること、
// 渋谷駅の地下↔地上で階の移動を案内することを、実データで確かめる。
import { test } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import {
  ROUTE_GRAPH_VERSION,
  PLACES_VERSION,
  decodeGraph,
  parsePlaces,
  snapToGraph,
  findRoute,
  guide,
} from "../public/assets/js/route.js";
import worker from "../src/index.js";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const ROUTE_DIR = path.join(__dirname, "..", "public", "route");
const graphText = fs.readFileSync(path.join(ROUTE_DIR, "graph.json"), "utf8");
const graphJson = JSON.parse(graphText);
const placesJson = JSON.parse(fs.readFileSync(path.join(ROUTE_DIR, "places.json"), "utf8"));
const graph = decodeGraph(graphJson);
const places = parsePlaces(placesJson);
const byId = Object.fromEntries(places.map((p) => [p.id, p]));

const MAX_GRAPH_BYTES = 3 * 1024 * 1024;
const MAX_PLACE_SNAP_M = 25;
// 渋谷駅東側の地下3階の通路(OSM: level=-3 の歩道。E2Eの「階の移動」画面と同じ地点)
const B3_POINT = { lat: 35.658588, lng: 139.702834, level: -3 };

test("graph.json / places.json の版の印が route.js の定数と一致する(1年キャッシュの取り違え防止)", () => {
  assert.equal(graphJson.version, ROUTE_GRAPH_VERSION, "graph.jsonを作り直したら ROUTE_GRAPH_VERSION も更新する");
  assert.equal(placesJson.version, PLACES_VERSION, "places.jsonを変えたら version と PLACES_VERSION を上げる");
});

test("graph.json: 出典(OSM/ODbL)付き・3MB以内・座標は小数6桁以内", () => {
  assert.match(graphJson.attribution, /OpenStreetMap contributors/);
  assert.match(graphJson.attribution, /ODbL/);
  assert.ok(graphText.length < MAX_GRAPH_BYTES, `サイズ ${graphText.length}`);
  assert.ok(graph.nodeCount > 1000 && graph.edgeCount > 1000, `規模 ${graph.nodeCount}/${graph.edgeCount}`);
  const tooPrecise = graphJson.nodes.find((v) => (String(v).split(".")[1] || "").length > 6);
  assert.equal(tooPrecise, undefined);
});

test("places.json: 10件以上・IDの重複なし・全部が歩ける道の近くにある", () => {
  assert.ok(places.length >= 10 && places.length <= 15, `件数 ${places.length}`);
  assert.equal(new Set(places.map((p) => p.id)).size, places.length);
  assert.equal(places.length, placesJson.places.length, "形式の不正な場所が混ざっていない");
  for (const p of places) {
    const s = snapToGraph(graph, p, { level: p.level });
    assert.ok(s && s.distanceM <= MAX_PLACE_SNAP_M, `${p.name} は道から${s && s.distanceM}m`);
  }
});

test("定番スポットどうしは、どの組み合わせでも道順が見つかる", () => {
  for (const a of places) {
    for (const b of places) {
      if (a === b) continue;
      const r = findRoute(graph, a, b);
      assert.equal(r.ok, true, `${a.name} → ${b.name}: ${r.reason}`);
    }
  }
});

test("ハチ公像 → モヤイ像: 歩ける道に沿った数百mの道順で、最初の矢印は目的地への直線とは限らない", () => {
  const r = findRoute(graph, byId.hachiko, byId.moyai);
  assert.equal(r.ok, true);
  assert.ok(r.route.totalM > 150 && r.route.totalM < 700, `距離 ${r.route.totalM}`);
  const g = guide(r.route, byId.hachiko, { level: 0 });
  assert.equal(g.arrived, false);
  assert.equal(g.offRoute, false);
  assert.match(g.instruction.text, /m先|へ|到着/);
});

test("渋谷駅の地下3階 → ハチ公像: 階の移動(地下→地上)を「◯◯で◯階へ」と案内する", () => {
  const r = findRoute(graph, B3_POINT, byId.hachiko);
  assert.equal(r.ok, true);
  const floors = r.route.maneuvers.filter((m) => m.kind === "floor");
  assert.ok(floors.length >= 1, "階の移動の案内がある");
  assert.ok(floors.some((m) => m.toLevel === 0), "最後は1階(地上)へ");
  const first = guide(r.route, B3_POINT, { level: -3 });
  assert.match(first.instruction.text, /(エスカレーター|階段|エレベーター)で(地下\d+|\d+)階へ/);
});

test("GET /go は場所モードの画面(アプリのHTML)を返す", async () => {
  const res = await worker.fetch(new Request("https://shibuya-machimachi.example/go"), {});
  assert.equal(res.status, 200);
  const html = await res.text();
  assert.match(html, /id="screen-place-select"/);
  assert.match(html, /id="place-route-mount"/);
  assert.match(html, /id="route-toggle-btn"/);
});
