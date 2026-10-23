// SE-070 브라우저 프로토타입 (1막). 규칙은 전부 ../engine.js — 여기서는 화면만 그린다.
// build.mjs 가 engine.js 와 이 파일을 한 모듈로 합치고 데이터를 #se-data 에 넣는다(아래 import 줄은 빌드 때 빠진다).
import { createEngine, mulberry32 } from "../engine.js";

const DATA = JSON.parse(document.getElementById("se-data").textContent);
document.documentElement.lang ||= "ko";
const eng = createEngine(DATA, { lastAct: 1 });
const B = DATA.balance;
const $app = document.getElementById("app");

const GENRE_NAME = Object.fromEntries(DATA.artists.genres.map((g) => [g.id, g.name]));
const TRAIT_NAME = Object.fromEntries(DATA.venues.traits.map((t) => [t.id, t.name]));
const KIND_NAME = Object.fromEntries(DATA.rewards.kinds.map((k) => [k.id, k.name]));
const RARITY_NAME = Object.fromEntries(DATA.rewards.rarities.map((r) => [r.id, r.name]));
const EVENT_BY_ID = Object.fromEntries(DATA.events.events.map((e) => [e.id, e]));
const RESULT_TEXT = {
  bankrupt: "자금이 바닥났다", no_show: "다음 공연을 열 돈이 없다",
  fame_zero: "아무도 이름을 기억하지 않는다", gate_fail: "결산 무대에서 증명하지 못했다",
  pass_act: "1막 통과 — 클럽 씬에서 이름을 알렸다", clear: "메가 페스티벌 성공",
};
const TAG_NAME = { equipment: "장비", facility: "시설", supply: "물품", crowd: "관객", venue: "장소", weather: "날씨", artist: "아티스트", press: "언론", "*": "모든 돌발" };
const GRADES = ["S", "A", "B", "C", "D"];
function gateGrade(A) {
  const relax = app.state ? eng.rule(eng.collectMods(app.state.cards), "gate_grade_relax") : 0;
  return GRADES[Math.min(GRADES.length - 1, GRADES.indexOf(A.gate.min_grade) + relax)];
}
const won = (n) => `${n < 0 ? "−" : ""}${Math.abs(n).toLocaleString("ko-KR")}만원`;
const signed = (n) => (n > 0 ? `+${n}` : n < 0 ? `−${-n}` : "0");
const esc = (s) => String(s).replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c]);

// ---------- 이 브라우저에만 남는 편의 기록(첫 판 안내, 런 기록). 실패해도 게임은 그대로 돈다 ----------
function loadLocal(key, fallback) {
  try {
    const v = JSON.parse(localStorage.getItem(key));
    return v && typeof v === "object" && !Array.isArray(v) ? v : fallback;
  } catch { return fallback; }
}
function saveLocal(key, v) { try { localStorage.setItem(key, JSON.stringify(v)); } catch { /* 저장 불가: 무시 */ } }
const TIPS = {
  offer: "제안 카드의 '요즘 뜨는 장르'와 아래 섭외 시장을 같이 보고 고르세요. 시장에 그 장르 아티스트가 있으면 유리합니다.",
  plan: "미리보기의 ! 경고를 없애는 게 기본입니다. 예상 만족도는 일부러 숨겨 두었어요 — 결과는 공연이 끝나야 압니다.",
  show: "돌발 카드는 대개 '돈을 내고 막기' 아니면 '만족도로 버티기'입니다. 공연 뒤 정산이라 자금이 모자라도 고를 수 있어요.",
  result: "원인 리뷰의 → 가 다음에 바꿀 결정입니다. 아래 '이랬다면'은 그 결정 하나만 바꿔 다시 계산한 값이에요.",
};
const tipsSeen = loadLocal("se-v2-tips", {});
function tip(screen) {
  if (tipsSeen[screen]) return "";
  return `<div class="tip" role="note"><span><b>처음이라면</b> ${TIPS[screen]}</span><button class="chip-btn" data-act="tip-ok" data-k="${screen}">알겠어요</button></div>`;
}
const records = (() => {
  const r = loadLocal("se-v2-records", {});
  const n = (x) => (Number.isFinite(+x) ? Math.max(0, Math.floor(+x)) : 0);
  return { runs: n(r.runs), passes: n(r.passes), bestSat: n(r.bestSat), bestFame: n(r.bestFame) };
})();
// 런마다 한 번만 센다(같은 시드로 다시 한 런도 새 런). runId 는 startRun 에서 올린다.
function recordRun(s) {
  if (app.recordedRun === app.runId) return;
  app.recordedRun = app.runId;
  records.runs += 1;
  if (s.result === "pass_act" || s.result === "clear") records.passes += 1;
  records.bestSat = Math.max(records.bestSat, ...s.history.map((h) => h.satisfaction), 0);
  records.bestFame = Math.max(records.bestFame, s.fame);
  saveLocal("se-v2-records", records);
}
const reduceMotion = window.matchMedia?.("(prefers-reduced-motion: reduce)").matches;

// ---------- 앱 상태 ----------
const app = { screen: "title", state: null, plan: null, sim: null, choices: [], beats: [], speed: 1, timer: null,
  showCards: false, pickedReward: null, seed: null };

function newSeed() { return (Date.now() ^ Math.floor(Math.random() * 0xffffffff)) >>> 0; }

function startRun(seed) {
  app.runId = (app.runId || 0) + 1;
  app.seed = seed >>> 0;
  app.state = eng.newRun(app.seed);
  nextShow();
}
function nextShow() {
  app.state = eng.beginShow(app.state);
  app.plan = null;
  app.screen = app.state.phase === "over" ? "over" : "offer";
  if (app.screen === "over") recordRun(app.state);
  render();
}
function pickOffer(i) {
  const p = eng.defaultPlan(app.state);
  p.offer = i; p.theme = app.state.pending.ctx.offers[i].trend; p.headliners = []; p.openers = []; p.price = 1;
  app.plan = p;
  app.screen = "plan";
  render();
}

// ---------- 공통 조각 ----------
function topBar() {
  const s = app.state;
  if (!s) return "";
  const A = eng.act(s.act);
  const total = A.normal_shows + 1;
  const pips = Array.from({ length: total }, (_, i) => {
    const cls = i < s.show_in_act ? "done" : i === s.show_in_act && s.phase !== "over" ? "now" : "";
    return `<i class="pip ${cls} ${i === total - 1 ? "gate" : ""}" title="${i === total - 1 ? "결산 쇼케이스" : "공연 " + (i + 1)}"></i>`;
  }).join("");
  const nCards = s.cards.length;
  return `<header class="top">
    <div class="brand">STAGE<b>EMPIRE</b></div>
    <div class="stat"><span>${esc(A.name)}</span><span class="pips">${pips}</span></div>
    <div class="spacer"></div>
    <div class="stat"><span>자금</span><span>${won(s.funds)}</span></div>
    <div class="stat"><span>명성</span><span>${s.fame}</span></div>
    <button class="chip-btn" data-act="cards" aria-expanded="${app.showCards}">보유 카드 ${nCards}</button>
  </header>${app.showCards ? cardsDrawer() : ""}`;
}

function cardsDrawer() {
  const cs = app.state.cards;
  if (!cs.length) return `<div class="drawer"><span class="muted">아직 보유한 카드가 없다. 공연을 마칠 때마다 3장 중 1장을 고른다.</span></div>`;
  return `<div class="drawer">${cs.map((c) => `<div><span class="badge" style="color:var(--r-${c.rarity})">${RARITY_NAME[c.rarity]}</span>
    <b>${esc(c.name)}</b> <span class="muted">· ${durationText(c)}</span><div class="muted" style="font-size:13px">${effectLines(c).join(" · ")}</div></div>`).join("")}</div>`;
}

function artistCard(id, extra = "") {
  const a = eng.ARTISTS.get(id);
  return `<div class="row" style="justify-content:space-between"><b>${esc(a.name)}</b><span class="badge genre-${a.genre}">${GENRE_NAME[a.genre]}</span></div>
    <div class="facts num"><span>집객 ${a.draw}</span><span>실력 ${a.skill}</span><span>${won(a.fee)}</span><span>적정 ${a.fair_price}만</span></div>${extra}`;
}

function offerSummary(o) {
  const bits = [`수요 ${o.demand_pct}%`, `대관료 ${o.venue_fee_pct}%`, `명성 ×${o.fame_pct / 100}`];
  if (o.sponsor) bits.push(`협찬 +${o.sponsor}만원`);
  return bits.join(" · ");
}

// ---------- ① 제안 ----------
function renderOffer() {
  const { ctx } = app.state.pending;
  const A = eng.act(app.state.act);
  const gateNote = ctx.isGate
    ? `<div class="gate-banner">결산 쇼케이스 — 등급 ${gateGrade(A)} 이상 + 명성 ${A.gate.min_fame} 이상이면 1막 통과. 돌발 카드 ${A.gate.events_per_show ?? A.events_per_show}장.</div>` : "";
  return `${topBar()}<section class="stack">
    <div><div class="eyebrow">① 제안</div><h2>${ctx.isGate ? "마지막 무대다" : "다음 공연을 고른다"}</h2></div>
    ${tip("offer")}
    ${gateNote}
    <div class="grid-cards">${ctx.offers.map((o, i) => `<button class="card pick" data-act="offer" data-i="${i}">
      <div class="eyebrow">요즘 뜨는 장르 <span class="genre-${o.trend}">${GENRE_NAME[o.trend]}</span></div>
      <h3 style="font-size:24px">${esc(o.name)}</h3>
      <div class="muted" style="font-size:13px">${offerSummary(o)}</div>
      <div style="font-size:13px;margin-top:6px">공연 테마를 이 장르로 잡으면 수요 +${B.demand.trend_demand_pct}%</div>
    </button>`).join("")}</div>
    <div><div class="eyebrow">이번 섭외 시장 (제안과 무관하게 같다)</div></div>
    <div class="grid-cards">${ctx.market.map((id) => `<div class="card">${artistCard(id)}</div>`).join("")}</div>
  </section>`;
}

// ---------- ② 준비 ----------
function planCtx() {
  const s = app.state, A = eng.act(s.act), { ctx } = s.pending;
  return { s, A, ctx, offer: ctx.offers[app.plan.offer], M: eng.collectMods(s.cards) };
}

const WARN_TEXT = {
  security: "보안 인원이 모자랄 것 같다", toilet_queue: "화장실 줄이 길어질 것 같다", bar_queue: "바 줄이 길어질 것 같다",
  opener: "오프닝 없이 빈 무대로 시작한다", opener_theme: "오프닝이 테마와 다른 장르다", price_over: "티켓값이 라인업 적정가보다 비싸다",
  empty_room: "장소에 비해 관객이 적다", sound: "장소 음향이 나쁘다",
};

function stepper(label, key, grp, v, lo, hi, note, warnKey, pv) {
  const w = pv && pv.warnings.find((x) => x.key === warnKey);
  return `<div class="stepper"><div><b>${label}</b></div>
    <div class="ctl"><button aria-label="${label} 줄이기" data-act="step" data-grp="${grp}" data-k="${key}" data-d="-1" ${v <= lo ? "disabled" : ""}>−</button>
    <span class="v">${v}</span>
    <button aria-label="${label} 늘리기" data-act="step" data-grp="${grp}" data-k="${key}" data-d="1" ${v >= hi ? "disabled" : ""}>+</button></div>
    <div class="note muted">${note}</div>
    ${w ? `<div class="note warn-line">! ${WARN_TEXT[warnKey]} (예상 ${signed(w.value)})</div>` : ""}</div>`;
}

function renderPlan() {
  const { s, A, ctx, offer, M } = planCtx();
  const p = app.plan;
  const venue = eng.VENUES.get(p.venue);
  const hasHead = p.headliners.length > 0;
  const pv = hasHead ? eng.preview(s, p) : null;
  const slots = { head: A.lineup.headliner_slots + eng.rule(M, "headliner_slots"), open: A.lineup.opener_slots };

  const M0 = eng.collectMods([]);
  const baseFee = (v) => eng.cost(M0, A, offer, v, { ...p, venue: v.id }).venue;
  const venues = eng.actVenues(A.id).map((v) => {
    const fee = eng.cost(M, A, offer, v, { ...p, venue: v.id }).venue;
    return `<button class="card pick ${v.id === p.venue ? "on" : ""}" data-act="venue" data-id="${v.id}" aria-pressed="${v.id === p.venue}">
      <div class="row" style="justify-content:space-between"><b>${esc(v.name)}</b><span>${v.traits.map((t) => `<span class="badge">${TRAIT_NAME[t]}</span>`).join(" ")}</span></div>
      <div class="facts num"><span>${v.capacity}명</span><span>${won(fee)}${fee !== baseFee(v) ? ` <s class="muted">${baseFee(v)}</s>` : ""}</span><span>음향 ${signed(v.sound)}</span><span>화장실 ${v.toilets}</span><span>바 ${v.bar_slots}</span>${v.demand_pct ? `<span>집객 ${signed(v.demand_pct)}%</span>` : ""}</div></button>`;
  }).join("");

  const artists = ctx.market.map((id) => {
    const isH = p.headliners.includes(id), isO = p.openers.includes(id);
    const hFull = !isH && p.headliners.length >= slots.head;
    const oFull = !isO && p.openers.length >= slots.open;
    const btns = `<div class="artist-actions">
      <button data-act="head" data-id="${id}" class="${isH ? "on" : ""}" aria-pressed="${isH}" ${isO || (hFull && slots.head > 1) ? "disabled" : ""}>헤드라이너</button>
      ${slots.open ? `<button data-act="open" data-id="${id}" class="${isO ? "on" : ""}" aria-pressed="${isO}" ${isH || (oFull && slots.open > 1) ? "disabled" : ""}>오프닝</button>` : ""}</div>`;
    const fit = eng.ARTISTS.get(id).genre === p.theme ? `<div class="good-line" style="margin-top:4px">테마 장르</div>` : "";
    return `<div class="card ${isH || isO ? "pick on" : ""}">${artistCard(id, fit + btns)}</div>`;
  }).join("");

  const themes = DATA.artists.genres.map((g) => {
    const n = ctx.market.filter((id) => eng.ARTISTS.get(id).genre === g.id).length;
    return `<button data-act="theme" data-id="${g.id}" class="${p.theme === g.id ? "on" : ""}" aria-pressed="${p.theme === g.id}">
      ${g.name}<small>${g.id === offer.trend ? "트렌드 · " : ""}시장 ${n}팀</small></button>`;
  }).join("");
  // 테마 관련 안내는 엔진 미리보기 값(themeMatch, opener_theme 경고)만 쓴다 — 규칙을 화면에서 다시 계산하지 않는다
  const offTheme = [];
  if (pv && !pv.themeMatch) offTheme.push(`헤드라이너가 ${GENRE_NAME[p.theme]} 장르가 아니다 — 테마 보너스를 놓친다`);
  const ot = pv && pv.warnings.find((x) => x.key === "opener_theme");
  if (ot) offTheme.push(`${WARN_TEXT.opener_theme} (예상 ${signed(ot.value)})`);
  const sec = eng.staffRow("security", A.id), bar = eng.staffRow("bar", A.id), toi = eng.facRow("toilet", A.id);
  const units = pv ? pv.units : null;
  const steppers = [
    stepper("보안", "security", "staff", p.staff.security, eng.staffMin(A, "security"), eng.staffMax(A, "security", venue, p),
      `1명 ${won(sec.wage)} · 1명이 ${sec.cover}명 감당${units && units.security !== p.staff.security ? ` · 카드 지원 포함 ${units.security}명` : ""}`, "security", pv),
    stepper("바텐더", "bar", "staff", p.staff.bar, eng.staffMin(A, "bar"), eng.staffMax(A, "bar", venue, p),
      `1명 ${won(bar.wage)} · 구간마다 ${bar.serve}잔 · 이 장소 최대 ${venue.bar_slots}명`, "bar_queue", pv),
    stepper("화장실 추가", "toilet", "fac", p.fac.toilet, 0, eng.facMax(A, "toilet"),
      `1칸 ${won(toi.cost)} · 장소 기본 ${venue.toilets}칸 · 1칸이 구간마다 ${toi.serve}명`, "toilet_queue", pv),
  ].join("");

  const prices = A.price_levels.map((lv, i) => `<button data-act="price" data-i="${i}" class="${p.price === i ? "on" : ""}" aria-pressed="${p.price === i}">
    <span class="num">${lv.price}만원</span><small>수요 ${lv.demand_pct}%</small></button>`).join("");
  const priceWarn = pv && pv.warnings.find((x) => x.key === "price_over");

  return `${topBar()}<div class="stack">
    <div class="offer-bar"><span class="eyebrow">② 준비</span><b>${esc(offer.name)}</b>
      <span>트렌드 <span class="genre-${offer.trend}">${GENRE_NAME[offer.trend]}</span></span><span class="muted" style="font-size:13px">${offerSummary(offer)}</span>
      <span class="spacer" style="flex:1"></span>${ctx.isGate ? "" : `<button class="chip-btn" data-act="back-offer">제안 다시 고르기</button>`}</div>
    ${tip("plan")}
    ${activeCardsStrip(s)}
    <div class="plan-grid"><div class="stack" style="gap:28px">
      <section class="sec"><div class="sec-h"><span class="n">0</span><h3>공연 테마</h3><span class="muted" style="font-size:13px">헤드라이너가 테마 장르면 수요 +${B.demand.theme_demand_pct}%·만족 +${B.lines.theme_match} · 트렌드와 같으면 수요 +${B.demand.trend_demand_pct}% · 오프닝이 다른 장르면 만족 ${B.lines.opener_off_theme}</span></div>
        <div class="seg">${themes}</div></section>
      <section class="sec"><div class="sec-h"><span class="n">1</span><h3>장소</h3></div><div class="grid-cards">${venues}</div></section>
      <section class="sec"><div class="sec-h"><span class="n">2</span><h3>라인업</h3><span class="muted" style="font-size:13px">헤드라이너 ${slots.head}명(필수) · 오프닝 ${slots.open}명까지</span></div>
        <div class="grid-cards">${artists}</div>
        ${pv && pv.warnings.find((x) => x.key === "opener") ? `<div class="warn-line">! ${WARN_TEXT.opener} (예상 ${signed(B.lines.opener.none)})</div>` : ""}
        ${offTheme.map((t) => `<div class="warn-line">! ${t}</div>`).join("")}</section>
      <section class="sec"><div class="sec-h"><span class="n">3·4</span><h3>시설 · 인력</h3></div>${steppers}</section>
      <section class="sec"><div class="sec-h"><span class="n">5</span><h3>티켓</h3></div><div class="seg">${prices}</div>
        ${priceWarn ? `<div class="warn-line">! ${WARN_TEXT.price_over} (예상 ${signed(priceWarn.value)})</div>` : ""}</section>
    </div>
    ${previewPanel(pv)}</div></div>
    ${dock(pv)}`;
}

// 이번 공연에 적용되는 보유 카드
function activeCardsStrip(s) {
  const act = s.cards.filter((c) => eng.isActive(c) || c.duration.type === "charges");
  if (!act.length) return "";
  return `<div class="cardstrip"><span class="eyebrow">적용 중인 카드</span>${act.map((c) =>
    `<span class="cchip ${c.rarity}" title="${esc(effectLines(c).join(" · "))}">${esc(c.name)}<small>${esc(effectLines(c)[0] || "")}</small></span>`).join("")}</div>`;
}

// 카드가 없었을 때와 비교한 효과(엔진을 카드 없이 한 번 더 부른다 — 규칙은 다시 계산하지 않는다)
function cardDelta(pv) {
  const s = app.state;
  if (!pv || !s.cards.length) return "";
  const bare = eng.preview({ ...s, cards: [] }, app.plan);
  const bits = [];
  const dc = bare.cost.total - pv.cost.total;
  if (dc) bits.push(`비용 ${dc > 0 ? "−" : "+"}${Math.abs(dc)}만원`);
  const da = pv.attMid - bare.attMid;
  if (da) bits.push(`예상 관객 ${signed(da)}명`);
  const dw = bare.warnings.length - pv.warnings.length;
  if (dw > 0) bits.push(`경고 ${dw}개 해소`);
  return bits.length ? `<div class="good-line">카드 효과: ${bits.join(" · ")}</div>` : "";
}

function blockReason(pv) {
  if (!app.plan.headliners.length) return "헤드라이너를 고르세요";
  if (pv && pv.errors.includes("budget")) return "예산 초과 — 자금 + 외상 한도를 넘는다";
  if (pv && pv.errors.length) return "계획을 확인하세요";
  return null;
}

function previewPanel(pv) {
  const s = app.state, A = eng.act(s.act);
  if (!pv) return `<aside class="preview"><div class="eyebrow">예상치 미리보기</div><p class="muted">헤드라이너를 고르면 예상 관객과 비용, 위험 경고가 여기에 뜬다.</p></aside>`;
  const after = s.funds - pv.cost.total;
  const credit = after < 0 ? `<span class="warn-line">외상 ${won(-after)} (한도 ${won(A.credit_limit)})</span>` : `<span class="muted">정산 전 잔액 ${won(after)}</span>`;
  const warns = pv.warnings.length
    ? pv.warnings.map((w) => `<div class="warn-line">! ${WARN_TEXT[w.key] || w.key} <span class="num">${signed(w.value)}</span></div>`).join("")
    : `<div class="good-line">경고 없음</div>`;
  const POS = { headliner: "헤드라이너 무대", opener: "오프닝 무대", theme: "테마 일치", sold_out: "매진 예상", sound: "좋은 음향", base_bonus: "운영 감각" };
  const pos = pv.positives.map((k) => POS[k] || k);
  if (pv.trendMatch) pos.push(`트렌드 일치(수요 +${B.demand.trend_demand_pct}%)`);
  const reason = blockReason(pv);
  return `<aside class="preview" aria-live="polite">
    <div class="eyebrow">예상치 미리보기</div>
    <div><div class="muted" style="font-size:13px">예상 관객 (수용 ${pv.capacity})</div><div class="big-range">${pv.attLow}–${pv.attHigh}<span style="font-size:15px">명</span></div></div>
    <div class="meter-row"><span>비용 합계</span><b class="num">${won(pv.cost.total)}</b></div>
    ${cardDelta(pv)}
    <div style="font-size:13px">${credit}</div>
    <div class="meter-row"><span>손익분기 관객</span><b class="num">${pv.breakEven}명</b></div>
    <div class="meter-row muted"><span>1명/1칸당 관객</span><span class="num">바 ${pv.perStaff.bar ?? "−"} · 화장실 ${pv.perStaff.toilet ?? "−"} · 보안 ${pv.perStaff.security ?? "−"}</span></div>
    <div class="stack" style="gap:4px">${warns}</div>
    ${pos.length ? `<div class="good-line">좋은 점: ${pos.join(", ")}</div>` : ""}
    <div class="muted" style="font-size:12px">예상 만족도는 공연이 끝나야 안다.</div>
    <button class="btn hot" data-act="go" ${reason ? "disabled" : ""}>${reason || "개최한다"}</button>
  </aside>`;
}

function dock(pv) {
  const reason = blockReason(pv);
  const info = pv
    ? `예상 <b>${pv.attLow}–${pv.attHigh}</b>명 · 비용 <b>${pv.cost.total}</b> · 경고 <b>${pv.warnings.length}</b>`
    : "헤드라이너를 고르세요";
  return `<div class="dock"><div class="info">${info}</div><button class="btn" data-act="go" ${reason ? "disabled" : ""}>${reason ? "준비 중" : "개최"}</button></div>`;
}

// ---------- ③ 개최 ----------
function startLive() {
  app.preShow = app.state; // '이랬다면' 계산용(공연 전 상태)
  app.sim = eng.startShow(app.state, app.plan);
  app.choices = [];
  app.beats = [];
  app.screen = "show";
  app.playing = true;
  render();
  schedule(500);
}

function schedule(ms) {
  clearTimeout(app.timer);
  if (!app.playing) return;
  app.timer = setTimeout(tick, ms / app.speed);
}

function tick() {
  if (app.screen !== "show") return;
  const b = app.sim.advance();
  if (b.kind === "event") { app.pendingBeat = b; renderShowParts(); return; }
  if (b.kind === "segment") { app.beats.push(b); renderShowParts(); schedule(1500); return; }
  finishLive();
}

function chooseEvent(id) {
  app.sim.choose(id);
  app.choices.push(id);
  app.pendingBeat = null;
  renderShowParts();
  schedule(500);
}

function finishLive() {
  clearTimeout(app.timer);
  app.state = eng.finishShow(app.state, app.sim);
  app.sim = null; app.anim = null; app.floatedBeats = 0;
  app.screen = "result";
  render();
}

function skipShow() {
  // 다음 돌발 카드나 끝까지 바로 진행
  clearTimeout(app.timer);
  for (;;) {
    const b = app.sim.advance();
    if (b.kind === "event") { app.pendingBeat = b; break; }
    if (b.kind === "segment") { app.beats.push(b); continue; }
    finishLive();
    return;
  }
  renderShowParts();
}

const LINE_LABEL = {
  price_over: "티켓값", opener: "오프닝", opener_theme: "오프닝 장르", sound: "음향", headliner: "헤드라이너", theme: "테마 일치",
  empty_room: "빈 자리", sold_out: "매진", bar_queue: "바 줄", toilet_queue: "화장실 줄", security: "보안",
  base_bonus: "운영 감각", food_queue: "푸드 줄", cleaning: "청소", medical: "의료",
};
const lineLabel = (k) => (k.startsWith("event:") ? EVENT_BY_ID[k.slice(6)]?.name || k : LINE_LABEL[k] || k);

function renderShow() {
  const S = app.sim.S;
  return `${topBar()}<section class="stack">
    <div><div class="eyebrow">③ 개최 · ${esc(S.offer.name)} · ${esc(S.venue.name)}</div>
      <h2>${esc(S.H.map((h) => h.name).join(" · "))}${S.O.length ? ` <span class="muted" style="font-size:18px">with ${esc(S.O.map((o) => o.name).join(", "))}</span>` : ""}</h2></div>
    ${tip("show")}
    <div class="timeline" id="tl"></div>
    <div class="show-grid">
      <div class="stack">
        <div class="stage-box"><canvas id="stage" width="800" height="500" role="img" aria-label="공연장 모습: 무대, 관객, 바와 화장실 줄"></canvas><div class="floats" id="floats" aria-hidden="true"></div></div>
        <div class="live" id="live"></div>
      </div>
      <div class="stack">
        <div class="mood" id="mood"></div>
        <div class="feed" id="feed" aria-live="polite"></div>
        <div class="controls">
          <button data-act="play">${app.playing ? "일시정지" : "재생"}</button>
          ${[1, 2, 4].map((x) => `<button data-act="speed" data-x="${x}" class="${app.speed === x ? "on" : ""}" aria-pressed="${app.speed === x}">${x}×</button>`).join("")}
          <button data-act="skip">건너뛰기</button>
        </div>
      </div>
    </div>
  </section><div id="modal"></div>`;
}

function renderShowParts() {
  const sim = app.sim;
  if (!sim) return;
  const S = sim.S, segs = S.A.segments;
  const last = app.beats[app.beats.length - 1];
  const doneN = app.beats.length;
  const tl = document.getElementById("tl");
  if (!tl) return;
  tl.innerHTML = segs.map((g, i) => `<div class="${i < doneN - 1 ? "done" : i === doneN - 1 ? "now" : ""}">${g.name}</div>`).join("");
  const mood = last ? last.mood : B.satisfaction.base;
  const ticks = B.grades.filter((g) => g.min > 0);
  document.getElementById("mood").innerHTML = `<div class="eyebrow">분위기</div><div class="val num">${mood}</div>
    <div class="mood-bar"><i style="width:${mood}%"></i>${ticks.map((g) => `<s style="left:${g.min}%"></s>`).join("")}</div>
    <div class="mood-ticks">${ticks.map((g) => `<span style="left:${g.min}%">${g.id}</span>`).join("")}</div>`;
  const feed = [];
  for (const b of app.beats) {
    for (const l of b.lines) feed.push(`<div><span class="d ${l.value > 0 ? "pos" : "neg"}">${signed(l.value)}</span><span>${esc(segs.find((g) => g.id === b.seg).name)} · ${esc(lineLabel(l.key))}</span></div>`);
  }
  document.getElementById("feed").innerHTML = feed.length ? feed.join("") : `<p class="muted" style="margin:0">문이 열리기를 기다린다…</p>`;
  const cumMiss = (k) => app.beats.reduce((s, b) => s + (b[k] || 0), 0);
  const barSold = app.beats.reduce((s, b) => s + b.barServed, 0);
  document.getElementById("live").innerHTML = `
    <div><small>입장</small><b>${last ? last.present : 0}</b> / ${S.att}명</div>
    <div><small>바 판매 (잔)</small><b>${barSold}</b></div>
    <div><small>화장실 못 간 사람</small><b>${cumMiss("toiMiss")}</b>명</div>
    <div><small>보안 부담 / 감당</small><b>${last ? last.load : 0}</b> / ${last ? last.cover : 0}</div>`;
  // 새로 실현된 줄을 무대 위에 띄운다
  if (reduceMotion) app.floatedBeats = app.beats.length; // 움직임 줄이기: 떠오르는 숫자 없음
  if (app.beats.length > (app.floatedBeats || 0)) {
    const fl = document.getElementById("floats");
    const nb = app.beats.slice(app.floatedBeats || 0);
    app.floatedBeats = app.beats.length;
    if (fl) {
      let k = 0;
      for (const b of nb) for (const l of b.lines) {
        const el = document.createElement("span");
        el.className = `float ${l.value > 0 ? "pos" : "neg"}`;
        el.style.left = `${20 + ((k * 23) % 60)}%`;
        el.style.animationDelay = `${k * 0.25}s`;
        el.textContent = `${signed(l.value)} ${lineLabel(l.key)}`;
        el.addEventListener("animationend", () => el.remove());
        fl.appendChild(el);
        k++;
      }
    }
  }
  app.anim = app.anim || { from: 0, to: 0, t0: 0 };
  const target = last ? last.present : 0;
  if (target !== app.anim.to) app.anim = { from: app.anim.shownNow ?? app.anim.to, to: target, t0: performance.now() };
  if (!app.raf) loopStage();
  const pb = app.pendingBeat;
  document.getElementById("modal").innerHTML = pb ? eventModal(pb) : "";
  if (pb) document.querySelector(".modal .choice")?.focus();
  const playBtn = document.querySelector('[data-act="play"]');
  if (playBtn) playBtn.textContent = app.playing ? "일시정지" : "재생";
}

function effectSummary(effects, sh) {
  if (sh) return "대비 카드를 1회 써서 피해 없이 넘긴다";
  if (!effects.length) return "아무 일도 없다";
  const t = [];
  for (const e of effects) {
    if (e.type === "money") t.push(`돈 ${e.value < 0 ? "−" + won(-e.value) : "+" + won(e.value)}`);
    if (e.type === "sat") t.push(`만족 ${signed(e.value)}`);
    if (e.type === "fame") t.push(`명성 ${signed(e.value)}`);
    if (e.type === "seg_pct") t.push(`이후 ${e.key === "cap.bar" ? "바" : "화장실"} 처리량 ${signed(e.value)}%`);
    if (e.type === "seg_add") t.push(`이후 ${{ "units.security": "보안", "units.toilet": "화장실", "units.bar": "바텐더" }[e.key]} ${signed(e.value)}`);
  }
  return t.join(" · ");
}

function eventModal(b) {
  const e = b.event;
  const seg = app.sim.S.A.segments.find((g) => g.id === b.seg).name;
  return `<div class="modal-bg"><div class="modal" role="dialog" aria-modal="true" aria-labelledby="ev-title">
    <div class="eyebrow">돌발 · ${seg}</div><h2 id="ev-title">${esc(e.name)}</h2><p style="margin:0">${esc(e.text)}</p>
    <div class="stack" style="gap:8px">${b.options.map((o) => `<button class="choice" data-act="choose" data-id="${o.id}">
      <b>${esc(o.label)}</b><small>${effectSummary(o.effects, o.id === "__shield")}</small></button>`).join("")}</div>
    <div class="muted" style="font-size:12px">현재 자금 ${won(app.state.funds)} · 돈은 공연 뒤 정산된다</div>
  </div></div>`;
}

function loopStage() {
  const step = (t) => {
    if (app.screen !== "show" || !app.sim) { app.raf = null; return; }
    drawStage(app.sim.S, app.beats[app.beats.length - 1], t);
    app.raf = reduceMotion ? null : requestAnimationFrame(step);
  };
  app.raf = requestAnimationFrame(step);
}

// 공연장 그림: 무대(위) · 관객 점(가운데) · 바(왼쪽 아래) · 화장실(오른쪽 아래). 점은 분홍/파랑 겹찍기.
// 관객 수는 부드럽게 늘고, 점은 구간 열기·분위기만큼 들썩인다. 헤드라이너 구간엔 조명이 돈다.
function drawStage(S, last, t = 0) {
  const cv = document.getElementById("stage");
  if (!cv) return;
  const ctx = cv.getContext("2d");
  const W = cv.width, H = cv.height;
  const css = getComputedStyle(document.documentElement);
  const col = (n) => css.getPropertyValue(n).trim();
  ctx.clearRect(0, 0, W, H);
  ctx.fillStyle = col("--card"); ctx.fillRect(0, 0, W, H);
  // 무대
  const curSeg = last ? S.A.segments.find((g) => g.id === last.seg) : null;
  const onStage = curSeg?.stage === "headliner" ? S.H.map((h) => h.name).join(" · ") : curSeg?.stage === "opener" ? (S.O[0]?.name || "빈 무대") : "";
  ctx.fillStyle = col("--ink"); ctx.fillRect(W * 0.18, 18, W * 0.64, 70);
  ctx.fillStyle = col("--paper"); ctx.font = `28px ${col("--f-display")}`; ctx.textAlign = "center"; ctx.textBaseline = "middle";
  ctx.fillText(onStage || (last ? (curSeg ? curSeg.name : "") : "개장 전"), W / 2, 54);
  // 관객
  const present = last ? last.present : 0;
  const cap = S.venue.capacity;
  const an = app.anim || { from: present, to: present, t0: 0 };
  const k = reduceMotion ? 1 : Math.min(1, (t - an.t0) / 900);
  const nowPresent = an.from + (an.to - an.from) * k;
  an.shownNow = nowPresent;
  const shown = Math.round((nowPresent / cap) * 360);
  const heat = curSeg ? curSeg.heat_pct / 100 : 0.3;
  const mood = last ? last.mood : B.satisfaction.base;
  const amp = reduceMotion ? 0 : heat * (mood / 60) * 4;
  if (curSeg?.stage === "headliner" && !reduceMotion) {
    // 무대 조명
    ctx.save();
    ctx.globalAlpha = 0.16;
    for (let i = 0; i < 3; i++) {
      const ang = Math.sin(t / 700 + i * 2.1) * 0.6;
      const x0 = W * (0.3 + i * 0.2), y0 = 88;
      ctx.fillStyle = i % 2 ? col("--blue") : col("--pink");
      ctx.beginPath(); ctx.moveTo(x0, y0);
      ctx.lineTo(x0 + Math.sin(ang - 0.18) * 420, y0 + Math.cos(ang - 0.18) * 420);
      ctx.lineTo(x0 + Math.sin(ang + 0.18) * 420, y0 + Math.cos(ang + 0.18) * 420);
      ctx.closePath(); ctx.fill();
    }
    ctx.restore();
  }
  const rng = mulberry32(S.state.seed + S.state.show_idx * 31);
  const pts = Array.from({ length: 360 }, () => [W * 0.1 + rng.int(Math.floor(W * 0.8)), 110 + rng.int(Math.floor(H * 0.52))]);
  // 무대 쪽으로 몰리도록 정렬
  pts.sort((a, b) => a[1] - b[1]);
  ctx.globalCompositeOperation = col("--blend") === "screen" ? "screen" : "multiply";
  for (let i = 0; i < shown; i++) {
    const [x, y0] = pts[i];
    const y = y0 + Math.sin(t / 180 + i * 1.7) * amp;
    ctx.fillStyle = col("--pink"); ctx.beginPath(); ctx.arc(x, y, 7, 0, 7); ctx.fill();
    ctx.fillStyle = col("--blue"); ctx.beginPath(); ctx.arc(x + 3, y + 2, 7, 0, 7); ctx.fill();
  }
  ctx.globalCompositeOperation = "source-over";
  // 바·화장실 줄
  const zone = (x, label, served, miss) => {
    ctx.strokeStyle = col("--ink"); ctx.lineWidth = 3; ctx.strokeRect(x, H - 100, 180, 76);
    ctx.fillStyle = col("--ink"); ctx.font = `20px ${col("--f-display")}`; ctx.textAlign = "left"; ctx.fillText(label, x + 12, H - 80);
    ctx.font = `16px ${col("--f-num")}`;
    ctx.fillText(served, x + 12, H - 52);
    if (miss > 0) { ctx.fillStyle = col("--warn"); ctx.fillText(`못 감 ${miss}`, x + 12, H - 32); }
  };
  zone(24, "바", last ? `${last.barServed}/${last.barDem}잔` : "–", last ? last.barDem - last.barServed : 0);
  zone(W - 204, "화장실", last ? `${Math.min(last.toiDem, last.toiCap)}/${last.toiDem}명` : "–", last ? last.toiMiss : 0);
  // 보안 상태
  ctx.textAlign = "center"; ctx.font = `16px ${col("--f-num")}`;
  const over = last && last.secOver > 0;
  ctx.fillStyle = over ? col("--warn") : col("--muted");
  ctx.fillText(last ? `보안 ${last.load}/${last.cover}${over ? " 초과" : ""}` : `수용 ${cap}명`, W / 2, H - 36);
}

// ---------- ④ 결과 ----------
function reasonText(l, res) {
  const plan = res.plan, A = eng.act(res.act);
  const H = plan.headliners.map((id) => eng.ARTISTS.get(id));
  const v = eng.VENUES.get(res.venue);
  const maxLoad = Math.max(...res.segs.map((s) => s.load));
  const k = l.key;
  if (k.startsWith("event:")) {
    const ev = res.events.find((e) => "event:" + e.event === k);
    const e = EVENT_BY_ID[k.slice(6)];
    const c = e.choices.find((x) => x.id === ev?.choice);
    return [`${e.name} — ${c ? c.label : "대비 카드 사용"}`, "돌발 카드 선택"];
  }
  const T = {
    price_over: [`티켓 ${A.price_levels[plan.price].price}만원 > 적정가 ${Math.max(...H.map((h) => h.fair_price))}만원`, "→ 티켓 가격"],
    opener: [plan.openers.length ? `오프닝 ${plan.openers.map((id) => eng.ARTISTS.get(id).name).join(", ")}` : "빈 무대로 시작", "→ 오프닝 섭외"],
    sound: [`${v.name} 음향`, "→ 장소"],
    headliner: [`헤드라이너 ${H.map((h) => h.name).join(", ")} (실력 ${Math.max(...H.map((h) => h.skill))})`, "→ 헤드라이너"],
    theme: [`${GENRE_NAME[plan.theme]} 테마에 맞는 헤드라이너`, "→ 테마·헤드라이너"],
    opener_theme: [`오프닝이 ${GENRE_NAME[plan.theme]} 테마와 다른 장르`, "→ 테마·오프닝"],
    empty_room: [`${v.capacity}석에 ${res.att}명`, "→ 장소 크기"],
    sold_out: [`매진 (${res.demand}명이 오려 했다)`, "→ 장소 크기·가격"],
    bar_queue: [`바에서 못 산 사람 ${res.miss.bar_queue}명`, "→ 바텐더 수"],
    toilet_queue: [`화장실 못 간 사람 ${res.miss.toilet_queue}명`, "→ 화장실 칸 수"],
    security: [`보안 부담 최대 ${maxLoad}명, 감당 ${res.segs.find((s) => s.load === maxLoad).cover}명 (보안 ${plan.staff.security}명 배치)`, "→ 보안 인원"],
    base_bonus: ["운영 감각 (보상 카드)", ""],
  };
  return T[k] || [lineLabel(k), ""];
}

// '이랬다면': 가장 큰 감점 원인의 결정 하나만 바꿔 공연 전 상태로 다시 계산(분산 0·돌발 없음 기준, 엔진 evaluate)
const WHATIF = {
  security: { grp: "staff", k: "security", d: 1, name: "보안", unit: "명" },
  toilet_queue: { grp: "fac", k: "toilet", d: 1, name: "추가 화장실", unit: "칸" },
  bar_queue: { grp: "staff", k: "bar", d: 1, name: "바텐더", unit: "명" },
  price_over: { k: "price", d: -1, name: "티켓 가격 단계", unit: "" },
};
function whatIf(res) {
  const pre = app.preShow;
  if (!pre || pre.show_idx !== res.show_idx) return "";
  const A = eng.act(res.act);
  const worst = res.lines.find((l) => l.value < 0 && WHATIF[l.key]);
  if (!worst) return "";
  const w = WHATIF[worst.key];
  const base = eng.evaluate(pre, res.plan, 0);
  const venue = eng.VENUES.get(res.plan.venue);
  const max = w.k === "price" ? A.price_levels.length - 1 : w.grp === "staff" ? eng.staffMax(A, w.k, venue, res.plan) : eng.facMax(A, w.k);
  const get = (p) => (w.k === "price" ? p.price : p[w.grp][w.k]);
  let best = null;
  for (let n = 1; n <= 6; n++) {
    const q = JSON.parse(JSON.stringify(res.plan));
    const v = get(res.plan) + w.d * n;
    if (v < 0 || v > max) break;
    if (w.k === "price") q.price = v; else q[w.grp][w.k] = v;
    if (eng.validatePlan(pre, q).length) break;
    const ev = eng.evaluate(pre, q, 0);
    best = { q, ev, v };
    if (!ev.lines.some((l) => l.key === worst.key)) break;
  }
  if (!best || best.ev.satisfaction <= base.satisfaction) return "";
  const from = get(res.plan), to = best.v;
  const label = w.k === "price" ? `티켓 ${A.price_levels[from].price}만원 → ${A.price_levels[to].price}만원` : `${w.name} ${from}${w.unit} → ${to}${w.unit}`;
  return `<div class="whatif"><span class="eyebrow">이랬다면</span>
    <div><b>${label}</b> — 만족도 ${base.satisfaction} → <b>${best.ev.satisfaction}</b> (${base.grade} → ${best.ev.grade}), 수지 ${signed(best.ev.profit - base.profit)}만원</div>
    <small class="muted">돌발 카드·수요 변동을 뺀 같은 조건 비교</small></div>`;
}

function countUp() {
  document.querySelectorAll("[data-count]").forEach((el) => {
    const to = +el.dataset.count;
    if (reduceMotion) { el.textContent = signed0(to, el.dataset.sign); return; }
    const t0 = performance.now();
    const f = (t) => {
      const k = Math.min(1, (t - t0) / 700);
      el.textContent = signed0(Math.round(to * (1 - Math.pow(1 - k, 3))), el.dataset.sign);
      if (k < 1) requestAnimationFrame(f);
    };
    requestAnimationFrame(f);
  });
}
function signed0(n, sign) { return sign ? signed(n) : String(n); }

function renderResult() {
  const s = app.state, res = s.pending.res;
  const A = eng.act(res.act);
  const reasons = res.lines.slice(0, 5).map((l) => {
    const [t, fix] = reasonText(l, res);
    return `<div><span class="d ${l.value > 0 ? "pos" : "neg"}">${signed(l.value)}</span><span>${esc(t)}${fix ? `<div class="fix">${fix}</div>` : ""}</span></div>`;
  }).join("");
  let gate = "";
  if (res.isGate) {
    gate = res.gatePass ? `<div class="gate-banner ok">결산 통과 — 등급 ${res.grade}, 명성 ${s.fame}</div>`
      : `<div class="gate-banner no">결산 실패 — 필요: 등급 ${gateGrade(A)} 이상 + 명성 ${A.gate.min_fame} 이상</div>`;
  }
  const next = s.phase === "reward" ? `<button class="btn hot" data-act="to-reward">보상 고르기</button>` : `<button class="btn hot" data-act="to-over">런 결과 보기</button>`;
  return `${topBar()}<section class="stack" style="gap:20px">
    <div class="eyebrow">④ 결과 · ${esc(res.offer.name)}</div>
    <div class="result-head"><div class="stamp ${reduceMotion ? "" : "stamp-in"}" aria-label="등급 ${res.grade}"><span class="a">${res.grade}</span><span class="b" aria-hidden="true">${res.grade}</span></div>
      <div><h2>${{ S: "전설로 남을 밤", A: "모두가 다시 오고 싶어 한다", B: "괜찮은 밤이었다", C: "아쉬운 소리가 들린다", D: "다들 일찍 떠났다" }[res.grade]}</h2>
      <div class="muted">명성 ${res.fameBefore} → <b>${s.fame}</b> (${signed(res.fameDelta)}) · 자금 ${won(res.fundsBefore)} → <b>${won(s.funds)}</b></div></div></div>
    <div class="trio"><div><small>관객</small><b data-count="${res.att}">${res.att}</b><span class="muted"> / ${res.capacity}</span></div>
      <div><small>만족도</small><b data-count="${res.satisfaction}">${res.satisfaction}</b></div>
      <div><small>수지</small><b class="${res.profit < 0 ? "neg" : "pos"}" data-count="${res.profit}" data-sign="1">${signed(res.profit)}</b><span class="muted">만원</span></div></div>
    ${gate}
    ${tip("result")}
    <div><div class="eyebrow">원인 리뷰 (기준 ${B.satisfaction.base}에서)</div><div class="reasons">${reasons || `<div class="muted">특별한 일 없이 끝났다.</div>`}</div></div>
    ${whatIf(res)}
    <details><summary>수지 내역</summary><dl class="kv" style="margin-top:8px">
      <dt>티켓</dt><dd>+${res.ticket}</dd><dt>바</dt><dd>+${res.bar}</dd>${res.sponsor ? `<dt>협찬</dt><dd>+${res.sponsor}</dd>` : ""}
      <dt>비용</dt><dd>−${res.cost.total} (장소 ${res.cost.venue} · 출연료 ${res.cost.headliner + res.cost.opener} · 인력 ${Object.values(res.cost.staff).reduce((a, b) => a + b, 0)} · 시설 ${Object.values(res.cost.facility).reduce((a, b) => a + b, 0)})</dd>
      ${res.evMoney ? `<dt>돌발</dt><dd>${signed(res.evMoney)}</dd>` : ""}</dl></details>
    <div>${next}</div></section>`;
}

// ---------- ⑤ 보상 ----------
const PCT_KEY = {
  "cost.venue": "대관료", "cost.headliner": "헤드라이너 개런티", "cost.opener": "오프닝 개런티", "cost.staff": "인건비",
  "cost.staff.security": "보안 일당", "cost.staff.bar": "바텐더 일당", "cost.facility": "시설 대여비", "cost.facility.toilet": "화장실 대여비",
  "cost.facility.sound": "음향 대여비", demand: "관객 수요", "bar.price": "바 매출", "cap.bar": "바 처리량", "cap.toilet": "화장실 처리량",
  "cap.security": "보안 감당", "fame.gain": "명성 획득", "event.money": "돌발 비용",
};
const ADD_KEY = {
  "free.security": ["무료 보안", "명"], "free.bar": ["무료 바텐더", "명"], "free.toilet": ["무료 화장실", "칸"],
  "free.cleaning": ["무료 청소", "명"], "free.medical": ["무료 의료", "명"], "sat.base": ["만족도", ""], "line.sound": ["음향", ""],
};
const RULE_TEXT = { headliner_slots: "헤드라이너 슬롯 +1", bankrupt_shield: "파산 1회 면제", gate_grade_relax: "결산 등급 조건 한 단계 완화", demand_floor: "수요가 예상보다 나쁘게 나오지 않는다" };
function effectLines(c) {
  return c.effects.map((e) => {
    if (e.type === "pct") {
      const g = e.key.startsWith("demand.genre.") ? `${GENRE_NAME[e.key.slice(13)]} 헤드라이너 수요` : PCT_KEY[e.key] || e.key;
      return `${g} ${signed(e.value)}%`;
    }
    if (e.type === "add") {
      if (e.key.startsWith("pen.")) return `${LINE_LABEL[e.key.slice(4)] || e.key} 감점 ${e.value} 완화`;
      const [n, u] = ADD_KEY[e.key] || [e.key, ""];
      return `${n} ${signed(e.value)}${u}`;
    }
    if (e.type === "rule") return RULE_TEXT[e.key] || e.key;
    if (e.type === "money") return `자금 ${signed(e.value)}만원`;
    if (e.type === "fame") return `명성 ${signed(e.value)}`;
    if (e.type === "shield") return `돌발 대비: ${TAG_NAME[e.tag] || e.tag}`;
    return e.type;
  });
}
function durationText(c) {
  const d = c.duration;
  if (d.type === "run") return "런 내내";
  if (d.type === "instant") return "즉시";
  if (d.type === "uses") return `다음 공연 ${c.left ?? d.n}회`;
  if (d.type === "charges") return `${c.charges ?? d.n}회 사용`;
  return d.type;
}

function renderReward() {
  const rw = app.state.pending.rewards;
  return `${topBar()}<section class="stack">
    <div><div class="eyebrow">⑤ 보상</div><h2>한 장을 고른다</h2><div class="muted">고른 카드는 다음 공연부터 적용된다.</div></div>
    <div class="rewards">${rw.map((c, i) => `<button class="rcard ${c.rarity} ${app.pickedReward === i ? "on" : ""} ${app.revealed || reduceMotion ? "" : "flip-in"}" style="animation-delay:${i * 0.18}s" data-act="reward" data-i="${i}" aria-pressed="${app.pickedReward === i}">
      <span class="rar">${RARITY_NAME[c.rarity]} · ${KIND_NAME[c.kind]}</span><h3>${esc(c.name)}</h3>
      <ul>${effectLines(c).map((t) => `<li>${esc(t)}</li>`).join("")}</ul><span class="muted" style="font-size:13px">${durationText(c)}</span></button>`).join("")}</div>
    <div>${rw.length ? `<button class="btn hot" data-act="take" ${app.pickedReward === null ? "disabled" : ""}>이 카드를 가져간다</button>` : `<button class="btn hot" data-act="take">다음 공연으로</button>`}</div>
  </section>`;
}

// ---------- 런 종료 ----------
function renderOver() {
  const s = app.state;
  const win = s.result === "pass_act" || s.result === "clear";
  const rows = s.history.map((h, i) => `<tr><td>${i + 1}${h.isGate ? " (결산)" : ""}</td><td>${esc(h.offer.name)}</td><td>${h.grade}</td><td class="n">${h.satisfaction}</td><td class="n">${signed(h.profit)}</td></tr>`).join("");
  return `${topBar()}<section class="stack" style="gap:20px">
    <div class="eyebrow">런 종료 · 시드 <span class="num">${s.seed}</span></div>
    <div class="poster" style="font-size:clamp(40px,11vw,88px)"><span class="p1">${win ? "1막 통과" : "런 실패"}</span><span class="p2" aria-hidden="true">${win ? "1막 통과" : "런 실패"}</span></div>
    <p class="lede">${RESULT_TEXT[s.result]}.${win ? " 프로토타입은 1막까지다. 2막(공연장)은 수치를 맞추는 중이다." : ""}</p>
    <div class="trio"><div><small>공연</small><b>${s.history.length}</b></div><div><small>최종 자금</small><b>${s.funds}</b><span class="muted">만원</span></div><div><small>최종 명성</small><b>${s.fame}</b></div></div>
    ${rows ? `<div class="tbl"><table class="hist"><thead><tr><th>#</th><th>제안</th><th>등급</th><th>만족</th><th>수지</th></tr></thead><tbody>${rows}</tbody></table></div>` : ""}
    <div class="row"><button class="btn hot" data-act="new-run">새 런 시작</button><button class="btn ghost" data-act="same-run">같은 시드로 다시</button></div>
  </section>`;
}

// ---------- 타이틀 ----------
function renderTitle() {
  return `<section class="title-hero">
    <div class="eyebrow">프로토타입 · 1막 클럽</div>
    <div class="poster"><span class="p1">STAGE<br>EMPIRE</span><span class="p2" aria-hidden="true">STAGE<br>EMPIRE</span></div>
    <p class="lede">무명 프로모터로 클럽 공연을 연다. 공연마다 음악 테마와 장소·라인업·시설·인력·티켓을 정하고, 공연이 흘러가는 걸 보며 돌발 상황에 답하고, 성적표를 받는다. 공연 3번과 결산 쇼케이스 1번을 버티면 1막 통과.</p>
    <div class="steps">
      <div><b>제안</b><span class="muted">기회 카드 3장 중 하나</span></div>
      <div><b>준비</b><span class="muted">테마와 5가지 결정, 예상치 미리보기</span></div>
      <div><b>개최</b><span class="muted">자동 진행 + 돌발 카드</span></div>
      <div><b>결과</b><span class="muted">원인별 성적표</span></div>
      <div><b>보상</b><span class="muted">카드 3장 중 1장</span></div>
    </div>
    <div class="row"><button class="btn hot" data-act="new-run">새 런 시작</button></div>
    ${records.runs ? `<div class="records num"><span>지금까지 <b>${records.runs}</b>런</span><span>1막 통과 <b>${records.passes}</b>회</span><span>최고 만족도 <b>${records.bestSat}</b></span><span>최고 명성 <b>${records.bestFame}</b></span></div>` : ""}
    <p class="muted" style="font-size:13px">자금 ${B.start.funds}만원 · 명성 ${B.start.fame}에서 시작. 자금이 0 아래로 떨어지거나 명성이 0이 되면 끝난다.</p>
  </section>`;
}

// ---------- 렌더·이벤트 ----------
function render() {
  const view = { title: renderTitle, offer: renderOffer, plan: renderPlan, show: renderShow, result: renderResult, reward: renderReward, over: renderOver }[app.screen];
  $app.innerHTML = `<div class="wrap">${view()}</div>`;
  if (app.screen === "show") renderShowParts();
  if (app.screen === "result") countUp();
  if (app.lastScreen !== app.screen) { window.scrollTo(0, 0); app.lastScreen = app.screen; }
}

$app.addEventListener("click", (ev) => {
  const t = ev.target.closest("[data-act]");
  if (!t || t.disabled) return;
  const a = t.dataset.act, p = app.plan;
  switch (a) {
    case "new-run": startRun(newSeed()); break;
    case "same-run": startRun(app.seed); break;
    case "cards": app.showCards = !app.showCards; render(); break;
    case "offer": pickOffer(+t.dataset.i); break;
    case "back-offer": app.screen = "offer"; render(); break;
    case "venue": {
      p.venue = t.dataset.id;
      const v = eng.VENUES.get(p.venue);
      p.staff.bar = Math.min(p.staff.bar, eng.staffMax(eng.act(app.state.act), "bar", v, p));
      render(); break;
    }
    case "head": {
      const id = t.dataset.id;
      const slots = eng.act(app.state.act).lineup.headliner_slots + eng.rule(eng.collectMods(app.state.cards), "headliner_slots");
      if (p.headliners.includes(id)) p.headliners = p.headliners.filter((x) => x !== id);
      else if (slots === 1) p.headliners = [id];
      else if (p.headliners.length < slots) p.headliners.push(id);
      render(); break;
    }
    case "open": {
      const id = t.dataset.id;
      const slots = eng.act(app.state.act).lineup.opener_slots;
      if (p.openers.includes(id)) p.openers = p.openers.filter((x) => x !== id);
      else if (slots === 1) p.openers = [id];
      else if (p.openers.length < slots) p.openers.push(id);
      render(); break;
    }
    case "step": p[t.dataset.grp][t.dataset.k] += +t.dataset.d; render(); break;
    case "price": p.price = +t.dataset.i; render(); break;
    case "theme": p.theme = t.dataset.id; render(); break;
    case "go": startLive(); break;
    case "play": app.playing = !app.playing; if (app.playing && !app.pendingBeat) schedule(300); else clearTimeout(app.timer); renderShowParts(); break;
    case "speed": app.speed = +t.dataset.x; document.querySelectorAll('[data-act="speed"]').forEach((b) => { b.classList.toggle("on", +b.dataset.x === app.speed); b.setAttribute("aria-pressed", String(+b.dataset.x === app.speed)); }); break;
    case "skip": if (!app.pendingBeat) skipShow(); break;
    case "choose": chooseEvent(t.dataset.id); break;
    case "to-reward": app.pickedReward = null; app.revealed = false; app.screen = "reward"; render(); app.revealed = true; break;
    case "to-over": app.screen = "over"; recordRun(app.state); render(); break;
    case "tip-ok": tipsSeen[t.dataset.k] = true; saveLocal("se-v2-tips", tipsSeen); t.closest(".tip")?.remove(); break;
    case "reward": app.pickedReward = +t.dataset.i; render(); break;
    case "take": app.state = eng.chooseReward(app.state, app.pickedReward); app.pickedReward = null; nextShow(); break;
  }
});

// ---------- 다시 게시돼도 이어서 (뷰어 hot 훅) ----------
function snapshot() {
  return { screen: app.screen, state: app.state, plan: app.plan, choices: app.choices, beats: app.beats.length, speed: app.speed, seed: app.seed,
    pickedReward: app.pickedReward, preShow: app.preShow, revealed: app.revealed, runId: app.runId, recordedRun: app.recordedRun };
}
function start(saved) {
  try { restore(saved); } catch (e) {
    // 데이터가 바뀌어 저장된 상태를 되살릴 수 없으면 타이틀로 (SE-070 리뷰 M1)
    console.warn("restore failed", e);
    Object.assign(app, { screen: "title", state: null, plan: null, sim: null, pendingBeat: null, beats: [], choices: [] });
  }
  render();
}
function restore(saved) {
  if (saved && saved.state) {
    Object.assign(app, { screen: saved.screen, state: saved.state, plan: saved.plan, speed: saved.speed || 1, seed: saved.seed, pickedReward: saved.pickedReward ?? null,
      preShow: saved.preShow ?? null, revealed: saved.revealed ?? true, runId: saved.runId ?? 0, recordedRun: saved.recordedRun ?? null });
    if (app.screen === "show") {
      // 공연 중이었다면 같은 계획·같은 선택으로 다시 재생한다(엔진은 결정적)
      app.sim = eng.startShow(app.state, app.plan);
      app.beats = []; app.choices = [];
      const want = saved.beats || 0;
      const ch = [...(saved.choices || [])];
      while (app.beats.length < want) {
        const b = app.sim.advance();
        if (b.kind === "event") { if (!ch.length) { app.pendingBeat = b; break; } const c = ch.shift(); app.sim.choose(c); app.choices.push(c); continue; }
        if (b.kind === "segment") app.beats.push(b); else break;
      }
      app.playing = false;
      app.floatedBeats = app.beats.length;
    }
  }
  render();
}
// 스모크 테스트용: 정해진 시드로 런 시작
window.stageEmpireTest = { startRun: (seed) => startRun(seed), seed: () => app.seed, history: () => app.state?.history.map((h) => [h.grade, h.satisfaction, h.profit]), records: () => ({ ...records }) };
window.claude?.hot?.snapshot?.(snapshot);
if (window.claude?.hot?.ready) window.claude.hot.ready(start);
else start(window.claude?.hot?.data ?? null);
