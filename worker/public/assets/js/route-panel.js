// 渋谷マチマチ 道順案内の画面部品(場所モード・人モード共通)。
// route.js(経路計算・純粋関数)を使って、次の経由点への矢印・次の案内文・残りの道のり・
// 「今いる階」ボタン(1タップで直せる)・到着表示を描く。
//
// 位置情報の扱い: 自分の位置・目的地・経路はこの端末の中だけで使い、ネットワークには送らない
// (道のデータ /route/graph.json を読むだけ)。人モードの「相手の位置」は、app.js が
// サーバーから届いた距離・方角と自分のGPSから画面内だけで近似したもの(SECURITY.md参照)。
//
// 使い方:
//   const panel = mountRoutePanel(el, { dataBaseUrl, onLevelChange, onRoute, onArrive, note });
//   panel.setSelf(lat, lng); panel.setHeading(deg); panel.setLevel(level);
//   panel.setTarget({ lat, lng, level, name });   // null で案内をやめる

// route.js は自分と同じ版の印(?v=)で読む(/assets/* は1時間キャッシュのため、古い版と混ざらないように)
const VERSION_QUERY = new URL(import.meta.url).search;
const routeModPromise = import(new URL(`./route.js${VERSION_QUERY}`, import.meta.url).href);

const REPLAN_MIN_INTERVAL_MS = 3000; // 再計算は最短でも3秒おき(GPSのぶれで毎秒計算し直さない)
// 「◯階に着いた」を押した後は、GPSがこれ以上動くまで「階の移動が終わった地点」にいるものとして案内する
// (地下や館内ではGPSがほぼ更新されないため。動いたら本物のGPSに戻す)
const VIRTUAL_POSITION_RELEASE_M = 15;
const TARGET_MOVE_REPLAN_M = 20; // 目的地(相手)がこれ以上動いたら計算し直す
const AREA_CENTER = Object.freeze({ lat: 35.658, lng: 139.7016 }); // worker/src/constants.js と同じ
const AREA_RADIUS_M = 1500;
const FLOOR_LABELS = ["B5", "B4", "B3", "B2", "B1", "1F", "2F", "3F", "4F", "5F", "6F", "7F", "8F", "9F", "10F"];
const ARROW_PATH = "M12 2 L20 20 L12 15.5 L4 20 Z";

const REASON_TEXT = Object.freeze({
  no_start: "近くに歩ける道が見つかりません(渋谷駅から1.5km以内で使えます)",
  no_goal: "目的地の近くに歩ける道が見つかりません",
  unreachable: "道順が見つかりませんでした",
});

// 日本語を文節の途中で改行しないよう、句読点の後ろで区切った「かたまり」ごとに inline-block の span にする
// (画面の幅に収まらないときだけ、かたまりの境目で折り返す)。phrases は文字列か文字列の配列。
function setPhrases(node, phrases) {
  const parts = Array.isArray(phrases) ? phrases : splitPhrases(String(phrases || ""));
  node.textContent = "";
  for (const part of parts) {
    if (!part) continue;
    const span = document.createElement("span");
    span.className = "phrase";
    span.textContent = part;
    node.appendChild(span);
  }
}

function splitPhrases(text) {
  const out = [];
  let buf = "";
  for (const ch of text) {
    buf += ch;
    if (ch === "、" || ch === "。" || ch === ")" || ch === "）") { out.push(buf); buf = ""; }
  }
  if (buf) out.push(buf);
  return out;
}

function el(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text != null) node.textContent = text;
  return node;
}

function buildDom(container) {
  const card = el("div", "card route-card");
  const head = el("div", "route-head");
  head.appendChild(el("span", "badge", "道順で案内"));
  const dest = el("div", "route-dest");
  const destName = el("strong", "route-dest-name", "");
  const destFloor = el("span", "route-dest-floor", "");
  dest.appendChild(destName);
  dest.appendChild(destFloor);
  head.appendChild(dest);
  card.appendChild(head);

  const arrowWrap = el("div", "route-arrow-wrap");
  const svgNs = "http://www.w3.org/2000/svg";
  const svg = document.createElementNS(svgNs, "svg");
  svg.setAttribute("viewBox", "0 0 24 24");
  svg.setAttribute("class", "route-arrow");
  svg.setAttribute("aria-hidden", "true");
  svg.setAttribute("fill", "currentColor");
  const path = document.createElementNS(svgNs, "path");
  path.setAttribute("d", ARROW_PATH);
  svg.appendChild(path);
  arrowWrap.appendChild(svg);
  card.appendChild(arrowWrap);

  const instruction = el("div", "route-instruction", "道のデータを読み込んでいます…");
  instruction.setAttribute("aria-live", "polite");
  card.appendChild(instruction);
  const remaining = el("div", "route-remaining", "");
  card.appendChild(remaining);

  const confirm = el("button", "route-floor-confirm", "");
  confirm.type = "button";
  confirm.hidden = true;
  card.appendChild(confirm);

  const floorLabel = el("div", "route-floor-label");
  setPhrases(floorLabel, ["今いる階", "(違ったらタップで直せます)"]);
  card.appendChild(floorLabel);
  const chips = el("div", "floor-chips");
  chips.setAttribute("role", "group");
  chips.setAttribute("aria-label", "今いる階");
  const chipButtons = FLOOR_LABELS.map((label) => {
    const b = el("button", "floor-chip", label);
    b.type = "button";
    b.dataset.floor = label;
    chips.appendChild(b);
    return b;
  });
  card.appendChild(chips);
  const note = el("p", "hint route-note", "");
  card.appendChild(note);
  container.appendChild(card);
  return { card, destName, destFloor, arrowWrap, svg, instruction, remaining, confirm, chips, chipButtons, note };
}

export function mountRoutePanel(container, opts = {}) {
  const dom = buildDom(container);
  const state = {
    self: null, heading: null, level: 0, target: null, virtualSelf: null,
    graph: null, mod: null, loadError: null,
    route: null, planTarget: null, planLevel: null, lastPlanAt: 0, reason: null,
    progressIndex: 0, guidance: null, arrivedNotified: false, destroyed: false,
  };
  setPhrases(dom.note, opts.note || "");

  routeModPromise
    .then((mod) => {
      state.mod = mod;
      return mod.loadRouteGraph(opts.dataBaseUrl || "", opts.fetch || globalThis.fetch.bind(globalThis));
    })
    .then((graph) => {
      state.graph = graph;
      update(true);
    })
    .catch((err) => {
      state.loadError = err;
      console.error(err);
      render();
    });

  function levelFromChip(label) {
    return state.mod ? state.mod.floorLabelToLevel(label) : null;
  }

  function setLevelInternal(level, fromUser) {
    if (!Number.isFinite(level) || level === state.level) return;
    state.level = level;
    if (fromUser && typeof opts.onLevelChange === "function") opts.onLevelChange(level, state.mod.levelToFloorLabel(level));
    update(true); // 階が変わったら、その階から計算し直す
  }

  dom.chipButtons.forEach((b) => {
    b.addEventListener("click", () => {
      const level = levelFromChip(b.dataset.floor);
      if (level != null) setLevelInternal(level, true);
    });
  });
  dom.confirm.addEventListener("click", () => {
    const g = state.guidance;
    if (!g || !g.floorPrompt) return;
    const p = g.floorPrompt.endPoint;
    if (p && state.self) state.virtualSelf = { lat: p.lat, lng: p.lng, gps: { ...state.self } };
    setLevelInternal(Math.round(g.floorPrompt.toLevel), true);
  });

  // 案内に使う「今の位置」: 着いたボタンの直後はGPSが動くまで階の移動の終点、それ以外はGPS
  function currentPosition() {
    const v = state.virtualSelf;
    if (v && state.mod && state.self &&
      state.mod.distanceMeters(v.gps.lat, v.gps.lng, state.self.lat, state.self.lng) < VIRTUAL_POSITION_RELEASE_M) {
      return { lat: v.lat, lng: v.lng };
    }
    state.virtualSelf = null;
    return state.self;
  }

  function outsideArea() {
    return state.mod && state.self &&
      state.mod.distanceMeters(state.self.lat, state.self.lng, AREA_CENTER.lat, AREA_CENTER.lng) > AREA_RADIUS_M;
  }

  function targetMoved() {
    const a = state.planTarget;
    const b = state.target;
    if (!a || !b) return true;
    if ((a.level ?? null) !== (b.level ?? null)) return true;
    return state.mod.distanceMeters(a.lat, a.lng, b.lat, b.lng) > TARGET_MOVE_REPLAN_M;
  }

  function plan(force) {
    const now = Date.now();
    if (!force && now - state.lastPlanAt < REPLAN_MIN_INTERVAL_MS) return false;
    state.lastPlanAt = now;
    const here = currentPosition();
    const from = { lat: here.lat, lng: here.lng, level: state.level };
    const result = state.mod.findRoute(state.graph, from, state.target);
    state.planTarget = { ...state.target };
    state.planLevel = state.level;
    state.progressIndex = 0;
    if (!result.ok) {
      state.route = null;
      state.reason = result.reason;
    } else {
      state.route = result.route;
      state.reason = null;
    }
    if (typeof opts.onRoute === "function") opts.onRoute(state.route);
    return true;
  }

  function update(forcePlan) {
    if (state.destroyed) return;
    state.guidance = null;
    if (!state.graph || !state.self || !state.target || outsideArea()) { render(); return; }
    const levelChanged = state.planLevel !== state.level;
    if (!state.route || levelChanged || targetMoved()) plan(forcePlan || !state.route || levelChanged);
    if (!state.route) { render(); return; }
    let g = state.mod.guide(state.route, currentPosition(), { level: state.level, progressIndex: state.progressIndex });
    if (g.offRoute && !g.arrived && plan(false) && state.route) {
      g = state.mod.guide(state.route, currentPosition(), { level: state.level, progressIndex: 0 });
    }
    state.progressIndex = g.progressIndex;
    state.guidance = g;
    if (g.arrived && !state.arrivedNotified) {
      state.arrivedNotified = true;
      if (typeof opts.onArrive === "function") opts.onArrive();
    }
    if (!g.arrived) state.arrivedNotified = false;
    render();
  }

  function renderArrow() {
    const g = state.guidance;
    if (!g || g.arrived) {
      dom.arrowWrap.classList.add("is-idle");
      return;
    }
    dom.arrowWrap.classList.remove("is-idle");
    // 向きセンサーが無い(heading=null)ときは北が上の矢印になる
    const rel = ((g.bearingDeg - (state.heading ?? 0)) % 360 + 360) % 360;
    dom.svg.style.transform = `rotate(${rel}deg)`;
  }

  let scrolledTo = null;
  function renderChips() {
    const active = state.mod ? state.mod.levelToFloorLabel(state.level) : "1F";
    let activeButton = null;
    dom.chipButtons.forEach((b) => {
      const on = b.dataset.floor === active;
      b.classList.toggle("is-active", on);
      b.setAttribute("aria-pressed", on ? "true" : "false");
      if (on) activeButton = b;
    });
    // 選ばれている階のボタンが横スクロールの外に隠れないよう、真ん中あたりまで寄せる(ページ自体は動かさない)
    if (activeButton && scrolledTo !== active && dom.chips.clientWidth > 0) {
      scrolledTo = active;
      dom.chips.scrollLeft = Math.max(0, activeButton.offsetLeft - dom.chips.offsetLeft - (dom.chips.clientWidth - activeButton.offsetWidth) / 2);
    }
  }

  function render() {
    if (state.destroyed) return;
    const mod = state.mod;
    const t = state.target;
    dom.destName.textContent = t ? t.name || "目的地" : "";
    dom.destFloor.textContent = t && mod && Number.isFinite(t.level) ? ` ${mod.levelLabel(t.level)}` : "";
    renderChips();
    dom.confirm.hidden = true;
    dom.card.classList.remove("is-arrived");
    let text;
    let sub = "";
    if (state.loadError) text = "道のデータを読み込めませんでした。通信を確かめて開き直してください";
    else if (!state.graph) text = "道のデータを読み込んでいます…";
    else if (!state.self) text = "現在地を取得しています…(位置情報を許可してください)";
    else if (outsideArea()) text = "渋谷エリア(駅から1.5km)の外なので、道順は出せません";
    else if (!t) text = opts.emptyText || "行き先を選んでください";
    else if (!state.route) text = REASON_TEXT[state.reason] || "道順を計算しています…";
    else {
      const g = state.guidance;
      text = g.arrived ? "到着しました！" : g.instruction.text;
      sub = g.arrived ? "" : mod.remainingText(g.remainingM);
      if (g.arrived) dom.card.classList.add("is-arrived");
      dom.card.classList.toggle("is-floor-change", !g.arrived && g.instruction.kind === "floor");
      if (!g.arrived && g.floorPrompt) {
        dom.confirm.hidden = false;
        dom.confirm.textContent = `${mod.levelLabel(g.floorPrompt.toLevel)}に着いた`;
      }
    }
    setPhrases(dom.instruction, text);
    dom.remaining.textContent = sub;
    renderArrow();
  }

  return {
    setSelf(lat, lng) {
      if (!Number.isFinite(lat) || !Number.isFinite(lng)) return;
      state.self = { lat, lng };
      update(false);
    },
    setHeading(deg) {
      state.heading = Number.isFinite(deg) ? deg : null;
      renderArrow();
    },
    setLevel(level) {
      if (!Number.isFinite(level) || level === state.level) return;
      state.level = level;
      update(true);
    },
    getLevel() {
      return state.level;
    },
    setTarget(target) {
      const changedDest = !state.target || !target || state.target.name !== target.name;
      state.target = target && Number.isFinite(target.lat) && Number.isFinite(target.lng) ? { ...target } : null;
      if (changedDest) { state.route = null; state.arrivedNotified = false; state.virtualSelf = null; }
      update(changedDest);
    },
    getRoute() {
      return state.route;
    },
    destroy() {
      state.destroyed = true;
      dom.card.remove();
    },
  };
}
