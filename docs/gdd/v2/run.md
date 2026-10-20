# 런 진행 (run.md)

| 항목 | 값 |
|---|---|
| 상태 | v2 1판 (SE-068) |
| 데이터 | [acts.json](data/acts.json), [balance.json](data/balance.json) (`start`·`fail`·`rng`), [artists.json](data/artists.json) |
| 짝 문서 | [show.md](show.md) (공연 1회), [events.md](events.md), [rewards.md](rewards.md) |

## 목적

런 하나가 어떤 순서로 흐르고 언제 끝나는지, 난수가 어디서 몇 번 나오는지를 정한다. SE-069 엔진은 이 문서의 루프와 RNG 규칙을 그대로 옮긴다.

## 규칙

### 정수 규칙 (모든 v2 문서 공통)

| # | 규칙 |
|---|---|
| I1 | 상태와 계산은 전부 정수. 소수·부동소수 없음 |
| I2 | `div(a, b)` = ⌊a ÷ b⌋ (음수도 −∞ 쪽 내림). JS `Math.floor(a / b)`, Python `a // b`. 공식은 가능한 한 음이 아닌 수에만 `div` 를 쓴다 |
| I3 | `scale(x, pct)` = `sign(x) × div(|x| × pct, 100)` (0 쪽으로 자름). 음수가 될 수 있는 값을 퍼센트로 늘리고 줄일 때 쓴다 |
| I4 | `clamp(x, lo, hi)`, `min`, `max` 는 보통 뜻 |

### 런 상태

```
RunState {
  seed: u32            // 런 시드
  act: int             // 1..4 (4 = 피날레)
  show_idx: int        // 런 전체 공연 번호 0..12 (RNG 시드용)
  show_in_act: int     // 막 안 공연 번호 0..normal_shows (마지막이 관문)
  funds: int           // 자금(만원). 시작 balance.start.funds = 300
  fame: int            // 명성. 시작 balance.start.fame = 10
  cards: Card[]        // 보유 보상 카드(지속 중인 것). rewards.md
  owned_ids: string[]  // 이번 런에서 받은 적 있는 카드 id (만료 포함)
  result: null | "pass_act" | "clear" | "bankrupt" | "no_show" | "fame_zero" | "gate_fail"
}
```

### 런 루프

```
start_run(seed):
  state = { seed, act: 1, show_idx: 0, show_in_act: 0,
            funds: balance.start.funds, fame: balance.start.fame, cards: [], owned_ids: [] }

loop:
  A = acts[state.act]
  is_gate = (state.show_in_act == A.normal_shows)          // 피날레는 normal_shows 0 → 첫 공연이 곧 관문
  ① offers = gen_offers(state, A, is_gate)                  // RNG: OFFER
     market = gen_market(state, A)                          // RNG: MARKET
     if min_plan_cost(state, A, offers, market) > state.funds + A.credit_limit:
        state.result = "no_show"; end                        // 개최 불가 = 자금 바닥
  ② plan = 플레이어 선택(offer 1장 + 준비 5기둥)              // show.md 기둥·예산 제약
  ③ res = run_show(state, A, plan, is_gate)                 // show.md. RNG: DEMAND, EVENT(, WEATHER)
  ④ settle(state, res)                                       // show.md #정산
     if state.funds < 0:
        if rule bankrupt_shield 남음: state.funds = 0; shield 1 소모
        else: state.result = "bankrupt"; end
     if state.fame <= 0: state.result = "fame_zero"; end
     gate_pass = false
     if is_gate:
        if grade_rank(res.grade) <= grade_rank(A.gate.min_grade) + rule(gate_grade_relax)
           and state.fame >= A.gate.min_fame: gate_pass = true
        else: state.result = "gate_fail"; end
        if state.act == 4: state.result = "clear"; end      // 피날레 통과 = 런 클리어, 보상 없음
  ⑤ offer3 = roll_rewards(state, A, gate_pass, res.grade)   // rewards.md. RNG: REWARD
     pick = 플레이어 선택 1장 → apply_pick(state, pick)       // 즉시 보상은 여기서 반영
  ⑥ tick_cards(state, res.active_card_ids)                  // 'uses' 카드 남은 횟수 −1, 0 이면 제거
     state.show_idx += 1
     if is_gate: state.act += 1; state.show_in_act = 0      // 다음 막
     else: state.show_in_act += 1
```

- 실패 판정 순서: 파산 → 명성 0 → 관문. 실패하면 그 공연의 보상은 없다.
- `grade_rank`: S=0, A=1, B=2, C=3, D=4. `gate_grade_relax` 는 허용 등급을 그 수만큼 낮춘다(B → C).
- 실패 사유 표시 문구: bankrupt "자금이 바닥났다", no_show "다음 공연을 열 돈이 없다", fame_zero "아무도 이름을 기억하지 않는다", gate_fail "결산 무대에서 증명하지 못했다".

### 막 구성 (`acts.json`)

| 막 | 상태 | 일반 공연 | 관문 | 관문 조건 | 제안 수 | 시장 | 돌발/공연 | 외상 한도 |
|---|---|---|---|---|---|---|---|---|
| 1 클럽 | final | 3 | 결산 쇼케이스 (돌발 3) | B 이상 + 명성 ≥ 12 | 3 | 6명 | 2 | 100 |
| 2 공연장 | draft | 3 | 결산 공연 | B 이상 + 명성 ≥ 45 | 3 | 6명 | 3 | 600 |
| 3 야외 페스티벌 | draft | 3 | 결산 페스티벌 | B 이상 + 명성 ≥ 90 | 3 | 7명 | 3 | 3,000 |
| 4 피날레 | draft | 0 | 메가 페스티벌 | B 이상 | 1 | 8명 | 3 | 8,000 |

런 = 4 + 4 + 4 + 1 = 13공연.

### ① 제안 카드 생성

```
gen_offers(state, A, is_gate):
  r = stream(state.seed, state.show_idx, OFFER)
  if is_gate:
     t = copy(A.gate.template); t.theme = GENRES[r.int(4)]; return [t]
  pool = A.offer_templates 중 weight > 0 (파일 순서)
  out = []
  repeat A.offers_per_show 번:
     i = weighted_pick(r, pool.weight)        // 아래 RNG 절
     t = copy(pool[i]); pool.remove(i)         // 중복 없음
     t.theme = GENRES[r.int(4)]                // GENRES = artists.json genres 순서: rock, hiphop, electronic, indie
     out.push(t)
  return out
```

제안 템플릿(1막): 평일 밤(집객 85%, 대관료 80%), 금요일 밤(100/100), 주말 특집(120/130, 명성 ×150%), 동네 양조장 협찬(90/100, 협찬금 +40), 평론가 초대석(95/100, 명성 ×200% — 등급이 나쁘면 손실도 2배). 관문 쇼케이스는 110/100, 명성 ×150%.

### 아티스트 시장

```
gen_market(state, A):
  r = stream(state.seed, state.show_idx, MARKET)
  L = artists 중 act == state.act (파일 순서), n = len(L), k = min(A.market_size, n)
  for i in 0..k-1: j = i + r.int(n - i); swap(L[i], L[j])     // 부분 Fisher–Yates
  return L[0..k-1]
```

시장은 제안 카드와 같은 화면에 보인다(제안을 고를 때 테마와 시장을 함께 본다). 시장은 제안 선택과 무관하게 정해진다.

### 개최 불가 판정 `min_plan_cost`

현재 수정자(보유 카드)로 계산한 가장 싼 합법 계획의 비용:
`min over offers(ap(div(가장 싼 장소 fee × offer.venue_fee_pct, 100), cost.venue)) + min over market(ap(fee, cost.headliner)) + 각 인력 역할의 최소 인원 × 일당(수정자 적용)`. 시설·오프닝·홍보 0. 이 값이 `funds + credit_limit` 보다 크면 `no_show`.

## 시드 RNG

### 알고리즘

mulberry32, 출력은 u32 정수. 상태 `a` 는 u32.

```
next_u32():                                   // JS 그대로
  a = (a + 0x6D2B79F5) | 0
  t = Math.imul(a ^ (a >>> 15), 1 | a)
  t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t
  return (t ^ (t >>> 14)) >>> 0
int(n):        return Math.floor(next_u32() * n / 4294967296)    // 0..n-1, n < 2^21 이면 정확
range(lo, hi): return lo + int(hi - lo + 1)
weighted_pick(r, w[]): x = r.int(Σw); for i: if x < w[i] return i; x -= w[i]
```

### 스트림

공연마다, 용도마다 새 생성기를 만든다. 한 용도의 호출 수가 바뀌어도 다른 용도의 난수가 밀리지 않는다(같은 시드로 정책만 바꾼 비교가 가능).

```
stream(run_seed, show_idx, id) = mulberry32((run_seed + show_idx × 1000003 + id × 7919) >>> 0)
id: OFFER 1, MARKET 2, DEMAND 3, EVENT 4, REWARD 5, WEATHER 6        (balance.json rng)
```

테스트 벡터(SE-069 단위 테스트용, node 로 확인함):
- `mulberry32(12345)` 첫 3개 u32 = 4207900869, 1317490944, 2079646450
- `stream(42, 0, DEMAND)` 시드 = 23799, 첫 `range(-20, 20)` = −9

### 공연 1회의 RNG 호출 순서

| 순서 | 스트림 | 호출 | 위치 |
|---|---|---|---|
| 1 | OFFER | 일반 공연: (weighted_pick 1회 + int(4) 1회) × offers_per_show. 관문: int(4) 1회 | 이 문서 ① |
| 2 | MARKET | int 를 market_size 회 | 이 문서 시장 |
| 3 | DEMAND | `range(−variance_pct, +variance_pct)` 1회 | show.md S2 |
| 4 | WEATHER | (3막+, 야외 장소만) int(100) 1회 | show.md 2막 이후 |
| 5 | EVENT | weighted_pick 을 돌발 수만큼(가중치 합이 0 이 되면 중단) | events.md E2 |
| 6 | REWARD | 슬롯마다: 등급 int 1회 → (노멀~레어) 종류 weighted_pick 1회 + 카드 int 1회 / (유니크·레전더리) 카드 int 1회 | rewards.md R2 |

개최 중 돌발 카드의 선택 결과는 결정적이다(난수 없음). 봇 정책의 난수는 봇 전용 RNG 를 쓰고 위 스트림과 섞지 않는다.

## 봇 정책과 1막 밸런스 목표

SE-069 봇 통계(AC3)는 아래 정책을 기준으로 삼는다. SE-069 의 절약/공격 정책은 따로 정의해도 되지만, 목표 판정은 **무작위**와 **합리적**으로 한다.

| 정책 | 정의 |
|---|---|
| 무작위 | 제안·장소·헤드라이너를 균등 추첨, 오프닝은 {없음} ∪ 시장(헤드라이너 제외)에서 균등, 보안·바텐더는 [최소, 최대] 균등, 추가 화장실 [0, 최대] 균등, 티켓 가격 단계 균등. 비용이 `funds + credit` 를 넘으면 다시 추첨(최대 50회), 실패 시 가장 싼 계획. 돌발 선택지·보상 카드도 균등 |
| 합리적 | (제안 × 시장의 헤드라이너) 조합마다: 티켓값 = 헤드라이너 적정가 이하 최고 단계, 오프닝 = 시장에서 가장 싼 아티스트(예산 안 되면 없음), 장소 = 예상 수요(분산 0)를 담는 가장 싼 장소(없으면 가장 큰 곳), 인력·화장실 = 미리보기 경고(줄 ≤ −3)가 사라지는 최소 수. **외상 없이**(비용 ≤ 자금) 예상 수지 ≥ 0 인 계획 중 `예상 만족도 + div(예상 수지, 20)` 최대. 돌발: 대비 카드가 있으면 사용, 아니면 `돈/6 + 만족 + 명성×3` 이 큰 선택(돈을 내면 자금이 30 아래로 가는 선택은 피함). 보상: 높은 등급 우선, 같으면 인맥·노하우 |
| 최적 근사(참고) | 장소·헤드라이너·오프닝·가격 전수 탐색 + 인력 자동, 하한 수요(−20%)에서도 파산하지 않는 계획 중 `명성 변화×20 + 만족도 + 수지/10` 최대 |

### 목표와 측정치

측정: game-designer 의 파이썬 재구현(이 문서·show.md 그대로, 저장소 밖 스크래치)으로 1막만 돌린 값. SE-069 JS 엔진이 같은 정책으로 ±3%p 안에서 재현해야 한다.

| 지표 | 목표 | 측정 (n) |
|---|---|---|
| 1막 통과율 — 무작위 | 20~50 % | 26.2 % (1,000), 25.7 % (다른 시드 1,000) |
| 1막 통과율 — 합리적 | 70~90 % | 86.8 % (400) |
| 1막 통과율 — 최적 근사 | (참고) ≥ 90 % | 96.7 % (60) |
| 무작위의 첫 공연 적자 비율 | ≥ 30 % ("첫 공연부터 적자 위험") | 65 % |
| 합리적 계획이 수요 −20% 에서 적자 | 5~20 % | 11 % |
| 합리적 계획에서 결정 하나만 바꿔도 등급이 바뀌는 공연 비율 | ≥ 50 % | 80 % (보안 −2명 57 %, 화장실 추가 0 64 %, 오프닝 없음 57 %, 티켓 +1단계 18 %, 바텐더 −1 14 %, 한 단계 큰 장소 14 %) |
| 공연 등급 분포 — 무작위 | D+C ≥ 50 % | A 2 / B 35 / C 42 / D 21 % |
| 공연 등급 분포 — 합리적 | B+A ≥ 80 % | A 18 / B 69 / C 12 % |
| 무작위 실패 사유 | 관문이 주, 자금·명성도 실제로 발생 | 관문 71 %, 개최 불가 2 %, 명성 0 0.6 %, 파산 0.1 % |

수지(공연당, 만원): 무작위 p10/중앙/p90 = −132 / −8 / +126, 합리적 = +59 / +148 / +275.

## 수용 기준

- RN1. 같은 시드·같은 선택이면 런 전체 결과(공연별 등급·자금·명성·보상 제시)가 바이트 단위로 같다.
- RN2. 테스트 벡터 2개가 일치한다.
- RN3. 정책만 바꾸고 시드를 같게 하면 제안·시장·수요 분산·보상 제시가 같다(스트림 분리).
- RN4. 1막 봇 통계가 위 목표 범위에 든다(무작위 20~50 %, 합리적 70~90 %).
- RN5. 관문 실패·파산·명성 0·개최 불가가 각각 런을 끝내고, 실패한 공연에서는 보상 3택1이 나오지 않는다.

## 테스트 방법

- `node prototype/v2/test_engine.mjs`: 테스트 벡터, 고정 시드 런 2회 비교(RN1), 실패 4종을 강제로 만드는 시나리오(RN5).
- `node prototype/v2/bot.mjs --runs 200`(이상): 무작위·합리적 정책 1막 통과율과 위 표 지표(RN4) → `docs/reports/SE-069.md`.

## 열린 질문

| # | 질문 | 추천 기본값 |
|---|---|---|
| Q1 | 1막에서 파산은 드물다(무작위 0.1 %, 개최 불가 2 %). 돈의 위협은 2막부터 커지게 할까, 1막 시작 자금을 줄일까 | 1막은 "예산 퍼즐"로만 쓰고 파산 위협은 2막 외상·고정비에서. 시작 자금 200 으로 줄이면 무작위 통과율이 18 % 로 목표 아래로 내려간다(측정) |
| Q2 | 메타 해금(커리어 포인트) | SE-070 이후. 이 문서 범위 밖 |
| Q3 | 2막 이후 관문 명성(45/90)은 대략치 | 2막 수치 확정 티켓에서 봇으로 맞춘다 |
| Q4 | 피날레 "이틀 일정" | 대략치 단계에서는 하루 공연 1회로 계산. 이틀이면 같은 계획으로 두 번 돌려 만족도 평균, 수지 합 — 2막 이후 티켓에서 확정 |
