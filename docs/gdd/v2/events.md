# 돌발 카드 (events.md)

| 항목 | 값 |
|---|---|
| 상태 | v2 1판 (SE-068). 1막 8장 확정, 2막 이후 카드는 미작성 |
| 데이터 | [events.json](data/events.json) |
| 짝 문서 | [show.md](show.md) S3·S4 (개최 루프), [rewards.md](rewards.md) (대비 카드 `shield`, `event.money`) |

## 목적

개최는 자동으로 흐르지만, 공연마다 돌발 카드 2~3장에 플레이어가 선택으로 답한다. 카드는 **준비가 허술한 곳에서 더 잘 터지고**(조건부 가중치), 선택지는 "돈으로 막기 vs 만족도로 버티기"의 교환이다. 결과 화면에서 돌발 줄은 `event:<id>` 로 따로 보인다.

## 규칙

### E1. 장 수

| 막 | 일반 공연 | 관문 |
|---|---|---|
| 1 | 2장 (`acts.events_per_show`) | 3장 (`acts.gate.events_per_show`) |
| 2·3·피날레 | 3장 (대략치) | 3장 |

### E2. 일정 뽑기 (RNG: EVENT)

```
schedule_events(state, A, plan, base, att, demand, n):
  r = stream(state.seed, state.show_idx, EVENT)
  pool = events 중 state.act ∈ e.act (파일 순서)
  out = []
  repeat n 번:
    w[i] = pool[i].weight
           × 각 weight_mod 조건이 참이면 w = div(w × mult_pct, 100) (순서대로 곱)
    if Σw == 0: break
    i = weighted_pick(r, w); out.push(pool[i]); pool.remove(i)     // 같은 카드 중복 없음
  out 을 segment 순서로 안정 정렬 (같은 구간이면 뽑힌 순서)
  return out
```

조건은 **기준 시뮬**(`base` = 돌발 없이 같은 계획·같은 입장 수로 돌린 결과)에서 판정한다.

### E3. 조건 어휘 (`events.json` `conditions`)

| 조건 | 참일 때 |
|---|---|
| `security_short` | 기준 시뮬의 보안 누적 초과 > 0 |
| `toilet_short` | 기준 시뮬의 화장실 못 간 인원 합 > 0 |
| `bar_short` | 기준 시뮬의 바 못 산 인원 합 > 0 |
| `sold_out` | demand ≥ 수용 |
| `att_ge` | att ≥ value |
| `venue_trait` | 장소 traits 에 value 포함 |
| `mood_ge` | 기준 시뮬에서 그 카드 구간 끝의 분위기 ≥ value |
| `has_opener` (선택지 requires) | 오프닝이 있다 |
| `security_ok` (선택지 requires) | 그 구간 시작 시점(현재 인원·현재 보안 인원)의 `load ≤ cover` |

### E4. 해결 `resolve_event` (개최 중, 결정적)

카드 구간의 (a) 단계(show.md S4)에서, 그 구간 현재 인원을 계산한 직후 실행한다.

1. 선택지 = `requires` 가 없거나 참인 것.
2. 대비 카드: 보유한 `charges` 카드 중 shield 태그가 카드 `tags` 와 정확히 같은 것(획득 순서) → 없으면 태그 `*` 인 것. 있으면 선택지 **"대비 카드 사용"**(효과 없음)을 추가한다. 고르면 그 카드 charges −1, 0 이면 제거.
3. 플레이어가 고른 선택지의 효과를 순서대로 적용한다.

| 효과 type | 적용 |
|---|---|
| `money` | `ev_money += v` (v < 0 이면 `−div(|v| × mp("event.money"), 100)`). 정산 때 수지에 들어간다 |
| `sat` | 줄 `event:<id>` 에 v, 이 구간에 실현 |
| `fame` | `ev_fame += v`, 정산 때 명성에 |
| `seg_pct` | `seg_pct[key] += v`, 이 구간부터 공연 끝까지 (`cap.bar`, `cap.toilet`) |
| `seg_add` | `units[key의 뒷부분] = max(0, units + v)`, 이 구간부터 (`units.security`, `units.toilet`, `units.bar`) |

돈 선택지는 자금이 모자라도 고를 수 있다(정산 후 파산할 수 있음 — UI 는 "정산 후 자금 N" 을 보여 준다).

## 1막 카드 8장

| id | 이름 | 구간 | 가중치 (조건) | 태그 | 선택지 → 효과 |
|---|---|---|---|---|---|
| `entrance_jam` | 입구 병목 | 개장 | 6 (보안 부족 ×3) | crowd | 즉석 인력 2명 고용: 돈 −20, 이후 보안 +2, 만족 −1 / 천천히 입장: 만족 −4 |
| `amp_fail` | 앰프 고장 | 오프닝 | 8 | equipment | 긴급 수리(20분 지연): 돈 −30, 만족 −3 / 언플러그드로 버틴다: 만족 −6 |
| `influencer` | 공연 블로거 방문 | 오프닝 | 6 | press | VIP 대접: 돈 −15, 명성 +2 / 평소대로: 없음 |
| `beer_shortage` | 맥주 재고 부족 | 전환 | 6 (입장 ≥ 180 ×2) | supply | 마트에서 긴급 조달: 돈 −25, 만족 −1 / 남은 음료만: 이후 바 처리량 −50 % |
| `toilet_clog` | 화장실 막힘 | 전환 | 6 (화장실 부족 ×2) | facility | 배관 업체 호출: 돈 −30, 만족 −1 / 그 칸을 닫는다: 이후 화장실 −1칸 |
| `drunk_fight` | 취객 시비 | 헤드라이너 | 6 (보안 부족 ×3) | crowd | 보안팀이 데리고 나간다(그 구간 보안이 충분할 때만): 없음 / 직접 말린다: 만족 −5 / 경찰을 부른다: 만족 −2, 명성 −1 |
| `noise_complaint` | 소음 민원 | 헤드라이너 | 3 (주택가 ×3) | venue | 볼륨을 줄인다: 만족 −5 / 버틴다(과태료): 돈 −40 |
| `encore` | 앙코르 요청 | 마감 | 2 (분위기 ≥ 72 ×4) | artist | 한 곡 더: 돈 −10, 만족 +3, 명성 +1 / 여기서 마친다: 없음 |

설계 의도:
- 준비와 연결: 보안이 부족하면 입구 병목·취객 시비가 3배 잘 나오고, 취객 시비의 무료 해결은 보안이 충분할 때만 열린다. 화장실이 빠듯하면 막힘이 2배, 주택가 장소는 민원이 3배.
- 돈 선택지도 만족 −1~−3 을 남긴다(완전히 지우지 못한다) — 합리적 플레이에도 변동을 주는 장치(run.md 측정에서 합리적 통과율을 90 % 아래로 내린 요인).
- 좋은 공연에는 보상 기회(앙코르)가 더 자주 온다.
- 기대 피해(1막 일반 공연, 돌발 2장): 만족 약 −2~−6 또는 돈 약 −20~−55.

## 수용 기준

- EV1. 같은 시드·같은 계획이면 같은 카드가 같은 구간에 나온다. 가중치 0 인 카드는 나오지 않는다.
- EV2. 조건 가중치가 기준 시뮬에서 판정된다: 보안 1명·록 200명 계획에서 `entrance_jam`·`drunk_fight` 가중치가 18 이 된다.
- EV3. `security_ok` 가 거짓이면 `guards` 선택지가 보이지 않는다.
- EV4. 대비 카드가 맞는 태그 카드에서만 "대비 카드 사용"을 보여 주고, 쓰면 charges 가 1 준다.
- EV5. `seg_pct`·`seg_add` 효과는 카드 구간부터 마감까지만 적용된다.

## 테스트 방법

- `node prototype/v2/test_engine.mjs`: EV1(시드 고정 2회), EV2(가중치 계산 함수 단위 테스트), EV3·EV5(show.md 예시 (b) 계획에 `drunk_fight`·`beer_shortage` 를 강제 주입해 선택지 목록과 구간 숫자 확인), EV4.

## 열린 질문

| # | 질문 | 추천 기본값 |
|---|---|---|
| Q1 | 2막·3막 돌발 카드(날씨·정전·암표·안전사고 등) | 2막 수치 티켓에서 6~8장씩 추가. 1막 카드는 `act` 배열에 2 를 넣어 재사용 가능 |
| Q2 | 돌발 선택에 시간 제한(배속 중 결정) | 프로토타입은 시간이 멈춘 상태에서 선택. 플레이 후 재검토 |
| Q3 | 돈 선택지 금액을 막별로 늘릴지 | 2막부터 `money` 값에 `acts.money_scale_pct` 를 곱하는 규칙을 추가(카드별 값 재입력보다 단순) |
