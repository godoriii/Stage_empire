// SE-069 봇 정책과 1막 통계. 정책 정의: docs/gdd/v2/run.md #봇-정책과-1막-밸런스-목표
// 실행: node prototype/v2/bot.mjs --runs 1000 [--seed-start 1] [--policy random,rational] [--json out.json]
import { createEngine, mulberry32, div } from "./engine.js";
import { loadData } from "./load_data.mjs";

const RARITY_ORDER = ["normal", "special", "rare", "unique", "legendary"];

// 봇 전용 RNG(엔진 스트림과 섞지 않는다)
const botRng = (seed) => mulberry32((seed ^ 0x9e3779b9) >>> 0);

function basePlan(eng, state) {
  const p = eng.defaultPlan(state);
  p.headliners = []; p.openers = [];
  return p;
}

function cheapestPlan(eng, state) {
  const A = eng.act(state.act);
  const { ctx } = state.pending;
  let best = null;
  for (let oi = 0; oi < ctx.offers.length; oi++) {
    for (const v of eng.actVenues(A.id)) {
      for (const h of ctx.market) {
        const p = basePlan(eng, state);
        Object.assign(p, { offer: oi, theme: ctx.offers[oi].trend, venue: v.id, headliners: [h] });
        const c = eng.cost(eng.collectMods(state.cards), A, ctx.offers[oi], v, p).total;
        if (!best || c < best.c) best = { p, c };
      }
    }
  }
  return best.p;
}

// ---------- 무작위 ----------
const random = {
  name: "random",
  plan(eng, state, r) {
    const A = eng.act(state.act);
    const { ctx } = state.pending;
    for (let t = 0; t < 50; t++) {
      const p = basePlan(eng, state);
      p.offer = r.int(ctx.offers.length);
      p.theme = eng.data.artists.genres[r.int(eng.data.artists.genres.length)].id;
      const vs = eng.actVenues(A.id);
      const v = vs[r.int(vs.length)];
      p.venue = v.id;
      const h = ctx.market[r.int(ctx.market.length)];
      p.headliners = [h];
      const rest = ctx.market.filter((x) => x !== h);
      if (A.lineup.opener_slots > 0) {
        const k = r.int(rest.length + 1);
        p.openers = k === 0 ? [] : [rest[k - 1]];
      }
      for (const role of A.knobs.staff) {
        const lo = eng.staffMin(A, role), hi = eng.staffMax(A, role, v, p);
        p.staff[role] = lo + r.int(hi - lo + 1);
      }
      for (const f of A.knobs.facilities) p.fac[f] = r.int(eng.facMax(A, f) + 1);
      p.price = r.int(A.price_levels.length);
      if (A.knobs.promo) p.promo = r.int(A.promo_levels.length);
      if (eng.validatePlan(state, p).length === 0) return p;
    }
    return cheapestPlan(eng, state);
  },
  event(eng, state, beat, sim, r) { return beat.options[r.int(beat.options.length)].id; },
  reward(eng, state, rewards, r) { return r.int(rewards.length); },
};

// ---------- 합리적 ----------
// 경고(줄 ≤ warn_at)가 사라질 때까지 해당 손잡이를 1씩 올린다.
const KNOB_FOR = { security: ["staff", "security"], bar_queue: ["staff", "bar"], toilet_queue: ["fac", "toilet"],
  food_queue: ["fac", "food"], cleaning: ["staff", "cleaning"], medical: ["staff", "medical"] };

function fixWarnings(eng, state, p) {
  const A = eng.act(state.act);
  const v = eng.VENUES.get(p.venue);
  for (let guard = 0; guard < 60; guard++) {
    const ev = eng.evaluate(state, p, 0);
    let changed = false;
    for (const l of ev.lines) {
      if (l.value > eng.B.preview.warn_at || !KNOB_FOR[l.key]) continue;
      const [grp, k] = KNOB_FOR[l.key];
      const max = grp === "staff" ? eng.staffMax(A, k, v, p) : eng.facMax(A, k);
      if (!(A.knobs[grp === "staff" ? "staff" : "facilities"].includes(k))) continue;
      if ((p[grp][k] || 0) < max) { p[grp][k] = (p[grp][k] || 0) + 1; changed = true; }
    }
    if (!changed) return p;
  }
  return p;
}

function rationalCandidates(eng, state) {
  const A = eng.act(state.act);
  const { ctx } = state.pending;
  const M = eng.collectMods(state.cards);
  const out = [];
  for (let oi = 0; oi < ctx.offers.length; oi++) {
    for (const h of ctx.market) {
      const art = eng.ARTISTS.get(h);
      let pi = 0;
      A.price_levels.forEach((lv, i) => { if (lv.price <= art.fair_price) pi = i; });
      // 테마 = 헤드라이너 장르. 오프닝 후보: 같은 장르 중 가장 싼 아티스트, 아무 장르 중 가장 싼 아티스트, 없음
      const rest = ctx.market.filter((x) => x !== h).map((id) => eng.ARTISTS.get(id)).sort((a, b) => a.fee - b.fee);
      const openerOpts = [];
      if (A.lineup.opener_slots > 0 && rest.length) {
        const same = rest.find((a) => a.genre === art.genre);
        if (same) openerOpts.push([same.id]);
        if (!same || same.id !== rest[0].id) openerOpts.push([rest[0].id]);
      }
      openerOpts.push([]);
      for (const openers of openerOpts) {
        const p = basePlan(eng, state);
        Object.assign(p, { offer: oi, theme: art.genre, headliners: [h], openers, price: pi });
        // 예상 수요(분산 0)를 담는 가장 싼 장소, 없으면 가장 큰 곳
        let pick = null, biggest = null;
        for (const v of eng.actVenues(A.id)) {
          p.venue = v.id;
          const ev = eng.evaluate(state, p, 0);
          const vc = eng.cost(M, A, ctx.offers[oi], v, p).venue;
          if (ev.raw <= v.capacity && (!pick || vc < pick.vc)) pick = { id: v.id, vc };
          if (!biggest || v.capacity > biggest.cap) biggest = { id: v.id, cap: v.capacity };
        }
        p.venue = (pick || biggest).id;
        fixWarnings(eng, state, p);
        if (eng.validatePlan(state, p).length) continue;
        const ev = eng.evaluate(state, p, 0);
        out.push({ p, ev });
      }
    }
  }
  return out;
}

const rational = {
  name: "rational",
  plan(eng, state) {
    const cands = rationalCandidates(eng, state);
    const score = (c) => c.ev.satisfaction + div(c.ev.profit, 20);
    const pickBest = (l) => l.reduce((a, b) => (score(b) > score(a) ? b : a));
    const good = cands.filter((c) => c.ev.cost <= state.funds && c.ev.profit >= 0);
    if (good.length) return pickBest(good).p;
    if (cands.length) return pickBest(cands).p;
    return cheapestPlan(eng, state);
  },
  event(eng, state, beat, sim) {
    const sh = beat.options.find((o) => o.id === "__shield");
    if (sh) return sh.id;
    let best = null;
    for (const o of beat.options) {
      let money = 0, sat = 0, fame = 0;
      for (const e of o.effects) {
        if (e.type === "money") money += e.value;
        if (e.type === "sat") sat += e.value;
        if (e.type === "fame") fame += e.value;
      }
      const poor = money < 0 && state.funds + sim.evMoney + money < 30;
      const sc = money + 6 * sat + 18 * fame - (poor ? 100000 : 0);
      if (!best || sc > best.sc) best = { id: o.id, sc };
    }
    return best.id;
  },
  reward(eng, state, rewards) {
    const pref = (c) => RARITY_ORDER.indexOf(c.rarity) * 10 + (c.kind === "contact" || c.kind === "knowhow" ? 1 : 0);
    let bi = 0;
    rewards.forEach((c, i) => { if (pref(c) > pref(rewards[bi])) bi = i; });
    return bi;
  },
};

export const POLICIES = { random, rational };

// 런 1회. 엔진은 lastAct=1 로 만든 것을 넘긴다(1막 통과 = pass_act).
export function runBot(eng, policy, seed, o = {}) {
  const r = botRng(seed);
  let s = eng.newRun(seed);
  const shows = [];
  for (let guard = 0; guard < 40; guard++) {
    s = eng.beginShow(s);
    if (s.phase === "over") break;
    const ctxLog = o.keepLog ? { offers: s.pending.ctx.offers.map((x) => x.id + ":" + x.theme), market: s.pending.ctx.market } : null;
    const p = policy.plan(eng, s, r);
    const extra = o.analyze ? o.analyze(eng, s, p) : null;
    const sim = eng.startShow(s, p);
    sim.runAll((beat) => policy.event(eng, s, beat, sim, r));
    s = eng.finishShow(s, sim);
    const res = s.pending.res;
    shows.push({ act: res.act, gate: res.isGate, grade: res.grade, sat: res.satisfaction, profit: res.profit,
      funds: s.funds, fame: s.fame, events: res.events.map((e) => e.event + ":" + e.choice), variance: res.varianceRoll,
      ...(ctxLog ? { ctx: ctxLog } : {}), ...(extra ? { extra } : {}) });
    if (s.phase === "over") break;
    s = eng.chooseReward(s, policy.reward(eng, s, s.pending.rewards, r));
  }
  return { seed, result: s.result, shows, funds: s.funds, fame: s.fame, cards: s.cards.map((c) => c.id + ":" + c.rarity) };
}

// 합리적 계획의 민감도: 수요 −20 % 적자, 결정 하나 바꾸면 등급 변화
function analyzeRational(eng, s, p) {
  const A = eng.act(s.act);
  const base = eng.evaluate(s, p, 0);
  const low = eng.evaluate(s, p, -eng.B.demand.variance_pct);
  const variants = {};
  const tryV = (name, mut) => {
    const q = JSON.parse(JSON.stringify(p));
    if (mut(q) === false) return;
    if (eng.validatePlan(s, q).filter((e) => e !== "budget").length) return;
    variants[name] = eng.evaluate(s, q, 0).grade !== base.grade;
  };
  tryV("security-2", (q) => { if (q.staff.security - 2 < eng.staffMin(A, "security")) return false; q.staff.security -= 2; });
  tryV("toilet0", (q) => { if (!q.fac.toilet) return false; q.fac.toilet = 0; });
  tryV("no_opener", (q) => { if (!q.openers.length) return false; q.openers = []; });
  tryV("price+1", (q) => { if (q.price + 1 >= A.price_levels.length) return false; q.price += 1; });
  tryV("bar-1", (q) => { if (q.staff.bar - 1 < eng.staffMin(A, "bar")) return false; q.staff.bar -= 1; });
  tryV("venue+1", (q) => {
    const vs = eng.actVenues(A.id).sort((a, b) => a.capacity - b.capacity);
    const i = vs.findIndex((v) => v.id === q.venue);
    if (i + 1 >= vs.length) return false;
    q.venue = vs[i + 1].id;
    q.staff.bar = Math.min(q.staff.bar, vs[i + 1].bar_slots);
  });
  return { lowDeficit: low.profit < 0, anyChange: Object.values(variants).some(Boolean), variants };
}

const pct = (a, b) => (b ? Math.round((1000 * a) / b) / 10 : 0);
function quant(xs, q) {
  const s = [...xs].sort((a, b) => a - b);
  return s[Math.min(s.length - 1, Math.floor(q * s.length))];
}

export function stats(eng, policy, n, seedStart = 1) {
  const runs = [];
  const analyze = policy.name === "rational" ? analyzeRational : null;
  for (let i = 0; i < n; i++) runs.push(runBot(eng, policy, seedStart + i, { analyze }));
  const results = {};
  for (const r of runs) results[r.result] = (results[r.result] || 0) + 1;
  const all = runs.flatMap((r) => r.shows);
  const grades = {};
  for (const sh of all) grades[sh.grade] = (grades[sh.grade] || 0) + 1;
  const out = {
    policy: policy.name, runs: n, seeds: `${seedStart}..${seedStart + n - 1}`,
    pass_rate: pct(results.pass_act || 0, n),
    results: Object.fromEntries(Object.entries(results).map(([k, v]) => [k, pct(v, n)])),
    first_show_deficit: pct(runs.filter((r) => r.shows[0] && r.shows[0].profit < 0).length, n),
    grades: Object.fromEntries(["S", "A", "B", "C", "D"].map((g) => [g, pct(grades[g] || 0, all.length)])),
    profit_p10_med_p90: [quant(all.map((s) => s.profit), 0.1), quant(all.map((s) => s.profit), 0.5), quant(all.map((s) => s.profit), 0.9)],
    shows: all.length,
  };
  if (analyze) {
    const ex = all.map((s) => s.extra).filter(Boolean);
    out.low_demand_deficit = pct(ex.filter((e) => e.lowDeficit).length, ex.length);
    out.one_change_grade = pct(ex.filter((e) => e.anyChange).length, ex.length);
    const vk = {};
    for (const e of ex) for (const [k, v] of Object.entries(e.variants)) { vk[k] ??= [0, 0]; vk[k][0] += v ? 1 : 0; vk[k][1]++; }
    out.one_change_by_variant = Object.fromEntries(Object.entries(vk).map(([k, [a, b]]) => [k, pct(a, b)]));
  }
  return out;
}

// CLI
if (import.meta.url === `file://${process.argv[1]}`) {
  const arg = (k, d) => { const i = process.argv.indexOf("--" + k); return i > 0 ? process.argv[i + 1] : d; };
  const n = +arg("runs", 200), seedStart = +arg("seed-start", 1);
  const eng = createEngine(loadData(), { lastAct: 1 });
  const res = arg("policy", "random,rational").split(",").map((k) => stats(eng, POLICIES[k], n, seedStart));
  const json = JSON.stringify(res, null, 1);
  console.log(json);
  const outPath = arg("json", null);
  if (outPath) (await import("node:fs")).writeFileSync(outPath, json);
}
