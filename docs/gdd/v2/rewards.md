# 보상 카드 (rewards.md)

| 항목 | 값 |
|---|---|
| 상태 | v2 1판 (SE-068) |
| 데이터 | [rewards.json](data/rewards.json) |
| 짝 문서 | [run.md](run.md) ⑤⑥, [show.md](show.md) 수정자 함수 `mp`·`ap`·`add`·`rule`, [events.md](events.md) E4 (대비 카드) |

## 목적

공연이 끝날 때마다(성공한 경우) 카드 3장 중 1장을 고른다. 넓은 풀(55장)에서 **종류와 등급을 따로 굴려** 런마다 다른 빌드가 나오게 한다. 효과는 정해진 효과 타입과 수정자 키로만 표현해 엔진이 카드별 코드를 갖지 않는다.

## 규칙

### R1. 등급

| 등급 | 기본 확률 (1막) | 2막 | 3막·피날레 | 클래스 | 효과 배율 `mag_pct` | 지속 보너스 `uses_add` |
|---|---|---|---|---|---|---|
| 노멀 normal | 55 | 48 | 40 | scalable | 100 | +0 |
| 스페셜 special | 25 | 27 | 30 | scalable | 150 | +1 |
| 레어 rare | 13 | 16 | 19 | scalable | 200 | +2 |
| 유니크 unique | 6 | 7 | 8 | unique (전용 카드) | — | — |
| 레전더리 legendary | 1 | 2 | 3 | legendary (전용 카드) | — | — |

- scalable 카드(47장)는 같은 카드가 노멀·스페셜·레어로 나온다. 등급이 오르면 효과 폭(×1.5, ×2)과 지속(+1, +2회)이 함께 커진다.
- 유니크(4장): 이름 있는 가상 인물. 런 전체 지속, 등급 배율 없음.
- 레전더리(4장): 규칙을 바꾼다(`rule`). 런 전체 지속.

### R2. 3택1 생성 (RNG: REWARD)

```
roll_rewards(state, A, gate_pass, grade):
  r = stream(state.seed, state.show_idx, REWARD)
  W = rarity_weights_by_act[state.act]                       // [normal, special, rare, unique, legendary]
  up_slot = (grade_rank(grade) <= grade_rank("A")) ? (gate_pass ? 1 : 0) : none
  picked = []
  for slot in 0..2:
    lo = (gate_pass && slot == 0) ? index("rare") : 0        // 관문 통과: 첫 장은 레어 이상 보장
    ri = weighted_pick(r, [i < lo ? 0 : W[i]])
    if slot == up_slot: ri = min(ri + 1, 4)                  // 성적 A 이상: 한 장 등급 +1
    excl = state.owned_ids ∪ picked.ids
    loop:
      if class(ri) ∈ {unique, legendary}:
        pool = cards 중 class == class(ri), min_act ≤ act, id ∉ excl (파일 순서)
        if pool 비었음: ri = index("rare"); continue
        card = pool[r.int(len(pool))]; break
      else:
        avail[k] = cards 중 class == scalable, kind == k, min_act ≤ act, id ∉ excl (파일 순서)
        K = kinds 중 avail 비지 않은 것 (파일 순서), 가중치 kind.weight
        k = K[weighted_pick(r, K.weight)]
        card = avail[k][r.int(len(avail[k]))]; break
    picked.push(materialize(card, rarity[ri]))
  return picked
```

종류 가중치: 인맥 14, 노하우 14, 섭외 혜택 16, 대여 할인 16, 운영 지원 16, 즉시 보상 12, 돌발 대비 12.
같은 런에서 받은 적 있는 카드(만료 포함)와 같은 제시 안의 카드는 다시 나오지 않는다.

### R3. 실체화 `materialize(card, rarity)`

```
for e in card.effects:
  if card.class == scalable and e.scales != false and e.type ∈ {pct, add, money, fame}:
     e.value = scale(e.value, rarity.mag_pct)          // 0 쪽으로 자름: −15 × 1.5 → −22
duration:
  uses    → left = n + (scalable ? rarity.uses_add : 0)
  charges → charges = n + (scalable ? rarity.uses_add : 0)
  run     → 런 끝까지
  instant → 고르는 즉시 반영하고 보관하지 않음
```

### R4. 지속과 적용 시점

| duration | 뜻 | 적용 |
|---|---|---|
| `instant` | 즉시 보상 | 고른 순간: `money` → `funds += scale(v, A.money_scale_pct)`(막 규모 보정, 1막 100 %), `fame` → `fame = max(0, fame + v)` |
| `uses` n | 다음 n번의 공연 | 다음 공연 준비부터 활성. 그 공연 정산 뒤(run.md ⑥) left −1, 0 이면 제거 |
| `charges` n | 돌발 대비 n회 | 공연 수와 무관하게 남아 있다가 대비 카드 사용 때 −1 |
| `run` | 런 전체 | 계속 활성 |

"활성 카드" = 보유 카드 중 `uses`(left > 0)·`run`. 수정자(`pct`·`add`·`rule`)는 활성 카드에서만 모은다. 고른 카드는 **다음 공연부터** 적용(막이 바뀌어도 이어진다).

### R5. 효과 타입

| type | 필드 | 엔진 처리 |
|---|---|---|
| `pct` | key, value | `pct_sum(key)` 에 더함 → `mp`/`ap` (show.md). 합산 후 20~300 % 클램프 |
| `add` | key, value | `add(key)` 에 더함 |
| `money` | value | 즉시 자금 (R4) |
| `fame` | value | 즉시 명성 (R4) |
| `shield` | tag | 대비 카드 (events.md E4). 태그 `*` 는 모든 돌발 |
| `rule` | key, value | `rule(key)` 에 더함 |

`scales: false` 가 붙은 효과는 등급 배율을 받지 않는다(대가 효과: 광고 계약의 명성 −1 등).

### R6. 수정자 키 목록 (엔진이 읽는 전부)

| 키 | 타입 | 들어가는 곳 (show.md) |
|---|---|---|
| `cost.venue`, `cost.headliner`, `cost.opener` | pct | S5 비용 |
| `cost.staff`, `cost.staff.<role>` | pct | S5 인력 비용 (전체 → 역할 순서로 두 번) |
| `cost.facility`, `cost.facility.<id>` | pct | S5 시설 비용 |
| `demand`, `demand.genre.<genre>` | pct | S2 수요 (헤드라이너 첫 명의 장르) |
| `bar.price` | pct | S7 바 매출 |
| `cap.bar`, `cap.toilet`, `cap.security`, `cap.food`, `cap.cleaning`, `cap.medical` | pct | S4 처리량·감당량 |
| `fame.gain` | pct | S8 양수 명성 변화 |
| `event.money` | pct | events.md E4 돈 선택지 비용 |
| `free.<role>`, `free.<facility>` | add | S1 무료 인원·칸 (비용 0) |
| `sat.base` | add | S6 `base_bonus` 줄 |
| `pen.<cause>` | add | S4/S6 해당 감점 줄을 0 쪽으로 (예: `pen.bar_queue` +2) |
| `line.sound` | add | S6 `sound` 줄 |
| `rule.headliner_slots` | rule | 헤드라이너 슬롯 + value |
| `rule.bankrupt_shield` | rule | 정산 후 자금 < 0 이면 0 으로 되돌리고 1 소모(런당 value 회) |
| `rule.gate_grade_relax` | rule | 관문 등급 조건을 value 단계 낮춤 |
| `rule.demand_floor` | rule | S2 의 v = max(0, v) |

(데이터의 `rule` 효과 key 는 접두사 없이 `headliner_slots` 처럼 쓴다.)

## 카드 풀 (55장)

값은 노멀 기준. `min_act` 2·3 카드는 해당 막부터 풀에 들어간다.

| 종류 | 카드 (지속) — 효과 |
|---|---|
| 인맥 (9, 런 전체) | 음향 엔지니어 친구 — 음향 줄 +1 · 지역 기자 — 수요 +5 % · 공연장 매니저 지인 — 대관료 −8 % · 바텐더 선배 — 바 처리량 +10 % · 경비업체 사장 — 보안 일당 −15 % · 록 동호회 회장 / 힙합 크루 형 / 파티 기획자 / 인디 레이블 대표 — 해당 장르 헤드라이너 수요 +10 % |
| 노하우 (7, 런 전체) | 동선 감각 — 화장실 처리량 +10 % · 바 운영 요령 — 바 매출 +10 % · 줄 세우기 요령 — 바 줄 감점 +2 완화 · 현장 통제 요령 — 보안 감당 +10 % · 가격 책정 감각 — 티켓값 감점 +2 완화 · 무대 진행 감각 — 만족도 +1 · 협상 요령 — 헤드라이너·오프닝 개런티 −5 % |
| 섭외 혜택 (6) | 헤드라이너 특가(1회) −20 % · 오프닝 특가(1회) −30 % · 라인업 묶음 계약(2회) 둘 다 −10 % · 후배 밴드의 부탁(1회) 오프닝 −50 % · 단골 아티스트(3회) 헤드라이너 −10 % · 공동 기획(1회) 헤드라이너 −30 %, 대신 명성 획득 −50 %(배율 없음) |
| 대여 할인 (6) | 대관료 할인권(2회) −15 % · 빈 날짜 대관(1회) −30 % · 간이 화장실 업체 쿠폰(2회) 화장실 −50 % · 장비 대여 묶음(2회) 시설 −20 % · 비수기 대관(1회) 대관료 −25 %, 수요 −5 %(배율 없음) · 장기 대관 계약(4회) −10 % |
| 운영 지원 (6, 1회) | 경비 지원 2명 · 바텐더 지원 1명 · 간이 화장실 기증 2칸 · 팬 자원봉사단(보안 1 + 바텐더 1) · 청소 업체 지원 3명(2막+) · 응급구조 봉사단 2명(3막+) |
| 즉시 보상 (5) | 문화재단 후원금 +30 · 광고 계약 +60, 명성 −1(배율 없음) · 언론 노출 명성 +2 · 팬 커뮤니티 결성 명성 +1, +15 · 굿즈 완판 +40 |
| 돌발 대비 (8) | 예비 앰프(equipment) · 배관 공구함(facility) · 여분 맥주 통(supply) · 경비 비상 연락망(crowd) · 이웃과 차 한잔(venue) · 만능 수습 매뉴얼(*) — 각 1회 · 위기 대응 훈련(런 전체) 돌발 돈 비용 −20 % · 우천 대비 천막(weather, 3막+) |
| 유니크 (4) | 은퇴한 음향감독 '고막' — 음향 줄 +3, 음향 대여 −30 % · 골목 건물주 '박 사장' — 대관료 −20 % · 밤의 기록자 '올빼미' — 명성 획득 +50 % · 만능 무대감독 '두 손' — 바·화장실·보안 감점 각 +3 완화 |
| 레전더리 (4) | 두 번째 헤드라이너 — 헤드라이너 슬롯 +1 · 보증인 — 파산 1회 면제 · 관객의 신뢰 — 관문 등급 조건 한 단계 완화 · 흥행 감각 — 수요가 예상보다 나쁘게 나오지 않음 |

이름은 전부 가상(실존 인물·단체·행사 연상 없음).

## 수치 근거

- 등급 확률 합 = 100(각 막). 3막 노멀 40 % 는 컨셉 4-1절 예시값.
- 1막 기대 효과: 노멀 인맥 1장 ≈ 공연당 수지 +5~+15 또는 만족 +1, 레어 운영 지원 ≈ 다음 공연 경고 하나 해소. 1막 통과율에 대한 보상의 기여는 작게 둔다(측정한 봇 통과율은 보상 포함).
- 막 결산 통과 시 레어 이상 1장 보장: 1막 기준 그 슬롯은 레어 65 % / 유니크 30 % / 레전더리 5 % (13:6:1).

## 수용 기준

- RW1. 카드 수 55(scalable 47 + 유니크 4 + 레전더리 4), 등급 확률이 표와 같다.
- RW2. 같은 시드·같은 상태면 같은 3장이 같은 등급으로 나온다.
- RW3. 관문 통과 직후 첫 장은 항상 레어 이상이고, 등급 A 이상이면 지정 슬롯이 한 단계 오른다(레전더리는 그대로).
- RW4. 받은 적 있는 카드는 그 런에서 다시 나오지 않는다. 유니크·레전더리 풀이 비면 레어로 내려 굴린다.
- RW5. 레어 "대관료 할인권"은 −30 %·4회, 스페셜 "경비 지원 2명"은 무료 보안 3명·2회로 실체화된다(R3).
- RW6. 엔진에 카드 id 별 분기가 없다(효과 타입·키만으로 처리).

## 테스트 방법

- `node prototype/v2/test_engine.mjs`: RW2(시드 고정), RW3(관문·A 등급 조건으로 10,000회 굴려 첫 장 등급 분포), RW4(풀 소진 시나리오), RW5(materialize 단위 테스트), RW1(데이터 로드 검사).
- RW6: 코드 리뷰(reviewer).

## 열린 질문

| # | 질문 | 추천 기본값 |
|---|---|---|
| Q1 | 메타 해금으로 풀에 카드 추가 | SE-070 이후. `min_act` 옆에 `unlock` 필드를 추가하는 방식 |
| Q2 | "이미 가진 카드 제외"를 만료된 카드까지 적용할지 | 적용(단순). 풀이 47장이라 13번 뽑아도 마르지 않는다 |
| Q3 | 카드 버리기·교체 | 없음(손잡이 최소화) |
