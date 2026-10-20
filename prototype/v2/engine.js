// Stage Empire v2 규칙 엔진 (SE-069). 스펙: docs/gdd/v2/{run,show,events,rewards}.md
// DOM 없음, 상태와 계산은 전부 정수(run.md I1~I4). 데이터는 createEngine(data) 인자로만 받는다.
// node 봇(bot.mjs)과 브라우저 프로토타입(SE-070)이 이 파일 하나를 함께 쓴다.

export const STREAM = { OFFER: 1, MARKET: 2, DEMAND: 3, EVENT: 4, REWARD: 5, WEATHER: 6 };
export const GRADE_RANK = { S: 0, A: 1, B: 2, C: 3, D: 4 };
const QUEUE_KEYS = ["bar_queue", "toilet_queue", "security", "food_queue", "cleaning", "medical"];
// 결과 리뷰 동점 정렬용 순서 (show.md S6 표 순서)
const LINE_ORDER = ["price_over", "opener", "opener_theme", "sound", "headliner", "theme", "empty_room", "sold_out",
  "bar_queue", "toilet_queue", "security", "event", "base_bonus", "food_queue", "cleaning", "medical"];

// ---------- 정수 규칙 (run.md I2·I3) ----------
export function div(a, b) { return Math.floor(a / b); }
export function scale(x, pct) { return x < 0 ? -div(-x * pct, 100) : div(x * pct, 100); }
export function clamp(x, lo, hi) { return x < lo ? lo : x > hi ? hi : x; }
function ceilDiv(a, b) { return a <= 0 ? 0 : div(a + b - 1, b); }

// ---------- 시드 RNG (run.md #시드-rng) ----------
export function mulberry32(seed) {
  let a = seed | 0;
  const r = {
    next_u32() {
      a = (a + 0x6D2B79F5) | 0;
      let t = Math.imul(a ^ (a >>> 15), 1 | a);
      t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
      return (t ^ (t >>> 14)) >>> 0;
    },
    int(n) { return Math.floor(r.next_u32() * n / 4294967296); },
    range(lo, hi) { return lo + r.int(hi - lo + 1); },
  };
  return r;
}

export function weightedPick(r, w) {
  let total = 0;
  for (const x of w) total += x;
  let x = r.int(total);
  for (let i = 0; i < w.length; i++) {
    if (x < w[i]) return i;
    x -= w[i];
  }
  return w.length - 1;
}

const clone = (o) => JSON.parse(JSON.stringify(o));

export function createEngine(data, opts = {}) {
  const B = data.balance;
  const lastAct = opts.lastAct ?? data.acts.acts.length;
  const ACTS = new Map(data.acts.acts.map((a) => [a.id, a]));
  const VENUES = new Map(data.venues.venues.map((v) => [v.id, v]));
  const ARTISTS = new Map(data.artists.artists.map((a) => [a.id, a]));
  const GENRES = data.artists.genres.map((g) => g.id);
  const GENRE = new Map(data.artists.genres.map((g) => [g.id, g]));
  const STAFF = new Map(data.staff.staff.map((s) => [s.id, s]));
  const FAC = new Map(data.facilities.facilities.map((f) => [f.id, f]));
  const EVENTS = data.events.events;
  const RW = data.rewards;
  const RARITY_IDX = new Map(RW.rarities.map((r, i) => [r.id, i]));

  function stream(runSeed, showIdx, id) {
    const m = B.rng.seed_mix;
    return mulberry32((runSeed + showIdx * m.show_mul + id * m.stream_mul) >>> 0);
  }
  const act = (id) => ACTS.get(id);
  const staffRow = (role, a) => STAFF.get(role)?.by_act.find((r) => r.act === a);
  const facRow = (id, a) => FAC.get(id)?.by_act.find((r) => r.act === a);
  const actVenues = (a) => data.venues.venues.filter((v) => v.act === a);

  // ---------- 수정자 (show.md #수정자-함수) ----------
  function isActive(c) {
    const t = c.duration.type;
    return t === "run" || (t === "uses" && c.left > 0);
  }
  function collectMods(cards) {
    const M = { pct: {}, add: {}, rule: {}, active: [] };
    for (const c of cards) {
      if (!isActive(c)) continue;
      M.active.push(c.uid);
      for (const e of c.effects) {
        if (e.type === "pct" || e.type === "add" || e.type === "rule") {
          M[e.type][e.key] = (M[e.type][e.key] || 0) + e.value;
        }
      }
    }
    return M;
  }
  const mp = (M, key, extra = 0) => clamp(100 + (M.pct[key] || 0) + extra, B.mods.pct_min, B.mods.pct_max);
  const ap = (M, x, key, extra = 0) => div(x * mp(M, key, extra), 100);
  const addv = (M, key) => M.add[key] || 0;
  const rule = (M, key) => M.rule[key] || 0;

  // ---------- 런 ----------
  function newRun(seed) {
    return {
      seed: seed >>> 0, act: 1, show_idx: 0, show_in_act: 0,
      funds: B.start.funds, fame: B.start.fame,
      cards: [], owned_ids: [], next_uid: 1, bankrupt_shields_used: 0,
      result: null, phase: "offer", history: [], pending: null,
    };
  }

  function genOffers(state, A, isGate) {
    const r = stream(state.seed, state.show_idx, STREAM.OFFER);
    if (isGate) {
      const t = clone(A.gate.template);
      t.trend = GENRES[r.int(GENRES.length)];
      return [t];
    }
    const pool = A.offer_templates.filter((t) => t.weight > 0);
    const out = [];
    for (let k = 0; k < A.offers_per_show && pool.length; k++) {
      const i = weightedPick(r, pool.map((t) => t.weight));
      const t = clone(pool[i]);
      pool.splice(i, 1);
      t.trend = GENRES[r.int(GENRES.length)];
      out.push(t);
    }
    return out;
  }

  function genMarket(state, A) {
    const r = stream(state.seed, state.show_idx, STREAM.MARKET);
    const L = data.artists.artists.filter((a) => a.act === state.act).map((a) => a.id);
    const n = L.length, k = Math.min(A.market_size, n);
    for (let i = 0; i < k; i++) {
      const j = i + r.int(n - i);
      [L[i], L[j]] = [L[j], L[i]];
    }
    return L.slice(0, k);
  }

  function staffCost(M, A, role, n) {
    const row = staffRow(role, A.id);
    return ap(M, ap(M, n * row.wage, "cost.staff"), "cost.staff." + role);
  }
  function staffMin(A, role) { return staffRow(role, A.id).min ?? 0; }

  function minPlanCost(state, A, M, offers, market) {
    const vs = actVenues(A.id);
    let venue = Infinity;
    for (const o of offers) {
      for (const v of vs) venue = Math.min(venue, ap(M, div(v.fee * o.venue_fee_pct, 100), "cost.venue"));
    }
    let head = Infinity;
    for (const id of market) head = Math.min(head, ap(M, ARTISTS.get(id).fee, "cost.headliner"));
    let staff = 0;
    for (const role of A.knobs.staff) staff += staffCost(M, A, role, staffMin(A, role));
    return venue + head + staff;
  }

  // ① 제안 + 시장. 개최 불가면 state.result = "no_show".
  function beginShow(state0) {
    const state = clone(state0);
    const A = act(state.act);
    const isGate = state.show_in_act === A.normal_shows;
    const offers = genOffers(state, A, isGate);
    const market = genMarket(state, A);
    const M = collectMods(state.cards);
    const minCost = minPlanCost(state, A, M, offers, market);
    const ctx = { act: A.id, isGate, offers, market, minCost, credit: A.credit_limit };
    state.pending = { ctx };
    if (minCost > state.funds + A.credit_limit) {
      state.result = "no_show";
      state.phase = "over";
    } else {
      state.phase = "plan";
    }
    return state;
  }

  // ---------- 계획 ----------
  function staffMax(A, role, venue, plan) {
    const row = staffRow(role, A.id);
    if (row.max_source === "bar_slots") {
      const booth = facRow("bar_booth", A.id);
      return venue.bar_slots + (booth ? (plan.fac.bar_booth || 0) * booth.staff_slots : 0);
    }
    if (row.max_source === "medical_tent") {
      const tent = facRow("medical_tent", A.id);
      return (plan.fac.medical_tent || 0) * tent.staff_slots;
    }
    return row.max;
  }
  function facMax(A, id) {
    const row = facRow(id, A.id);
    return id === "sound" ? row.grades.length - 1 : row.max;
  }

  // 기본 계획(UI 초기값·봇 시작점): 가장 싼 장소, 시장 첫 아티스트, 최소 인력.
  function defaultPlan(state) {
    const A = act(state.act);
    const { ctx } = state.pending;
    const venue = actVenues(A.id).reduce((a, b) => (b.fee < a.fee ? b : a));
    const plan = {
      offer: 0, theme: ctx.offers[0].trend, venue: venue.id, headliners: [ctx.market[0]], openers: [],
      staff: {}, fac: {}, price: 0, promo: 0,
    };
    for (const role of A.knobs.staff) plan.staff[role] = staffMin(A, role);
    for (const f of A.knobs.facilities) plan.fac[f] = 0;
    return plan;
  }

  function lineupSlots(A, M) {
    return { head: A.lineup.headliner_slots + rule(M, "headliner_slots"), open: A.lineup.opener_slots };
  }

  function cost(M, A, offer, venue, plan) {
    const c = { venue: 0, headliner: 0, opener: 0, staff: {}, facility: {}, promo: 0, total: 0 };
    c.venue = ap(M, div(venue.fee * offer.venue_fee_pct, 100), "cost.venue");
    for (const id of plan.headliners) c.headliner += ap(M, ARTISTS.get(id).fee, "cost.headliner");
    for (const id of plan.openers) c.opener += ap(M, ARTISTS.get(id).fee, "cost.opener");
    let staff = 0, fac = 0;
    for (const role of A.knobs.staff) {
      c.staff[role] = staffCost(M, A, role, plan.staff[role] || 0);
      staff += c.staff[role];
    }
    for (const f of A.knobs.facilities) {
      const row = facRow(f, A.id);
      const base = f === "sound" ? row.grades[plan.fac.sound || 0].cost : (plan.fac[f] || 0) * row.cost;
      c.facility[f] = ap(M, ap(M, base, "cost.facility"), "cost.facility." + f);
      fac += c.facility[f];
    }
    if (A.knobs.promo) c.promo = A.promo_levels[plan.promo || 0].cost;
    c.total = c.venue + c.headliner + c.opener + staff + fac + c.promo;
    return c;
  }

  function validatePlan(state, plan) {
    const A = act(state.act);
    const { ctx } = state.pending;
    const M = collectMods(state.cards);
    const err = [];
    const offer = ctx.offers[plan.offer];
    if (!offer) err.push("offer");
    if (!GENRES.includes(plan.theme)) err.push("theme");
    const venue = VENUES.get(plan.venue);
    if (!venue || venue.act !== A.id) err.push("venue");
    const slots = lineupSlots(A, M);
    const all = [...plan.headliners, ...plan.openers];
    if (plan.headliners.length < 1 || plan.headliners.length > slots.head) err.push("headliners");
    if (plan.openers.length > slots.open) err.push("openers");
    if (new Set(all).size !== all.length || all.some((id) => !ctx.market.includes(id))) err.push("lineup");
    if (venue) {
      for (const role of A.knobs.staff) {
        const n = plan.staff[role] || 0;
        if (n < staffMin(A, role) || n > staffMax(A, role, venue, plan)) err.push("staff." + role);
      }
    }
    for (const f of A.knobs.facilities) {
      const n = plan.fac[f] || 0;
      if (n < 0 || n > facMax(A, f)) err.push("fac." + f);
    }
    if (!(plan.price >= 0 && plan.price < A.price_levels.length)) err.push("price");
    if (A.knobs.promo && !(plan.promo >= 0 && plan.promo < A.promo_levels.length)) err.push("promo");
    if (!err.length && cost(M, A, offer, venue, plan).total > state.funds + A.credit_limit) err.push("budget");
    return err;
  }

  // ---------- 개최 준비 (S1·S2) ----------
  function setup(state, plan, forceVariance) {
    const A = act(state.act);
    const { ctx } = state.pending;
    const M = collectMods(state.cards);
    const offer = ctx.offers[plan.offer];
    const venue = VENUES.get(plan.venue);
    const H = plan.headliners.map((id) => ARTISTS.get(id));
    const O = plan.openers.map((id) => ARTISTS.get(id));
    const booth = facRow("bar_booth", A.id);
    const units = {
      security: (plan.staff.security || 0) + addv(M, "free.security"),
      bar: Math.min((plan.staff.bar || 0) + addv(M, "free.bar"),
        venue.bar_slots + (booth ? (plan.fac.bar_booth || 0) * booth.staff_slots : 0)),
      toilet: venue.toilets + (plan.fac.toilet || 0) + addv(M, "free.toilet"),
      food: (plan.fac.food || 0) + addv(M, "free.food"),
      cleaning: (plan.staff.cleaning || 0) + addv(M, "free.cleaning"),
      medical: (plan.staff.medical || 0) + addv(M, "free.medical"),
    };
    const rowdy = Math.max(...H.map((h) => GENRE.get(h.genre).rowdy_pct));
    const level = A.price_levels[plan.price];
    const dm = B.demand;
    let raw = 0;
    for (const h of H) raw += h.draw;
    for (const o of O) raw += div(o.draw * dm.opener_draw_pct, 100);
    raw += state.fame * dm.fame_draw;
    raw = div(raw * offer.demand_pct, 100);
    const themeMatch = H.some((h) => h.genre === plan.theme);
    if (themeMatch) raw = div(raw * (100 + dm.theme_demand_pct), 100);
    const trendMatch = plan.theme === offer.trend;
    if (trendMatch) raw = div(raw * (100 + dm.trend_demand_pct), 100);
    raw = div(raw * level.demand_pct, 100);
    if (A.knobs.promo) raw = div(raw * (100 + A.promo_levels[plan.promo || 0].demand_pct), 100);
    raw = div(raw * (100 + venue.demand_pct), 100);
    raw = ap(M, raw, "demand");
    raw = ap(M, raw, "demand.genre." + H[0].genre);
    let v;
    if (forceVariance !== undefined) v = forceVariance;
    else v = stream(state.seed, state.show_idx, STREAM.DEMAND).range(-dm.variance_pct, dm.variance_pct);
    const vRoll = v;
    if (rule(M, "demand_floor") > 0) v = Math.max(0, v);
    const demand = div(raw * (100 + v), 100);
    const att = Math.min(demand, venue.capacity);
    return {
      state, A, M, ctx, plan, offer, venue, H, O, units, rowdy, raw, v, vRoll, demand, att,
      price: level.price, themeMatch, trendMatch, soldOut: demand >= venue.capacity,
      cost: cost(M, A, offer, venue, plan),
    };
  }

  // S6 고정 줄: [{seg, key, value}]
  function staticLines(S) {
    const L = B.lines, out = [];
    const push = (seg, key, value) => { if (value !== 0) out.push({ seg, key, value }); };
    const fair = Math.max(...S.H.map((h) => h.fair_price));
    const over = S.price - fair;
    if (over > 0) {
      push("doors", "price_over",
        Math.min(0, Math.max(L.price_over.cap, over * L.price_over.per_unit) + addv(S.M, "pen.price_over")));
    }
    push("doors", "base_bonus", addv(S.M, "sat.base"));
    if (S.A.lineup.opener_slots > 0) {
      if (S.O.length) push("opening", "opener", S.O.reduce((s, o) => s + div(o.skill * L.opener.weight_pct, 100), 0));
      else push("opening", "opener", L.opener.none);
      push("opening", "opener_theme", S.O.filter((o) => o.genre !== S.plan.theme).length * L.opener_off_theme);
    }
    let sound = S.venue.sound + addv(S.M, "line.sound");
    if (S.A.knobs.facilities.includes("sound")) sound += facRow("sound", S.A.id).grades[S.plan.fac.sound || 0].sat;
    push("opening", "sound", sound);
    push("headline", "headliner", scale(Math.max(...S.H.map((h) => h.skill)) - L.headliner.pivot, L.headliner.weight_pct));
    if (S.themeMatch) push("headline", "theme", L.theme_match);
    const fill = div(S.att * 100, S.venue.capacity);
    if (fill < L.empty_room.fill_pct_below) {
      push("headline", "empty_room", Math.max(L.empty_room.cap, -div(L.empty_room.fill_pct_below - fill, L.empty_room.div)));
    }
    if (S.soldOut) push("headline", "sold_out", L.sold_out);
    return out;
  }

  function queuePen(S, k, m) {
    if (S.att === 0) return 0;
    const cfg = B.lines[k];
    const pct = div(m * 100, S.att);
    const p = Math.max(cfg.cap, -div(pct * cfg.weight_pct, 100));
    return Math.min(0, p + addv(S.M, "pen." + k));
  }

  // ---------- 개최 시뮬 (S4) — 구간 단위로 진행, 돌발 카드에서 멈춘다 ----------
  class ShowSim {
    constructor(S, events, shieldCards) {
      this.S = S;
      this.events = events; // 구간 순서로 정렬된 돌발 카드
      this.shieldCards = shieldCards; // [{uid, tag, charges}]
      this.shieldUsed = {};
      this.static = staticLines(S);
      this.units = { ...S.units };
      this.segPct = {};
      this.miss = Object.fromEntries(QUEUE_KEYS.map((k) => [k, 0]));
      this.prevPen = Object.fromEntries(QUEUE_KEYS.map((k) => [k, 0]));
      this.drinks = 0; this.foodServed = 0; this.cum = 0;
      this.evMoney = 0; this.evFame = 0; this.evLines = [];
      this.run = B.satisfaction.base;
      this.mood = []; this.segs = []; this.log = [];
      this.si = 0; this.present = 0; this.segEvents = null; this.pendingEvent = null;
      this.done = false;
    }
    get segments() { return this.S.A.segments; }

    // 다음 박자: {kind:"event", ...} | {kind:"segment", ...} | {kind:"done"}
    advance() {
      if (this.pendingEvent) return { kind: "event", ...this.pendingEvent };
      if (this.done) return { kind: "done" };
      const seg = this.segments[this.si];
      if (this.segEvents === null) {
        this.cum += seg.arrive_pct;
        this.present = div(this.S.att * this.cum, 100);
        this.segEvents = this.events.filter((e) => e.segment === seg.id);
      }
      if (this.segEvents.length) {
        const e = this.segEvents.shift();
        this.pendingEvent = { event: e, seg: seg.id, options: this.options(e, seg) };
        return { kind: "event", ...this.pendingEvent };
      }
      const out = this.finishSegment(seg);
      this.segEvents = null;
      this.si++;
      if (this.si >= this.segments.length) this.done = true;
      return out;
    }

    shieldFor(e) {
      const avail = (c) => c.charges - (this.shieldUsed[c.uid] || 0) > 0;
      return this.shieldCards.find((c) => avail(c) && e.tags.includes(c.tag))
        || this.shieldCards.find((c) => avail(c) && c.tag === "*") || null;
    }

    options(e, seg) {
      const ok = (req) => {
        if (!req) return true;
        if (req === "has_opener") return this.S.O.length > 0;
        if (req === "security_ok") {
          const load = div(this.present * this.S.rowdy * seg.heat_pct, 10000);
          return load <= ap(this.S.M, this.units.security * staffRow("security", this.S.A.id).cover, "cap.security");
        }
        throw new Error("unknown requires " + req);
      };
      const opts = e.choices.filter((c) => ok(c.requires)).map((c) => ({ id: c.id, label: c.label, effects: c.effects }));
      const sh = this.shieldFor(e);
      if (sh) opts.push({ id: "__shield", label: "대비 카드 사용", effects: [], shieldUid: sh.uid });
      return opts;
    }

    choose(choiceId) {
      const p = this.pendingEvent;
      if (!p) throw new Error("no pending event");
      const c = p.options.find((o) => o.id === choiceId);
      if (!c) throw new Error("invalid choice " + choiceId);
      if (c.shieldUid) this.shieldUsed[c.shieldUid] = (this.shieldUsed[c.shieldUid] || 0) + 1;
      for (const ef of c.effects) {
        const v = ef.value;
        if (ef.type === "money") this.evMoney += v >= 0 ? v : -div(-v * mp(this.S.M, "event.money"), 100);
        else if (ef.type === "sat") this.evLines.push({ seg: p.seg, key: "event:" + p.event.id, value: v });
        else if (ef.type === "fame") this.evFame += v;
        else if (ef.type === "seg_pct") this.segPct[ef.key] = (this.segPct[ef.key] || 0) + v;
        else if (ef.type === "seg_add") {
          const u = ef.key.split(".")[1];
          this.units[u] = Math.max(0, this.units[u] + v);
        } else throw new Error("unknown effect " + ef.type);
      }
      this.log.push({ event: p.event.id, seg: p.seg, choice: choiceId });
      this.pendingEvent = null;
    }

    finishSegment(seg) {
      const S = this.S, A = S.A, M = S.M, u = this.units, present = this.present;
      const knobs = A.knobs;
      const n = { seg: seg.id, present };
      // 바
      const barDem = div(present * seg.bar_pct, 100);
      const barCap = ap(M, u.bar * staffRow("bar", A.id).serve, "cap.bar", this.segPct["cap.bar"] || 0);
      const barServed = Math.min(barDem, barCap);
      this.drinks += barServed;
      this.miss.bar_queue += barDem - barServed;
      Object.assign(n, { barDem, barCap, barServed });
      // 화장실
      const toiDem = div(present * seg.toilet_pct, 100);
      const toiCap = ap(M, u.toilet * facRow("toilet", A.id).serve, "cap.toilet", this.segPct["cap.toilet"] || 0);
      const toiMiss = Math.max(0, toiDem - toiCap);
      this.miss.toilet_queue += toiMiss;
      Object.assign(n, { toiDem, toiCap, toiMiss });
      // 푸드 (2막+)
      if (knobs.facilities.includes("food")) {
        const fr = facRow("food", A.id);
        const fDem = div(present * seg.food_pct, 100);
        const fCap = ap(M, u.food * fr.serve, "cap.food", this.segPct["cap.food"] || 0);
        const fServed = Math.min(fDem, fCap);
        this.foodServed += fServed;
        this.miss.food_queue += fDem - fServed;
        Object.assign(n, { foodDem: fDem, foodCap: fCap, foodServed: fServed });
      }
      // 보안
      const load = div(present * S.rowdy * seg.heat_pct, 10000);
      const cover = ap(M, u.security * staffRow("security", A.id).cover, "cap.security");
      const secOver = Math.max(0, load - cover);
      this.miss.security += secOver;
      Object.assign(n, { load, cover, secOver });
      // 의료 (3막+, 헤드라이너 구간)
      if (knobs.staff.includes("medical") && seg.stage === "headliner") {
        const need = div(present * S.rowdy * seg.heat_pct, 10000);
        const mc = ap(M, u.medical * staffRow("medical", A.id).cover, "cap.medical");
        this.miss.medical += Math.max(0, need - mc);
      }
      // 청소 (2막+, 마감 구간)
      if (knobs.staff.includes("cleaning") && this.si === this.segments.length - 1) {
        const trash = this.drinks + this.foodServed;
        this.miss.cleaning = Math.max(0, trash - ap(M, u.cleaning * staffRow("cleaning", A.id).cover, "cap.cleaning"));
      }
      // 이번 구간에 실현되는 줄
      const lines = [...this.static.filter((l) => l.seg === seg.id), ...this.evLines.filter((l) => l.seg === seg.id)];
      for (const k of QUEUE_KEYS) {
        const p = queuePen(S, k, this.miss[k]);
        if (p !== this.prevPen[k]) {
          lines.push({ seg: seg.id, key: k, value: p - this.prevPen[k] });
          this.prevPen[k] = p;
        }
      }
      for (const l of lines) this.run += l.value;
      const mood = clamp(this.run, B.satisfaction.min, B.satisfaction.max);
      this.mood.push(mood);
      n.lines = lines; n.mood = mood;
      this.segs.push(n);
      return { kind: "segment", ...n };
    }

    runAll(chooser) {
      for (;;) {
        const b = this.advance();
        if (b.kind === "done") return this;
        if (b.kind === "event") this.choose(chooser(b, this));
      }
    }

    // 원인별로 합친 줄과 최종 만족도
    summary() {
      const byKey = new Map();
      const addL = (key, value) => byKey.set(key, (byKey.get(key) || 0) + value);
      for (const l of this.static) addL(l.key, l.value);
      for (const l of this.evLines) addL(l.key, l.value);
      for (const k of QUEUE_KEYS) if (this.prevPen[k] !== 0) addL(k, this.prevPen[k]);
      const lines = [...byKey].filter(([, v]) => v !== 0).map(([key, value]) => ({ key, value }));
      const sum = lines.reduce((s, l) => s + l.value, 0);
      const satisfaction = clamp(B.satisfaction.base + sum, B.satisfaction.min, B.satisfaction.max);
      return { lines, satisfaction };
    }
  }

  // ---------- 돌발 카드 일정 (events.md E2) ----------
  function eventWeights(S, base, pool) {
    return pool.map((e) => {
      let w = e.weight;
      for (const m of e.weight_mods || []) {
        if (condition(S, base, e, m)) w = div(w * m.mult_pct, 100);
      }
      return w;
    });
  }
  function condition(S, base, e, m) {
    switch (m.if) {
      case "security_short": return base.miss.security > 0;
      case "toilet_short": return base.miss.toilet_queue > 0;
      case "bar_short": return base.miss.bar_queue > 0;
      case "sold_out": return S.soldOut;
      case "att_ge": return S.att >= m.value;
      case "venue_trait": return S.venue.traits.includes(m.value);
      case "mood_ge": {
        const i = S.A.segments.findIndex((s) => s.id === e.segment);
        return base.mood[i] >= m.value;
      }
      default: throw new Error("unknown condition " + m.if);
    }
  }
  function scheduleEvents(S, base) {
    const A = S.A;
    const n = S.ctx.isGate ? (A.gate.events_per_show ?? A.events_per_show) : A.events_per_show;
    const r = stream(S.state.seed, S.state.show_idx, STREAM.EVENT);
    const pool = EVENTS.filter((e) => e.act.includes(A.id));
    const w = eventWeights(S, base, pool);
    const out = [];
    for (let k = 0; k < n; k++) {
      if (w.reduce((s, x) => s + x, 0) === 0) break;
      const i = weightedPick(r, w);
      out.push(pool[i]);
      pool.splice(i, 1); w.splice(i, 1);
    }
    return sortBySegment(A, out);
  }
  function sortBySegment(A, evs) {
    const idx = (e) => A.segments.findIndex((s) => s.id === e.segment);
    return evs.map((e, i) => [e, i]).sort((a, b) => idx(a[0]) - idx(b[0]) || a[1] - b[1]).map((x) => x[0]);
  }

  function shieldCards(state) {
    const out = [];
    for (const c of state.cards) {
      if (c.duration.type !== "charges" || c.charges <= 0) continue;
      for (const e of c.effects) if (e.type === "shield") out.push({ uid: c.uid, tag: e.tag, charges: c.charges, name: c.name });
    }
    return out;
  }

  // 기준 시뮬(돌발 없음)
  function baseSim(S) { return new ShowSim(S, [], []).runAll(() => { throw new Error("no events"); }); }

  // ---------- 미리보기 (show.md P) ----------
  function preview(state, plan) {
    const S = setup(state, plan, 0);
    const sim = baseSim(S);
    const { lines } = sim.summary();
    const var_ = B.demand.variance_pct;
    const lowRaw = rule(S.M, "demand_floor") > 0 ? S.raw : div(S.raw * (100 - var_), 100);
    const barPctSum = S.A.segments.reduce((s, g) => s + g.bar_pct, 0);
    const per = (n) => (n > 0 ? div(S.att, n) : null);
    return {
      attLow: Math.min(S.venue.capacity, lowRaw),
      attMid: Math.min(S.venue.capacity, S.raw),
      attHigh: Math.min(S.venue.capacity, div(S.raw * (100 + var_), 100)),
      capacity: S.venue.capacity,
      cost: S.cost,
      fundsAfterCost: state.funds - S.cost.total,
      breakEven: ceilDiv((S.cost.total - S.offer.sponsor) * 100, S.price * 100 + barPctSum * S.A.drink_price),
      perStaff: { bar: per(S.units.bar), toilet: per(S.units.toilet), security: per(S.units.security) },
      warnings: lines.filter((l) => l.value <= B.preview.warn_at).map((l) => l),
      positives: lines.filter((l) => l.value > 0).map((l) => l.key),
      trendMatch: S.trendMatch, themeMatch: S.themeMatch,
      units: S.units,
      legal: validatePlan(state, plan).length === 0,
      errors: validatePlan(state, plan),
    };
  }

  // ---------- 개최 시작 (S3) ----------
  // opts.forceVariance: 수요 분산 고정, opts.forceEvents: 돌발 카드 id 목록 고정(빈 배열 = 없음)
  function startShow(state, plan, o = {}) {
    const err = validatePlan(state, plan);
    if (err.length) throw new Error("invalid plan: " + err.join(","));
    const S = setup(state, plan, o.forceVariance);
    const base = baseSim(S);
    let events;
    if (o.forceEvents) events = sortBySegment(S.A, o.forceEvents.map((id) => EVENTS.find((e) => e.id === id)));
    else events = scheduleEvents(S, base);
    const sim = new ShowSim(S, events, shieldCards(state));
    sim.base = base;
    return sim;
  }

  function gradeOf(sat) { return B.grades.find((g) => sat >= g.min); }

  function money(S, sim) {
    const A = S.A;
    const ticket = S.att * S.price;
    const bar = ap(S.M, sim.drinks * A.drink_price, "bar.price");
    const food = A.knobs.facilities.includes("food") ? sim.foodServed * facRow("food", A.id).food_price : 0;
    return { ticket, bar, food, profit: ticket + bar + food + S.offer.sponsor - S.cost.total + sim.evMoney };
  }

  // 돌발 없음·분산 v(기본 0) 기대 결과 — 봇·분석용. 엔진 상태는 바꾸지 않는다.
  function evaluate(state, plan, v = 0) {
    const S = setup(state, plan, v);
    const sim = baseSim(S);
    const { satisfaction, lines } = sim.summary();
    const grade = gradeOf(satisfaction);
    return { satisfaction, grade: grade.id, lines, cost: S.cost.total, att: S.att, demand: S.demand, raw: S.raw, ...money(S, sim) };
  }

  // ---------- 결과·정산 (S7·S8, run.md ④⑤) ----------
  function finishShow(state0, sim) {
    if (!sim.done || sim.pendingEvent) throw new Error("show not finished");
    const state = clone(state0);
    const S = sim.S, A = S.A, M = S.M;
    const { lines, satisfaction } = sim.summary();
    const grade = gradeOf(satisfaction);
    const { ticket, bar, food, profit } = money(S, sim);
    let fd = scale(grade.fame, S.offer.fame_pct);
    if (fd > 0) fd = ap(M, fd, "fame.gain");
    const fameBefore = state.fame, fundsBefore = state.funds;
    state.funds += profit;
    state.fame = Math.max(0, state.fame + fd + sim.evFame);
    // 쓴 대비 카드 소모
    for (const [uid, n] of Object.entries(sim.shieldUsed)) {
      const c = state.cards.find((x) => String(x.uid) === String(uid));
      c.charges -= n;
    }
    state.cards = state.cards.filter((c) => !(c.duration.type === "charges" && c.charges <= 0));

    const res = {
      act: A.id, show_idx: state.show_idx, isGate: S.ctx.isGate,
      offer: S.offer, venue: S.venue.id, plan: clone(S.plan),
      trendMatch: S.trendMatch, themeMatch: S.themeMatch,
      demand: S.demand, att: S.att, capacity: S.venue.capacity, soldOut: S.soldOut, variance: S.v, varianceRoll: S.vRoll,
      satisfaction, grade: grade.id, lines: sortLines(lines), mood: sim.mood, segs: sim.segs,
      cost: S.cost, ticket, bar, food, sponsor: S.offer.sponsor, evMoney: sim.evMoney, profit,
      fameDelta: state.fame - fameBefore, fundsBefore, fameBefore,
      events: sim.log, miss: { ...sim.miss }, activeCards: [...M.active],
    };

    // 실패 판정: 파산 → 명성 0 → 관문 (run.md ④)
    let gatePass = false;
    if (state.funds < 0) {
      if (state.bankrupt_shields_used < rule(M, "bankrupt_shield")) {
        state.funds = 0; state.bankrupt_shields_used++; res.bankruptShieldUsed = true;
      } else state.result = "bankrupt";
    }
    if (!state.result && state.fame <= 0) state.result = "fame_zero";
    if (!state.result && S.ctx.isGate) {
      const relax = rule(M, "gate_grade_relax");
      if (GRADE_RANK[grade.id] <= GRADE_RANK[A.gate.min_grade] + relax && state.fame >= (A.gate.min_fame ?? 0)) {
        gatePass = true;
        if (A.id >= lastAct) state.result = A.id >= data.acts.acts.length ? "clear" : "pass_act";
      } else state.result = "gate_fail";
    }
    res.gatePass = gatePass;
    state.history.push(res);
    if (state.result) {
      state.phase = "over";
      state.pending = { res };
      return state;
    }
    state.pending = { res, rewards: rollRewards(state, A, gatePass, grade.id) };
    state.phase = "reward";
    return state;
  }

  function sortLines(lines) {
    const ord = (k) => LINE_ORDER.indexOf(k.startsWith("event:") ? "event" : k);
    // 감점 줄 먼저, 절댓값 큰 순, 같으면 표 순서
    return [...lines].sort((a, b) =>
      (a.value < 0 ? 0 : 1) - (b.value < 0 ? 0 : 1) || Math.abs(b.value) - Math.abs(a.value) || ord(a.key) - ord(b.key));
  }

  // ---------- 보상 (rewards.md R2·R3) ----------
  function materialize(card, ri) {
    const R = RW.rarities[ri];
    const c = clone(card);
    c.rarity = R.id;
    if (c.class === "scalable") {
      for (const e of c.effects) {
        if (e.scales !== false && ["pct", "add", "money", "fame"].includes(e.type)) e.value = scale(e.value, R.mag_pct);
      }
    }
    const extra = c.class === "scalable" ? R.uses_add : 0;
    if (c.duration.type === "uses") c.left = c.duration.n + extra;
    if (c.duration.type === "charges") c.charges = c.duration.n + extra;
    return c;
  }

  function rollRewards(state, A, gatePass, grade) {
    const r = stream(state.seed, state.show_idx, STREAM.REWARD);
    const W = RW.rarity_weights_by_act.find((x) => x.act === state.act).weights;
    const rareI = RARITY_IDX.get(RW.gate_guarantee_min_rarity);
    const upSlot = GRADE_RANK[grade] <= GRADE_RANK[RW.grade_upgrade_min_grade] ? (gatePass ? 1 : 0) : -1;
    const picked = [];
    for (let slot = 0; slot < RW.offer_count; slot++) {
      const lo = gatePass && slot === 0 ? rareI : 0;
      let ri = weightedPick(r, W.map((w, i) => (i < lo ? 0 : w)));
      if (slot === upSlot) ri = Math.min(ri + 1, RW.rarities.length - 1);
      const excl = new Set([...state.owned_ids, ...picked.map((p) => p.id)]);
      let card = null;
      for (;;) {
        const cls = RW.rarities[ri].class;
        if (cls !== "scalable") {
          const pool = RW.cards.filter((c) => c.class === cls && c.min_act <= state.act && !excl.has(c.id));
          if (!pool.length) { ri = rareI; continue; }
          card = pool[r.int(pool.length)];
          break;
        }
        const avail = new Map();
        for (const k of RW.kinds) {
          const l = RW.cards.filter((c) => c.class === "scalable" && c.kind === k.id && c.min_act <= state.act && !excl.has(c.id));
          if (l.length) avail.set(k.id, l);
        }
        const K = RW.kinds.filter((k) => avail.has(k.id));
        if (!K.length) break;
        const k = K[weightedPick(r, K.map((x) => x.weight))];
        const l = avail.get(k.id);
        card = l[r.int(l.length)];
        break;
      }
      if (card) picked.push(materialize(card, ri));
    }
    return picked;
  }

  // ⑤ 보상 선택 + ⑥ 카드 소모·다음 공연으로
  function chooseReward(state0, index) {
    const state = clone(state0);
    if (state.phase !== "reward") throw new Error("not in reward phase");
    const { res, rewards } = state.pending;
    const A = act(state.act);
    const pick = rewards[index];
    if (pick) {
      state.owned_ids.push(pick.id);
      if (pick.duration.type === "instant") {
        for (const e of pick.effects) {
          if (e.type === "money") state.funds += scale(e.value, A.money_scale_pct);
          if (e.type === "fame") state.fame = Math.max(0, state.fame + e.value);
        }
      } else {
        pick.uid = state.next_uid++;
        state.cards.push(pick);
      }
    }
    // ⑥ 이번 공연에 활성이던 'uses' 카드 −1
    for (const c of state.cards) {
      if (c.duration.type === "uses" && res.activeCards.includes(c.uid)) c.left -= 1;
    }
    state.cards = state.cards.filter((c) => !(c.duration.type === "uses" && c.left <= 0));
    state.show_idx += 1;
    if (res.isGate) { state.act += 1; state.show_in_act = 0; } else state.show_in_act += 1;
    state.pending = null;
    state.phase = "offer";
    return state;
  }

  return {
    data, B, ACTS, VENUES, ARTISTS, GENRE, STAFF, FAC, EVENTS,
    stream, act, actVenues, staffRow, facRow, staffMin, staffMax, facMax,
    collectMods, mp, ap, addv, rule, isActive,
    newRun, beginShow, defaultPlan, validatePlan, cost, preview, evaluate, startShow, finishShow,
    chooseReward, rollRewards, materialize, gradeOf, setup, baseSim, eventWeights, scheduleEvents, shieldCards,
  };
}
