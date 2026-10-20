# 공연 1회 (show.md)

| 항목 | 값 |
|---|---|
| 상태 | v2 1판 (SE-068). 1막 확정, 2막 이후 손잡이는 대략치(#2막-이후-손잡이) |
| 데이터 | [balance.json](data/balance.json), [acts.json](data/acts.json), [venues.json](data/venues.json), [artists.json](data/artists.json), [staff.json](data/staff.json), [facilities.json](data/facilities.json) |
| 짝 문서 | [run.md](run.md) (정수 규칙 I1~I4, RNG), [events.md](events.md) (개최 중 돌발), [rewards.md](rewards.md) (수정자 `ap`·`add`) |

## 목적

공연 한 번을 **준비(결정) → 개최(5구간 숫자 모델) → 결과(원인별 줄)** 로 계산한다. 모든 감점 줄은 준비 결정 하나로 돌아가고, 개최 중 분위기 게이지는 그 줄들이 실현되는 순간을 보여 준다.
이 문서의 의사코드만으로 SE-069 가 해석 없이 엔진을 쓸 수 있어야 한다. 정수 규칙과 `div`·`scale` 은 run.md I1~I4.

## 수정자 함수 (rewards.md 와 공용)

```
pct_sum(key) = 활성 카드의 {type:"pct", key} 값 합 (없으면 0)
mp(key, extra=0) = clamp(100 + pct_sum(key) + extra, balance.mods.pct_min(20), balance.mods.pct_max(300))
ap(x, key, extra=0) = div(x × mp(key, extra), 100)          // x ≥ 0 에만 쓴다
add(key) = 활성 카드의 {type:"add", key} 값 합 (없으면 0)
rule(key) = 활성 카드의 {type:"rule", key} 값 합
```

카드가 하나도 없으면 `ap(x, k) = x`, `add(k) = 0`. 손 계산 예시는 카드 없음.

## 준비 5기둥

준비 화면에서는 시간이 멈춰 있다. 플레이어가 정하는 것(= 계획 `plan`):

| 기둥 | 결정 | 1막 범위 | 제약 |
|---|---|---|---|
| 0. 제안 | 제안 카드 1장 | 3장 중 1 | — |
| 1. 장소 | 장소 1곳 | 그 막의 장소 5곳 | — |
| 2. 라인업 | 헤드라이너 `H[]`, 오프닝 `O[]` | 헤드라이너 1(필수), 오프닝 0~1. 시장에서만, 중복 불가 | 슬롯 수 = `acts.lineup` (+ `rule(headliner_slots)`) |
| 3. 시설 | 추가 화장실 칸 수 | 0~3 | `facilities.toilet.max` |
| 4. 인력 | 보안 인원, 바텐더 인원 | 보안 1~6, 바텐더 1~장소 `bar_slots` | `staff.min`/`max`/`max_source` |
| 5. 티켓·홍보 | 티켓 가격 단계 (2막+: 홍보 단계) | 1·2·3·4만원 중 1 | — |

1막은 손잡이 7개(제안 제외). 2막부터 푸드 부스·음향 등급·청소·홍보, 3막부터 의료·의료 텐트·바 부스·두 번째 헤드라이너가 열린다(#2막-이후-손잡이).

### 예산 제약 (S0)

```
C = cost(plan)                       // S5
합법 ⇔ C.total ≤ funds + A.credit_limit
```

비용은 공연 뒤 정산 때 한 번에 빠진다(외상). 그래서 준비 단계에서 자금보다 큰 계획을 걸 수 있고, 매출이 모자라면 정산 후 자금 < 0 → 파산(run.md).

## 예상치 미리보기 (P)

준비 화면에 항상 뜨는 값. 전부 **분산 0(v = 0), 돌발 없음**으로 개최 시뮬을 한 번 돌린 결과에서 나온다(엔진의 같은 함수를 쓴다).

| # | 표시 | 공식 |
|---|---|---|
| P1 | 예상 관객 범위 | `min(cap, div(raw × (100 − var), 100))` ~ `min(cap, div(raw × (100 + var), 100))`, 가운데 값 `att0 = min(cap, raw)` (raw 는 S2) |
| P2 | 비용 합계·자금 잔액 | `C.total`, `funds − C.total` (음수면 "외상 N") |
| P3 | 손익분기 관객 | `ceil((C.total − sponsor) × 100 / (price × 100 + Σseg.bar_pct × drink_price))` (근사: 바 매출을 1인당 Σbar_pct% 잔으로 본다) |
| P4 | 비율 | 바텐더 1명당 관객 `div(att0, units.bar)`, 화장실 1칸당 `div(att0, units.toilet)`, 보안 1명당 `div(att0, units.security)` (0 명이면 "없음") |
| P5 | 위험 경고 | 미리보기 시뮬의 줄 중 값 ≤ `balance.preview.warn_at`(−3) 인 감점 줄마다 경고 1줄(아래 표의 경고 문구) |
| P6 | 예상 만족도는 **숫자로 보여 주지 않는다** | 경고와 가점 줄 이름만. 결과의 긴장을 남긴다 |

## 개최 시뮬

### S1. 유효 인원

```
units.security = plan.security + add("free.security")
units.bar      = min(plan.bar + add("free.bar"), venue.bar_slots (+ 3막 바 부스 × staff_slots))
units.toilet   = venue.toilets + plan.toilet + add("free.toilet")
rowdy          = max(genre[h.genre].rowdy_pct for h in H)        // 록 120, 힙합 110, 일렉 100, 인디 70
```

### S2. 수요와 입장 (RNG: DEMAND 1회)

```
raw = Σ h.draw (h∈H) + Σ div(o.draw × opener_draw_pct(50), 100) (o∈O) + fame × fame_draw(2)
raw = div(raw × offer.demand_pct, 100)
if any(h.genre == offer.theme): raw = div(raw × (100 + theme_demand_pct(20)), 100)
raw = div(raw × price_level.demand_pct, 100)                 // 1막: 1만 125, 2만 100, 3만 80, 4만 60
(2막+) raw = div(raw × (100 + promo_level.demand_pct), 100)
raw = div(raw × (100 + venue.demand_pct), 100)
raw = ap(raw, "demand")
raw = ap(raw, "demand.genre." + H[0].genre)
v = stream(DEMAND).range(-variance_pct(20), +variance_pct)    // RNG
if rule("demand_floor") > 0: v = max(0, v)
demand = div(raw × (100 + v), 100)
att = min(demand, venue.capacity)
sold_out = (demand ≥ venue.capacity)
```

### S3. 돌발 카드 일정 (RNG: EVENT)

`base = simulate(plan, att, demand, events=[])` 를 먼저 돌려 조건을 판정하고, events.md E2 로 이번 공연의 돌발 카드 목록과 구간을 정한다. 그다음 실제 개최 `simulate(plan, att, demand, events)` 를 돈다.

### S4. 구간 루프 `simulate`

구간 5개(`acts[act].segments` 순서): 개장 · 오프닝 · 전환 · 헤드라이너 · 마감. 1막 프로필:

| 구간 | 무대 | 도착 % | 바 % | 화장실 % | 열기 % |
|---|---|---|---|---|---|
| 개장 doors | 없음 | 45 | 25 | 5 | 60 |
| 오프닝 opening | 오프닝 | 35 | 15 | 10 | 90 |
| 전환 changeover | 없음 | 15 | 35 | 40 | 70 |
| 헤드라이너 headline | 헤드라이너 | 5 | 10 | 10 | 120 |
| 마감 close | 없음 | 0 | 5 | 20 | 80 |

```
simulate(plan, att, demand, events):
  static = static_lines(plan, att, demand)          // S6: (구간, 원인, 값) 목록
  cum = 0; miss = {bar_queue:0, toilet_queue:0, security:0}; prev_pen = {같은 키: 0}
  drinks = 0; seg_pct = {}; ev_money = 0; ev_fame = 0; ev_lines = []
  run = sat_base(62)
  for s, seg in segments:
    cum += seg.arrive_pct
    present = div(att × cum, 100)

    // (a) 이 구간의 돌발 카드 (일정 순서대로) — events.md E3
    for e in events where e.seg == s: resolve_event(e, ...)   // ev_money, ev_fame, ev_lines, seg_pct, units 변경

    // (b) 바
    bar_dem = div(present × seg.bar_pct, 100)
    bar_cap = ap(units.bar × staff.bar.serve(30), "cap.bar", seg_pct["cap.bar"])
    served  = min(bar_dem, bar_cap); drinks += served; miss.bar_queue += bar_dem − served

    // (c) 화장실
    toi_dem = div(present × seg.toilet_pct, 100)
    toi_cap = ap(units.toilet × facility.toilet.serve(15), "cap.toilet", seg_pct["cap.toilet"])
    miss.toilet_queue += max(0, toi_dem − toi_cap)

    // (d) 보안
    load  = div(present × rowdy × seg.heat_pct, 10000)
    cover = ap(units.security × staff.security.cover(50), "cap.security")
    miss.security += max(0, load − cover)

    // (e) 이번 구간에 실현되는 줄
    lines_s = [static 중 구간 s] + [ev_lines 중 구간 s]
    for k in (bar_queue, toilet_queue, security):
       p = queue_pen(k, miss[k], att)
       if p != prev_pen[k]: lines_s.push((k, p − prev_pen[k])); prev_pen[k] = p
    run += Σ lines_s 값
    mood[s] = clamp(run, 0, 100)                      // 분위기 게이지

  lines = static + ev_lines 를 원인별로 합친 것 + prev_pen 중 0 이 아닌 것
  satisfaction = clamp(sat_base + Σ lines, 0, 100)   // lines 에 base_bonus(= add("sat.base")) 포함
  return {satisfaction, lines, drinks, mood[], 구간별 숫자, ev_money, ev_fame}

queue_pen(k, m, att):
  if att == 0: return 0
  pct = div(m × 100, att)                          // 못 간 사람(보안은 감당 못 한 인원·구간) ÷ 관객 %
  p = max(lines[k].cap, −div(pct × lines[k].weight_pct, 100))
  return min(0, p + add("pen." + k))
```

- `add("sat.base")` 는 개장 구간에 `base_bonus` 줄로 실현된다(분위기 게이지와 최종값이 같도록).
- 보안의 `miss` 는 "구간마다 감당 못 한 인원"의 합(인원·구간). 한 사람이 여러 구간 위험하면 여러 번 센다.
- 바 매출은 처리된 잔 수만, 못 산 사람은 매출 0.

### S5. 비용

```
cost.venue     = ap(div(venue.fee × offer.venue_fee_pct, 100), "cost.venue")
cost.headliner = Σ ap(h.fee, "cost.headliner")
cost.opener    = Σ ap(o.fee, "cost.opener")
cost.staff     = Σ_role ap(ap(plan[role] × staff[role].wage, "cost.staff"), "cost.staff." + role)   // 무료 인원은 제외
cost.facility  = Σ_f ap(ap(plan[f] × facility[f].cost, "cost.facility"), "cost.facility." + f)
(2막+) cost.promo = promo_level.cost, cost.sound = sound_grade.cost (cost.facility.sound 적용)
cost.total = 위 합
```

1막 단가: 보안 10, 바텐더 8, 화장실 칸 10.

### S6. 만족도 줄 (원인 ↔ 결정 대응표)

만족도 = 기준값 62 + 아래 줄의 합 (+ 돌발 줄), 0~100 으로 자른다.

| 원인 (key) | 실현 구간 | 공식 (`balance.lines`) | 되돌릴 결정 | 경고/리뷰 문구 예 |
|---|---|---|---|---|
| `price_over` 티켓값 | 개장 | `over = price − max(H.fair_price)`; over > 0 이면 `min(0, max(−12, over × −4) + add("pen.price_over"))` | 기둥 5 티켓 가격 | "티켓 4만원 > 이 라인업 적정가 3만원 → −4" |
| `opener` 오프닝 | 오프닝 | 오프닝 있음: `Σ div(o.skill × 8, 100)`, 없음: −3 | 기둥 2 오프닝 섭외 | "빈 무대로 시작 → −3" |
| `sound` 음향 | 오프닝 | `venue.sound + add("line.sound")` (+2막 음향 등급 `sat`). 0 이면 줄 없음 | 기둥 1 장소 (2막+: 기둥 3 음향 등급) | "창고 울림 → −4" |
| `headliner` 헤드라이너 | 헤드라이너 | `scale(max(H.skill) − 50, 30)` | 기둥 2 헤드라이너 | "실력 76 → +7" |
| `theme` 테마 일치 | 헤드라이너 | 헤드라이너 장르 = 제안 테마면 +3 (수요 +20 % 도) | 기둥 0 제안 / 기둥 2 | "인디의 밤에 인디 헤드라이너 → +3" |
| `empty_room` 빈 자리 | 헤드라이너 | `fill = div(att × 100, capacity)`; fill < 50 이면 `max(−10, −div(50 − fill, 3))` | 기둥 1 장소 크기 | "300석에 90명 → −6" |
| `sold_out` 매진 열기 | 헤드라이너 | demand ≥ capacity 면 +3 | 기둥 1 장소 크기 / 기둥 5 가격 | "매진 → +3" |
| `bar_queue` 바 줄 | 매 구간 누적 | `queue_pen`, weight 30 %, cap −8 | 기둥 4 바텐더 수 | "바에서 못 산 사람 40명(20 %) → −6" |
| `toilet_queue` 화장실 줄 | 매 구간 누적 | `queue_pen`, weight 70 %, cap −15 | 기둥 3 화장실 칸 수 | "전환 시간 화장실 20명 못 감 → −7" |
| `security` 보안 | 매 구간 누적 | `queue_pen`, weight 6 %, cap −12 | 기둥 4 보안 인원 | "보안 1명당 173명(권장 50) → −12" |
| `event:<id>` 돌발 | 카드 구간 | 고른 선택지의 `sat` | 돌발 카드 선택 | "앰프 고장, 언플러그드 → −6" |
| `base_bonus` 운영 감각 | 개장 | `add("sat.base")` | (보상 카드) | — |
| (2막+) `food_queue`, `cleaning`, `medical`, `weather` | #2막-이후-손잡이 | | 푸드 부스 / 청소 / 의료 / 우천 대비 | |

결과 화면의 "원인 리뷰 3~5줄" = 위 줄을 절댓값 큰 순으로 최대 5줄(같으면 표 순서), 감점 줄을 먼저.

### S7. 매출·수지

```
ticket = att × price
bar    = ap(drinks × A.drink_price(1), "bar.price")
(2막+) food = food_served × food_price
profit = ticket + bar (+ food) + offer.sponsor − cost.total + ev_money
```

### S8. 등급·명성·정산

| 등급 | 만족도 ≥ | 명성 기본 |
|---|---|---|
| S | 84 | +5 |
| A | 74 | +3 |
| B | 59 | +2 |
| C | 48 | 0 |
| D | 0 | −2 |

```
grade = balance.grades 에서 min ≤ satisfaction 인 첫 행 (S→D 순서)
fd = scale(grade.fame, offer.fame_pct)
if fd > 0: fd = ap(fd, "fame.gain")
funds += profit
fame = max(0, fame + fd + ev_fame)
```

다음은 run.md ④(파산·명성 0·관문 판정) → ⑤ 보상.

## 2막 이후 손잡이 (대략치, `status: draft`)

봇 검증 전 초안. 공식 모양만 확정하고 수치는 2막 티켓에서 맞춘다.

| 손잡이 | 공식 |
|---|---|
| 홍보 (2막+) | `acts.promo_levels[i]`: 비용 `cost`, 수요 `div(raw × (100 + demand_pct), 100)` (S2 가격 다음) |
| 음향 등급 (2막+) | `facilities.sound.grades[i]`: 비용, `sound` 줄에 `sat` 더함 |
| 푸드 부스 (2막+) | 바와 같은 모양: `food_dem = div(present × seg.food_pct, 100)`, `cap = ap(booths × serve, "cap.food")`, 처리분 × `food_price` 매출, 못 간 사람 → `food_queue` (weight 30, cap −8) |
| 청소 (2막+) | 쓰레기 = 바 처리 잔 + 푸드 처리 건(누적). 마감 구간에 `excess = max(0, 쓰레기 − ap(cleaners × cover, "cap.cleaning"))` → `queue_pen("cleaning", excess)` (weight 20, cap −10) |
| 의료 (3막+) | 헤드라이너 구간에 `need = div(present × rowdy × heat, 10000)`, `cover = ap(medics × cover(1500), "cap.medical")`, 부족분 → `queue_pen("medical")` (weight 20, cap −12). 의료 인원 상한 = 의료 텐트 × 4 |
| 바 부스 (3막+) | 야외 장소는 `bar_slots` 0. 바텐더 상한 += 부스 × 4 |
| 날씨 (3막+, 야외) | 개최 시작에 WEATHER `int(100)` 1회 → 맑음 60 / 흐림 25 / 비 15. 비: 수요 −10 %(S2 의 v 적용 직후), `weather` 줄 −8 을 개장 구간에 실현. 우천 대비(시설, 3막 티켓에서 추가) 등급이 줄을 0 쪽으로 줄인다. 데이터 테이블은 아직 없음(열린 질문) |
| 헤드라이너 2명 (3막+ 또는 레전더리) | 집객 합, `headliner` 줄은 최고 실력, 적정가·소란도는 최댓값, 테마는 한 명만 맞아도 |

## 손 계산 예시 (SE-069 고정점 테스트)

두 예시 모두: 보유 카드 없음(`ap(x)=x`, `add=0`), **수요 분산 v = 0**, **돌발 카드 없음**(events = []). 엔진 테스트는 `run_show` 에 `{forceVariance: 0, forceEvents: []}` 같은 주입으로 같은 조건을 만든다. 숫자는 이 문서 공식을 그대로 옮긴 파이썬 재구현으로 뽑고 손으로 대조했다.

### 예시 (a) — 잘 준비한 1막 첫 공연 → A

상태: 1막 첫 공연, 자금 300, 명성 10.

| 결정 | 값 |
|---|---|
| 제안 | 금요일 밤 (`friday`: 수요 100 %, 대관료 100 %, 명성 100 %, 협찬 0), 테마 **indie** |
| 장소 | 반지하 소극장 `club_basement` (수용 120, 대관료 40, 음향 0, 화장실 2칸, 바 자리 2) |
| 헤드라이너 | 우산 두 개 `a1_two_umbrellas` (indie, 집객 60, 실력 76, 개런티 110, 적정가 3) |
| 오프닝 | 녹슨 자전거 `a1_rusty_bike` (rock, 집객 70, 실력 55, 개런티 90) |
| 시설 | 추가 화장실 1칸 |
| 인력 | 보안 2, 바텐더 2 |
| 티켓 | 3만원 (단계 index 2, 수요 80 %) |

**비용(S5)**: 장소 div(40×100,100)=40, 헤드라이너 110, 오프닝 90, 인력 2×10 + 2×8 = 36, 시설 1×10 = 10 → **286** (≤ 300 + 100, 외상 없음).

**수요(S2)**: 60 + div(70×50,100)=35 + 10×2=20 → 115 → ×100 % = 115 → 테마 일치 ×120 % = 138 → ×80 % = div(11040,100) = **110** → 장소 보정 0 → 110. v = 0 → demand 110, **att 110** (수용 120, 매진 아님, fill = 91 %).

**유효 인원(S1)**: 보안 2(감당 100), 바텐더 2(구간당 60잔), 화장실 2+1 = 3칸(구간당 45명), 소란도 인디 70.

**구간(S4)**:

| 구간 | 누적 도착 | 현재 인원 | 바 수요/처리량/판매 | 화장실 수요/처리량 | 보안 부담/감당 | 실현 줄 | 분위기 |
|---|---|---|---|---|---|---|---|
| 개장 | 45 | 49 | 12 / 60 / 12 | 2 / 45 | 20 / 100 | — | 62 |
| 오프닝 | 80 | 88 | 13 / 60 / 13 | 8 / 45 | 55 / 100 | opener +4 | 66 |
| 전환 | 95 | 104 | 36 / 60 / 36 | 41 / 45 | 50 / 100 | — | 66 |
| 헤드라이너 | 100 | 110 | 11 / 60 / 11 | 11 / 45 | 92 / 100 | headliner +7, theme +3 | 76 |
| 마감 | 100 | 110 | 5 / 60 / 5 | 22 / 45 | 61 / 100 | — | 76 |

계산 근거: 현재 인원 div(110×45,100)=49, div(110×80,100)=88, div(110×95,100)=104. 바 div(49×25,100)=12, div(88×15,100)=13, div(104×35,100)=36, div(110×10,100)=11, div(110×5,100)=5. 화장실 div(104×40,100)=41 등. 보안 div(49×70×60,10000)=20, div(88×70×90,10000)=55, div(104×70×70,10000)=50, div(110×70×120,10000)=92, div(110×70×80,10000)=61.
못 간 사람: 바 0, 화장실 0, 보안 0 → 큐 줄 없음.

**만족도 줄(S6)**: price_over 없음(3 − 3 = 0), opener div(55×8,100) = **+4**, sound 0 → 줄 없음, headliner scale(76−50, 30) = div(780,100) = **+7**, theme **+3**, empty_room 없음(91 ≥ 50), sold_out 없음(110 < 120).
**만족도 = 62 + 4 + 7 + 3 = 76 → A**.

**매출(S7)**: 티켓 110 × 3 = 330, 바 12+13+36+11+5 = 77잔 × 1 = 77, 협찬 0 → **수지 = 330 + 77 − 286 = +121**.
**정산(S8)**: 명성 scale(3, 100) = +3 → **명성 13**, **자금 421**.
미리보기 값(참고): 예상 관객 88~120 (div(110×80,100)=88, div(110×120,100)=132 → 수용 120), 손익분기 ceil(286×100 / (300 + 90)) = ceil(73.3) = **74명**, 경고 없음.

### 예시 (b) — 화장실·보안이 부족한 공연 → C

상태: 1막 두 번째 공연, 자금 420, 명성 13.

| 결정 | 값 |
|---|---|
| 제안 | 주말 특집 (`weekend`: 수요 120 %, 대관료 130 %, 명성 150 %, 협찬 0), 테마 **hiphop** |
| 장소 | 흡음벽 스튜디오홀 `club_studio` (수용 200, 대관료 130, 음향 +4, 화장실 3칸, 바 자리 3) |
| 헤드라이너 | 새벽 세탁소 `a1_dawn_laundry` (rock, 집객 120, 실력 70, 개런티 200, 적정가 3) |
| 오프닝 | 녹슨 자전거 `a1_rusty_bike` |
| 시설 | 추가 화장실 **0** |
| 인력 | 보안 **1**, 바텐더 2 |
| 티켓 | 3만원 (80 %) |

**비용**: 장소 div(130×130,100) = 169, 헤드라이너 200, 오프닝 90, 인력 10 + 16 = 26, 시설 0 → **485** (≤ 420 + 100 → 합법, 외상 65).

**수요**: 120 + 35 + 13×2=26 → 181 → ×120 % = div(21720,100) = 217 → 테마 불일치(rock ≠ hiphop) → ×80 % = div(17360,100) = **173** → att **173** (수용 200, 매진 아님, fill 86 %).

**유효 인원**: 보안 1(감당 50), 바텐더 2(60잔), 화장실 3칸(45명), 소란도 록 120.

| 구간 | 현재 인원 | 바 수요/처리량/판매 | 화장실 수요/처리량/못 감 | 보안 부담/감당/초과 | 실현 줄 | 분위기 |
|---|---|---|---|---|---|---|
| 개장 | 77 | 19 / 60 / 19 | 3 / 45 / 0 | 55 / 50 / 5 | — | 62 |
| 오프닝 | 138 | 20 / 60 / 20 | 13 / 45 / 0 | 149 / 50 / 99 | opener +4, sound +4, security −3 | 67 |
| 전환 | 164 | 57 / 60 / 57 | 65 / 45 / **20** | 137 / 50 / 87 | toilet_queue −7, security −3 | 57 |
| 헤드라이너 | 173 | 17 / 60 / 17 | 17 / 45 / 0 | 249 / 50 / 199 | headliner +6, security −6 | 57 |
| 마감 | 173 | 8 / 60 / 8 | 34 / 45 / 0 | 166 / 50 / 116 | — (보안은 이미 상한) | 57 |

계산 근거: 인원 div(173×45,100)=77, div(173×80,100)=138, div(173×95,100)=164. 보안 부담 div(77×120×60,10000)=55, div(138×120×90,10000)=149, div(164×120×70,10000)=137, div(173×120×120,10000)=249, div(173×120×80,10000)=166.

큐 줄의 누적(queue_pen):
- 화장실: 전환 후 못 감 20 → pct = div(2000,173) = 11 → −div(11×70,100) = **−7** (이후 변화 없음).
- 보안 누적 초과: 개장 5 → pct 2 → −div(12,100)=0 / 오프닝 104 → pct 60 → −div(360,100) = −3 / 전환 191 → pct 110 → −6 (Δ −3) / 헤드라이너 390 → pct 225 → −13 → 상한 **−12** (Δ −6) / 마감 506 → pct 292 → 상한 −12 (Δ 0).
- 바: 못 산 사람 0.

**만족도 줄**: opener +4, sound +4, headliner scale(20,30) = +6, theme 없음, toilet_queue −7, security −12.
**만족도 = 62 + 4 + 4 + 6 − 7 − 12 = 57 → C**.

**매출**: 티켓 173 × 3 = 519, 바 19+20+57+17+8 = 121 → **수지 = 519 + 121 − 485 = +155**.
**정산**: 명성 scale(0, 150) = 0 → **명성 13 유지**, **자금 575**.
리뷰 1순위: "보안 1명이 관객 173명을 맡았다 → −12", 2순위: "전환 시간 화장실 20명 못 감 → −7".

**대조 — 보안 5, 화장실 +2 로 고치면** (다른 결정 동일; 비용 545 가 자금 420 + 외상 100 을 넘으므로 **자금 450 이상일 때만** 걸 수 있다 — SE-069 검산): 비용 545(인력 50 + 16, 시설 20), 화장실 5칸 75명 ≥ 65, 헤드라이너 보안 부담 249 ≤ 250 → 큐 줄 0, **만족도 76 → A**, 수지 519 + 121 − 545 = **+95**, 명성 scale(3,150) = **+4**. 돈 60 을 더 써서 수지는 60 줄지만 등급 C → A, 명성 0 → +4. 이 대조가 "결정 하나 → 결과 → 이유"의 기준 사례다.

## 수용 기준

- SH1. 예시 (a) 를 엔진에 넣으면 수요 110, 입장 110, 구간별 숫자·분위기(62/66/66/76/76), 만족도 76(A), 비용 286, 티켓 330, 바 77, 수지 +121, 명성 +3 이 전부 일치한다.
- SH2. 예시 (b) 는 수요·입장 173, 비용 485, 화장실 못 감 20, 보안 누적 초과 506, 줄 {opener 4, sound 4, headliner 6, toilet_queue −7, security −12}, 분위기 62/67/57/57/57, 만족도 57(C), 수지 +155, 명성 0 이 일치한다. 대조안은 만족도 76(A), 수지 +95, 명성 +4.
- SH3. 모든 감점 줄의 원인 key 가 S6 표의 "되돌릴 결정" 하나에 대응하고, 결과 화면이 그 key 로 리뷰 문장을 만든다.
- SH4. 분위기 게이지의 마감 값 = 최종 만족도 (0~100 클램프 범위 안일 때).
- SH5. 계획 비용이 `funds + credit_limit` 를 넘으면 엔진이 계획을 거부한다.
- SH6. 미리보기(P) 는 v=0·돌발 없음 시뮬과 같은 숫자를 쓰고, 예시 (b) 에서 `toilet_queue`·`security` 경고 2줄을 낸다.
- SH7. 계산에 부동소수가 없다(엔진 코드 리뷰: `/` 는 `Math.floor` 안에서만).

## 테스트 방법

- `node prototype/v2/test_engine.mjs`: SH1·SH2 고정점(데이터는 `docs/gdd/v2/data/*.json` 그대로), SH4(무작위 계획 1,000개), SH5, SH6.
- SH3: 결과 객체의 `lines` 키 집합 ⊆ S6 표 키 + `event:*` 를 테스트로 확인.

## 열린 질문

| # | 질문 | 추천 기본값 |
|---|---|---|
| Q1 | 미리보기에 예상 만족도 숫자를 보여 줄까 | 보여 주지 않는다(P6). 프로토타입 플레이 후 재검토 |
| Q2 | 바 매출이 수지에서 차지하는 몫(1막 약 20 %)이 적당한가 | 유지. 바텐더 부족 = 줄 감점 + 매출 손실 두 갈래로 보이는 게 좋다 |
| Q3 | S 등급이 1막에서 거의 안 나온다(합리적 0 %, 최적 근사 3 %) | 유지 — S 는 보상 카드(노하우·인맥)가 쌓인 2막 이후 목표. 1막 보상 등급 상향은 A 로 충분 |
| Q4 | 날씨·우천 대비 데이터 테이블 | 3막 수치 티켓에서 `balance.weather`, `facilities.rain_cover` 추가 |
| Q5 | 손익분기(P3)는 근사식 | 프로토타입에서 오차가 눈에 띄면 미리보기 시뮬의 1인당 실제 매출로 바꾼다 |
