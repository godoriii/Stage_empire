// SE-069 엔진 테스트. 실행: node prototype/v2/test_engine.mjs
// 고정점은 docs/gdd/v2/show.md 손 계산 예시 (a)(b), run/events/rewards.md 수용 기준.
import { createEngine, mulberry32, STREAM } from "./engine.js";
import { loadData } from "./load_data.mjs";
import { runBot, POLICIES } from "./bot.mjs";

const data = loadData();
const eng = createEngine(data);
let pass = 0, fail = 0;
function check(name, cond, detail = "") {
  if (cond) pass++;
  else { fail++; console.log("FAIL", name, detail); }
}
function eq(name, got, want) {
  const g = JSON.stringify(got), w = JSON.stringify(want);
  check(name, g === w, `got ${g} want ${w}`);
}

// 1막 상태를 직접 만든다(제안·시장을 고정).
function fixedState({ funds, fame, offerId, theme, market, cards = [] }) {
  const s = eng.newRun(1);
  s.funds = funds; s.fame = fame; s.cards = cards;
  const A = eng.act(1);
  const offer = { ...A.offer_templates.find((t) => t.id === offerId), theme };
  s.pending = { ctx: { act: 1, isGate: false, offers: [offer], market, minCost: 0, credit: A.credit_limit } };
  s.phase = "plan";
  return s;
}
const plan = (venue, H, O, sec, bar, toilet, priceIdx) =>
  ({ offer: 0, venue, headliners: H, openers: O, staff: { security: sec, bar }, fac: { toilet }, price: priceIdx, promo: 0 });

function play(state, p, o = { forceVariance: 0, forceEvents: [] }, chooser) {
  const sim = eng.startShow(state, p, o);
  sim.runAll(chooser || (() => { throw new Error("unexpected event"); }));
  return { sim, after: eng.finishShow(state, sim) };
}
const lineMap = (res) => Object.fromEntries(res.lines.map((l) => [l.key, l.value]).sort((a, b) => (a[0] < b[0] ? -1 : 1)));

// ---- RNG 테스트 벡터 (RN2) ----
{
  const r = mulberry32(12345);
  eq("RN2 mulberry32(12345)", [r.next_u32(), r.next_u32(), r.next_u32()], [4207900869, 1317490944, 2079646450]);
  eq("RN2 stream(42,0,DEMAND).range", eng.stream(42, 0, STREAM.DEMAND).range(-20, 20), -9);
}

// ---- SH1 예시 (a) ----
{
  const s = fixedState({ funds: 300, fame: 10, offerId: "friday", theme: "indie", market: ["a1_two_umbrellas", "a1_rusty_bike"] });
  const p = plan("club_basement", ["a1_two_umbrellas"], ["a1_rusty_bike"], 2, 2, 1, 2);
  const { sim, after } = play(s, p);
  const res = after.pending.res;
  eq("SH1 demand/att", [res.demand, res.att], [110, 110]);
  eq("SH1 cost", res.cost.total, 286);
  eq("SH1 present", sim.segs.map((x) => x.present), [49, 88, 104, 110, 110]);
  eq("SH1 bar served", sim.segs.map((x) => x.barServed), [12, 13, 36, 11, 5]);
  eq("SH1 toilet dem", sim.segs.map((x) => x.toiDem), [2, 8, 41, 11, 22]);
  eq("SH1 security load", sim.segs.map((x) => x.load), [20, 55, 50, 92, 61]);
  eq("SH1 mood", res.mood, [62, 66, 66, 76, 76]);
  eq("SH1 lines", lineMap(res), { headliner: 7, opener: 4, theme: 3 });
  eq("SH1 sat/grade", [res.satisfaction, res.grade], [76, "A"]);
  eq("SH1 money", [res.ticket, res.bar, res.profit], [330, 77, 121]);
  eq("SH1 fame/funds", [after.fame, after.funds], [13, 421]);
  const pv = eng.preview(s, p);
  eq("SH1 preview", [pv.attLow, pv.attHigh, pv.breakEven, pv.warnings.length], [88, 120, 74, 0]);
}

// ---- SH2 예시 (b) + 대조안 ----
const sB = fixedState({ funds: 420, fame: 13, offerId: "weekend", theme: "hiphop", market: ["a1_dawn_laundry", "a1_rusty_bike"] });
const pB = plan("club_studio", ["a1_dawn_laundry"], ["a1_rusty_bike"], 1, 2, 0, 2);
{
  const { sim, after } = play(sB, pB);
  const res = after.pending.res;
  eq("SH2 demand/att/cost", [res.demand, res.att, res.cost.total], [173, 173, 485]);
  eq("SH2 security load", sim.segs.map((x) => x.load), [55, 149, 137, 249, 166]);
  eq("SH2 miss", [res.miss.toilet_queue, res.miss.security], [20, 506]);
  eq("SH2 lines", lineMap(res), { headliner: 6, opener: 4, security: -12, sound: 4, toilet_queue: -7 });
  eq("SH2 mood", res.mood, [62, 67, 57, 57, 57]);
  eq("SH2 sat/grade/profit/fame", [res.satisfaction, res.grade, res.profit, res.fameDelta], [57, "C", 155, 0]);
  eq("SH2 review order", res.lines.slice(0, 2).map((l) => l.key), ["security", "toilet_queue"]);
  const pv = eng.preview(sB, pB);
  eq("SH6 preview warnings", pv.warnings.map((w) => w.key).sort(), ["security", "toilet_queue"]);
  // 대조안 비용 545 는 자금 420 + 외상 100 을 넘는다(스펙 예시의 가정 오류) → 자금 450 으로 검산
  const fix = { ...pB, staff: { security: 5, bar: 2 }, fac: { toilet: 2 } };
  check("SH2 contrast over budget at funds 420", eng.validatePlan(sB, fix).includes("budget"));
  const r2 = play({ ...sB, funds: 450 }, fix).after.pending.res;
  eq("SH2 contrast cost", r2.cost.total, 545);
  eq("SH2 contrast", [r2.satisfaction, r2.grade, r2.profit, r2.fameDelta], [76, "A", 95, 4]);
}

// ---- SH5 예산 초과 거부 ----
{
  const s = fixedState({ funds: 100, fame: 10, offerId: "friday", theme: "rock", market: ["a1_fullmoon_diner", "a1_rebar"] });
  const p = plan("club_rooftop", ["a1_fullmoon_diner"], ["a1_rebar"], 6, 4, 3, 0);
  check("SH5 over budget rejected", eng.validatePlan(s, p).includes("budget"));
  let threw = false;
  try { eng.startShow(s, p); } catch { threw = true; }
  check("SH5 startShow throws", threw);
}

// ---- SH4 분위기 마감 값 = 최종 만족도, SH3 줄 키 집합 (무작위 계획 1,000개) ----
{
  const allowed = new Set(["price_over", "opener", "sound", "headliner", "theme", "empty_room", "sold_out",
    "bar_queue", "toilet_queue", "security", "base_bonus"]);
  const r = mulberry32(7);
  let bad = 0, badKey = 0, n = 0;
  const venues = eng.actVenues(1).map((v) => v.id);
  const artists = data.artists.artists.filter((a) => a.act === 1).map((a) => a.id);
  for (let i = 0; i < 1000; i++) {
    const h = artists[r.int(artists.length)];
    let o = artists[r.int(artists.length)];
    const s = fixedState({ funds: 5000, fame: r.int(30) + 1, offerId: "friday", theme: "rock", market: [h, o] });
    const v = venues[r.int(venues.length)];
    const vb = eng.VENUES.get(v).bar_slots;
    const p = plan(v, [h], o === h || r.int(3) === 0 ? [] : [o], 1 + r.int(6), 1 + r.int(vb), r.int(4), r.int(4));
    const sim = eng.startShow(s, p, { forceVariance: r.range(-20, 20), forceEvents: [] }).runAll(() => 0);
    const { satisfaction, lines } = sim.summary();
    n++;
    if (sim.mood[4] !== satisfaction && satisfaction > 0 && satisfaction < 100) bad++;
    if (lines.some((l) => !allowed.has(l.key))) badKey++;
  }
  check("SH4 mood end == satisfaction (1000)", bad === 0, `${bad}/${n}`);
  check("SH3 line keys", badKey === 0, `${badKey}`);
}

// ---- EV2 조건 가중치: 보안 1명·록 200명 ----
{
  const s = fixedState({ funds: 5000, fame: 10, offerId: "friday", theme: "indie", market: ["a1_rebar"] });
  const p = plan("club_rooftop", ["a1_rebar"], [], 1, 4, 0, 1);
  const S = eng.setup(s, p, 0);
  const base = eng.baseSim(S);
  const pool = data.events.events.filter((e) => e.act.includes(1));
  const w = Object.fromEntries(pool.map((e, i) => [e.id, eng.eventWeights(S, base, pool)[i]]));
  eq("EV2 att", S.att >= 180, true);
  eq("EV2 weights", [w.entrance_jam, w.drunk_fight, w.beer_shortage, w.noise_complaint], [18, 18, 12, 9]);
}

// ---- EV3 security_ok 거짓이면 guards 없음 / EV5 seg_pct 는 그 구간부터 ----
{
  const sim = eng.startShow(sB, pB, { forceVariance: 0, forceEvents: ["beer_shortage", "drunk_fight"] });
  const seen = [];
  sim.runAll((b) => {
    seen.push([b.event.id, b.options.map((o) => o.id)]);
    return b.event.id === "beer_shortage" ? "limit" : "stop";
  });
  eq("EV3 options", seen, [["beer_shortage", ["mart", "limit"]], ["drunk_fight", ["stop", "police"]]]);
  eq("EV5 bar cap by seg", sim.segs.map((x) => x.barCap), [60, 60, 30, 30, 30]);
  const ok = eng.startShow({ ...sB, funds: 500 }, { ...pB, staff: { security: 6, bar: 2 } }, { forceVariance: 0, forceEvents: ["drunk_fight"] });
  let opts = null;
  ok.runAll((b) => { opts = b.options.map((o) => o.id); return "guards"; });
  eq("EV3 guards when covered", opts, ["guards", "stop", "police"]);
}

// ---- EV4 대비 카드 ----
{
  const amp = eng.materialize(data.rewards.cards.find((c) => c.id === "g_spare_amp"), 0);
  amp.uid = 99;
  const s = fixedState({ funds: 420, fame: 13, offerId: "weekend", theme: "hiphop", market: ["a1_dawn_laundry", "a1_rusty_bike"], cards: [amp] });
  const sim = eng.startShow(s, pB, { forceVariance: 0, forceEvents: ["amp_fail", "toilet_clog"] });
  const seen = [];
  sim.runAll((b) => { seen.push([b.event.id, b.options.map((o) => o.id)]); return b.options.at(-1).id; });
  eq("EV4 shield only on matching tag", seen, [["amp_fail", ["repair", "unplugged", "__shield"]], ["toilet_clog", ["plumber", "close"]]]);
  const after = eng.finishShow(s, sim);
  eq("EV4 charge consumed", after.cards.length, 0);
}

// ---- EV1 / RN1 / RN3 결정성 ----
{
  const a = runBot(eng, POLICIES.rational, 1234, { keepLog: true });
  const b = runBot(eng, POLICIES.rational, 1234, { keepLog: true });
  check("RN1 same seed same run", JSON.stringify(a) === JSON.stringify(b));
  // RN3: 정책만 바꾸고 시드를 같게 하면 공연마다 제안·시장·수요 분산 난수가 같다(두 정책이 모두 도달한 공연까지).
  // 분산은 굴린 값(vRoll) 기준 — '흥행 감각' 카드의 하한 적용 전.
  let compared = 0, diff = 0;
  for (let seed = 1; seed <= 30; seed++) {
    const ra = runBot(eng, POLICIES.random, seed, { keepLog: true });
    const rb = runBot(eng, POLICIES.rational, seed, { keepLog: true });
    const n = Math.min(ra.shows.length, rb.shows.length);
    for (let i = 0; i < n; i++) {
      compared++;
      const a = ra.shows[i], b = rb.shows[i];
      if (JSON.stringify([a.ctx, a.variance]) !== JSON.stringify([b.ctx, b.variance])) diff++;
    }
  }
  check("RN3 offers/market/variance same across policies", compared > 30 && diff === 0, `${diff}/${compared}`);
  // 보상 제시: 같은 (시드, show_idx, 등급, 관문 통과, 받은 카드)면 자금·명성·보유 카드 상태와 무관하게 같다
  const ra = eng.newRun(77), rb = eng.newRun(77);
  rb.funds = 999; rb.fame = 40; rb.cards = [eng.materialize(data.rewards.cards[0], 0)];
  ra.owned_ids = rb.owned_ids = ["c_sound_friend"];
  eq("RN3 rewards depend only on seed/show/grade/gate/owned", eng.rollRewards(ra, eng.act(1), false, "B"), eng.rollRewards(rb, eng.act(1), false, "B"));
}

// ---- RW 보상 ----
{
  const cards = data.rewards.cards;
  eq("RW1 counts", [cards.length, cards.filter((c) => c.class === "scalable").length,
    cards.filter((c) => c.class === "unique").length, cards.filter((c) => c.class === "legendary").length], [55, 47, 4, 4]);
  check("RW1 weights sum 100", data.rewards.rarity_weights_by_act.every((x) => x.weights.reduce((a, b) => a + b) === 100));
  const rare = eng.materialize(cards.find((c) => c.id === "r_venue_15"), 2);
  eq("RW5 rare venue coupon", [rare.effects[0].value, rare.left], [-30, 4]);
  const sp = eng.materialize(cards.find((c) => c.id === "s_guards_2"), 1);
  eq("RW5 special guards", [sp.effects[0].value, sp.left], [3, 2]);
  // RW3: 관문 통과 첫 장 레어 이상, A 이상이면 둘째 장 +1
  const s = eng.newRun(1);
  let lowFirst = 0, counts = {};
  for (let i = 0; i < 10000; i++) {
    s.seed = i;
    const r = eng.rollRewards(s, eng.act(1), true, "A");
    if (!["rare", "unique", "legendary"].includes(r[0].rarity)) lowFirst++;
    counts[r[1].rarity] = (counts[r[1].rarity] || 0) + 1;
  }
  check("RW3 gate first slot >= rare", lowFirst === 0, String(lowFirst));
  check("RW3 upgraded slot never normal", !counts.normal, JSON.stringify(counts));
  // RW2 결정성
  eq("RW2 deterministic", eng.rollRewards(eng.newRun(9), eng.act(1), false, "B"), eng.rollRewards(eng.newRun(9), eng.act(1), false, "B"));
  // RW4 유니크 풀 소진 → 레어로
  const s4 = eng.newRun(3);
  s4.owned_ids = cards.filter((c) => c.class !== "scalable").map((c) => c.id);
  let special = 0;
  for (let i = 0; i < 2000; i++) {
    s4.seed = i;
    for (const c of eng.rollRewards(s4, eng.act(1), false, "C")) if (c.class !== "scalable") special++;
  }
  check("RW4 exhausted unique/legendary fall back", special === 0);
}

// ---- RN5 실패 4종 ----
{
  // 파산: 자금 0, 외상으로 비싼 공연 + 수요 −20
  const s = fixedState({ funds: 60, fame: 1, offerId: "weeknight", theme: "indie", market: ["a1_rusty_bike"] });
  const pick = { amp_fail: "repair", noise_complaint: "endure" };
  const r = play(s, plan("club_basement", ["a1_rusty_bike"], [], 1, 1, 0, 0),
    { forceVariance: -20, forceEvents: ["amp_fail", "noise_complaint"] }, (b) => pick[b.event.id]).after;
  check("RN5 bankrupt", r.result === "bankrupt" && r.phase === "over" && !r.pending.rewards, `${r.result} funds ${r.funds}`);
  // 명성 0
  const s2 = fixedState({ funds: 500, fame: 1, offerId: "critic", theme: "rock", market: ["a1_fluorescent"] });
  const r2 = play(s2, plan("club_rooftop", ["a1_fluorescent"], [], 1, 1, 0, 3)).after;
  check("RN5 fame_zero", r2.result === "fame_zero", `${r2.result} fame ${r2.fame} grade ${r2.pending.res.grade}`);
  // 관문 실패
  const s3 = fixedState({ funds: 500, fame: 30, offerId: "friday", theme: "rock", market: ["a1_fluorescent"] });
  s3.pending.ctx.isGate = true;
  s3.pending.ctx.offers = [{ ...eng.act(1).gate.template, theme: "rock" }];
  const r3 = play(s3, plan("club_rooftop", ["a1_fluorescent"], [], 1, 1, 0, 3)).after;
  check("RN5 gate_fail", r3.result === "gate_fail", r3.result);
  // 개최 불가
  const s4 = eng.newRun(5);
  s4.funds = -200;
  check("RN5 no_show", eng.beginShow(s4).result === "no_show");
}

console.log(`${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
