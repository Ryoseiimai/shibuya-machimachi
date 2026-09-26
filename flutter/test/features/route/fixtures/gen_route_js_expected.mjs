// route.js（Web 版）で実データの全ペアを計算し、Dart 移植との突き合わせ用の期待値を書き出す。
import fs from "node:fs";
import path from "node:path";
// 使い方（repo のルートで）: node flutter/test/features/route/fixtures/gen_route_js_expected.mjs "$PWD" flutter/test/features/route/fixtures/route_js_expected.json
// graph.json・places.json・route.js を変えたら作り直す（route_data_test.dart が版の印の一致も見る）。
const repo = process.argv[2];
const mod = await import(path.join(repo, "worker/public/assets/js/route.js"));
const graph = mod.decodeGraph(JSON.parse(fs.readFileSync(path.join(repo, "worker/public/route/graph.json"), "utf8")));
const places = mod.parsePlaces(JSON.parse(fs.readFileSync(path.join(repo, "worker/public/route/places.json"), "utf8")));
const r6 = (x) => (x == null ? null : Math.round(x * 1e6) / 1e6);
const r3 = (x) => (x == null ? null : Math.round(x * 1e3) / 1e3);
function summarize(from, to, fromLevel) {
  const r = mod.findRoute(graph, from, to);
  if (!r.ok) return { ok: false, reason: r.reason };
  const route = r.route;
  const probes = [];
  // 経路上の点（始点・途中の各点の少し手前）と、経路から少し横にずれた点で guide を比べる
  const idxs = new Set([0]);
  const n = route.points.length;
  for (let k = 1; k <= 4; k++) idxs.add(Math.min(n - 1, Math.floor((n - 1) * k / 4)));
  for (const i of [...idxs].sort((a, b) => a - b)) {
    const p = route.points[i];
    const q = route.points[Math.max(0, i - 1)];
    const pos = { lat: (p.lat * 3 + q.lat) / 4 + 0.00005, lng: (p.lng * 3 + q.lng) / 4 };
    const level = Math.round(p.floor);
    const g = mod.guide(route, pos, { level, progressIndex: 0 });
    probes.push({
      lat: pos.lat, lng: pos.lng, level,
      text: g.instruction.text, kind: g.instruction.kind, arrived: g.arrived, offRoute: g.offRoute,
      remainingM: r3(g.remainingM), bearingDeg: r3(g.bearingDeg), progressIndex: g.progressIndex,
      floorPrompt: g.floorPrompt ? { toLevel: g.floorPrompt.toLevel, via: g.floorPrompt.via } : null,
      remainingText: mod.remainingText(g.remainingM),
    });
  }
  return {
    ok: true,
    totalM: r3(route.totalM),
    pointCount: n,
    destinationLevel: route.destination.level,
    maneuvers: route.maneuvers.map((m) => ({
      kind: m.kind, index: m.index, alongM: r3(m.alongM), via: m.via ?? null, toLevel: m.toLevel ?? null,
      direction: m.direction ?? null, label: m.label ?? null, crossing: m.crossing ?? false,
    })),
    probes,
  };
}
const pairs = [];
for (const a of places) for (const b of places) {
  if (a === b) continue;
  pairs.push({ from: a.id, to: b.id, ...summarize(a, b) });
}
const B3 = { lat: 35.658588, lng: 139.702834, level: -3 };
const hachiko = places.find((p) => p.id === "hachiko");
const b3 = { from: "B3_POINT", to: "hachiko", ...summarize(B3, hachiko) };
const b3guide = mod.guide(mod.findRoute(graph, B3, hachiko).route, B3, { level: -3 });
b3.firstText = b3guide.instruction.text;
fs.writeFileSync(process.argv[3], JSON.stringify({ generatedFrom: "worker/public/assets/js/route.js", graphVersion: mod.ROUTE_GRAPH_VERSION, pairs, b3 }));
console.log("pairs", pairs.length, "ok", pairs.filter((p) => p.ok).length, "b3", b3.firstText);
