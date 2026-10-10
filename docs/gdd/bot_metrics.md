# 봇 플레이 정책과 "한 번 더" 대리 지표 (bot_metrics.md)

| 항목 | 값 |
|---|---|
| 티켓 | SE-042 (1차 game-designer: 이 문서 / 2차 qa: 러너·통계·리포트) |
| 러너 | `project/tests/e2e/bot_runner.gd`(본체, `extends SceneTree`) + `tools/bot/play_bot.sh`(호출 래퍼) — qa |
| 정책 파일 | `tools/bot/policies/<id>.json` — qa 가 이 문서의 표를 옮겨 적는다(게임 데이터 아님) |
| 결과 | `tools/bot/results/SE-042.json`(기계용) + `docs/reports/SE-042.md`(표) — qa |
| 근거 | PRD "기술 요구사항"(밸런스는 봇 1,000판 통계), "마일스톤 로드맵"(MVP 검증 = 10분 플레이 뒤 "한 번 더", 프로덕션 관문 = 봇 1,000판 파산율 10~25 %), "리스크"(밸런스가 일찍 지루하거나 파산 빈발 → 매 마일스톤 봇 통계), [economy.md](economy.md) Q1(구제 2회는 봇 통계로 재조정)·기준/파산 시나리오, [reputation.md](reputation.md) RT1~RT6·부록 C, [show.md](show.md) 등급 임계, [audience.md](audience.md) 입장 수·가격 반응, [artist.md](artist.md) 섭외 K1~K5·성장 GR1~GR6, [build.md](build.md) 배치 B1~B11, [events.md](events.md) 명령 이벤트, SE-036 30일 리플레이(봇 v0) |

## 목적

사람 플레이 테스트(SE-043) 전에 세 가지를 숫자로 본다.

1. **10분(≈ 3일) 안에 결정할 거리가 생기는가.** 1일 ≈ 4분(economy.md "티어 2 해금 자금 도달 추정" 시간 근거)이라 10분 ≈ 2.5일, 넉넉히 3일차까지를 본다.
2. **30일(≈ 2시간) 안에 티어 2 가 보이는가.** PRD "티어 2까지 약 2시간".
3. **멍청한 정책은 파산하고, 신중한 정책은 살아남는가.** 정책 차이가 결과 차이를 만들어야 "결정"이 의미가 있다.

**이 문서의 지표는 "한 번 더"의 대리(proxy)다.** "한 번 더 하고 싶다"는 사람의 감정이라 봇이 직접 재지 못한다. 대신 그 감정이 생기기 위한 **필요조건**(돈이 움직인다, 곧 이익이 보인다, 새 선택지가 열린다, 목표가 손에 닿는다, 실수에 벌이 있다, 선택이 결과를 바꾼다)을 측정 가능한 문장으로 바꿨다. 대리 지표가 전부 목표 범위 안이어도 "한 번 더"가 보장되지는 않는다. 범위 밖이면 "한 번 더"가 나오기 어렵다는 신호로 읽는다. 최종 판정은 SE-043(프로덕트 오너 플레이 + 이 지표, 결정 로그 2026-10-10)이 한다.

범위: 티어 1, 30일, 정책 3종 × 시드 100. 밸런스 조정은 하지 않는다(측정만). 범위 밖 결과의 처리는 #범위-밖-결과의-처리.

## 규칙

### 실행 단위와 하루 진행

| # | 규칙 |
|---|---|
| R1 | **한 판** = `GameSession.new()` → `new_game_from_configs(seed, GameSession.load_configs())` → `autosave_enabled = false`(오토세이브는 결과에 영향이 없고 시간만 든다) → 1일차부터 `days`일까지. 파산(`economy.bankrupt`)하면 그날 close 에서 끝낸다(게임 오버). |
| R2 | **하루** = ① 낮 시작 경계(1일차는 새 게임 직후, 2일차부터는 `time.next_day_requested` → `advance(0)` 직후, `loop.phase == "day"`)에서 관측 → 정책 → 명령 발행 ② `advance(sim.json day_ticks)`(SE-036 리플레이와 같은 방식)로 close 까지 ③ close 경계에서 관측 → 구제 결정 → 지표 갱신 ④ 다음 날. |
| R3 | **봇이 내는 명령은 events.md 명령 이벤트뿐이다**: `build.place_requested`, `artist.book_requested`, `economy.ticket_price_requested`, `economy.bailout_accept_requested`, `time.next_day_requested`. `build.demolish_requested`·`time.speed_requested`·`session.*`는 쓰지 않는다(철거는 v0 정책에 없음, 배속은 헤드리스에서 무관, 세이브는 결과와 무관). |
| R4 | **같은 경계의 명령 순서**(큐 FIFO 그대로 처리되므로 결과에 영향): 섭외 → 가격 → 건설(큐 앞에서부터). 섭외를 먼저 두어 건설이 그날 개런티 현금을 먹지 않게 한다. |
| R5 | **관측은 상태 이벤트 구독으로만 한다**(#관측-상태). `GameSession`의 시스템 멤버를 읽어 정책을 정하지 않는다(UI 가 보는 정보와 같은 정보로 결정 — 러너가 sim 내부 구현에 묶이지 않게). 예외: 하루 진행 제어용 `loop.day`·`loop.phase`, 지표 교차 확인용 `cash()`·`reputation_total()`(정책 입력으로 쓰지 않음). |
| R6 | **결정성.** 정책은 관측 상태와 봇 RNG(#봇-rng)만의 함수다. 같은 (정책 파일, 시드, 일수) → 같은 명령 열 → 같은 결과 JSON(바이트 동일, AC2). 봇은 세션의 RNG 스트림(`sim.json rng_streams`)을 건드리지 않는다. |

### 관측 상태

봇이 구독으로 유지하는 값. 정책 표의 조건은 이 이름만 쓴다.

| 이름 | 출처 이벤트 | 값 |
|---|---|---|
| `cash` | `economy.cash_changed.cash`(마지막 값), 없으면 `economy.json starting_cash` | 현재 현금 |
| `rep` | `reputation.changed.total`(마지막), 없으면 0 | 종합 명성 |
| `roster[id]` | 시작값 `artists.json rows[]`(`grade`, `popularity`, `skill`), 갱신 `artist.grown`(`grade`, `popularity`, `skill`) | 아티스트별 현재 등급·인기 |
| `discovered[id]` | `artist.grown.promoted == true`면 `true` | 이 베뉴에서 승급한 아티스트(K4 면제) |
| `bookable(id)` | `rep ≥ artist.json grades[roster[id].grade].unlock_reputation` 또는 `discovered[id]` | K4 를 통과할지(봇의 예측, 실제 판정은 sim) |
| `guarantee(id)` | `economy.json guarantee_by_grade[roster[id].grade]` | 섭외 비용 |
| `coverage` | `build.coverage_changed`(마지막): `capacity`, `has_stage`, `upkeep_per_day` | 배치 상태 |
| `yday` | 전날의 `audience.admissions_decided`(`admissions`, `capped_by`, `capacity`)·`show.ended`(`grade`, `satisfaction_bp`)·`show.skipped` | 어제 결과(1일차는 없음) |
| `price` | `economy.ticket_price_changed.price`(마지막), 없으면 `ticket_price_default` | 현재 티켓 가격 |
| `pending_bailout` | close 에서 그날 `economy.bailout_offered`가 왔으면 그 페이로드 | 구제 제안 |
| `built` | 이 판에서 `build.placed`가 난 큐 항목 번호 집합 | 건설 큐 진행 |

### 정책 공통

- **개점 배치**: 세 정책 모두 1일차 낮 첫 명령으로 `tier1_club.json reference_layouts[baseline_show]` 6개(건설비 2,140, 수용 122, 유지비 123)를 놓는다. 사람은 무대를 반드시 놓으므로 "무대를 못 찾아 파산"은 측정 대상이 아니다. 개점 배치는 R4 의 "건설"보다 앞이다(무대 없이는 섭외해도 공연이 없다).
- **선택 동률**: 같은 점수면 `artists.json rows[]` 순서가 앞인 쪽.
- **섭외 비용 계산**: 봇은 `cash ≥ guarantee(id) + book_reserve`일 때만 섭외 명령을 낸다(뻔한 `insufficient_cash` 거절을 피한다). 무작위 정책은 이 검사를 하지 않는다.
- **건설 예산**: 그날 섭외할 개런티를 먼저 빼고, `cash − 개런티 − (이미 낸 건설비) − cost ≥ build_min_cash_after`인 동안 큐 앞에서부터 `build_max_per_day`개까지 낸다. 큐 항목이 거절되면(`build.rejected`) 그 항목은 건너뛴 것으로 표시하고 다음 날 다시 시도하지 않는다.
- **구제**: v0 는 구제를 거절할 수 없고(economy.md Q5) 수동 수락과 자동 수락의 결과가 같다(economy.md "파산 시나리오" 끝). 그래서 정책의 구제 열은 "그 close 에서 `economy.bailout_accept_requested`를 낼지"만 정하고, 결과 상태는 어느 쪽이든 같다. 이 열은 Q5 (b)(거절 = 즉시 파산)가 채택될 때 정책을 갈라 쓰기 위한 자리다.

### 정책 1 — 절약형 `frugal`

"돈을 아끼는 신중한 플레이어." 개점 배치 뒤 추가 투자 없음, 싼 아티스트(`local`, 개런티 400)만, 가격은 기본값.

| 시점 | 상태 조건 | 명령 |
|---|---|---|
| 1일차 낮 | — | 개점 배치 `baseline_show` 6개 `build.place_requested` |
| 매일 낮 | 후보 = `roster[id].grade == "local"`이고 `bookable(id)`인 아티스트. 후보가 있고 `cash ≥ 400 + book_reserve(0)` | 후보 중 `popularity` 최대 1명 `artist.book_requested`. 승급해 `rookie`가 된 아티스트는 후보에서 빠진다(개런티 800 을 내지 않음 → 다른 로컬로 갈아탐) |
| 매일 낮 | 후보 없음 또는 현금 부족 | 섭외 없음(그날 `show.skipped {no_lineup}`) |
| 매일 낮 | — | 가격 명령 없음(20 유지) |
| 매일 낮 | — | 추가 건설 없음(`build_queue` 빈 배열) |
| close | `pending_bailout != null` | `economy.bailout_accept_requested` |
| close | 파산 아님 | `time.next_day_requested` |

예상 궤적(손계산 아님, 근거): 1~6일 `thumbnail_soda`(s07, indie, 인기 27) — SE-036 표와 같음. 7일 공연 뒤 승급 → 8일부터 `flipped_setlist`(s03, rock, 24) → 약 8회 뒤 승급 → `eight_opener`(s10, electronic, 21) … 장르가 바뀌며 정체성 보정이 끊기고(reputation.md FC3) 장르 적합이 달라진다. 개런티는 30일 내내 400.

### 정책 2 — 공격형 `aggressive`

"번 돈을 바로 공간과 아티스트에 넣는 플레이어." 인기 최대 아티스트(신인 포함), 건설 큐 소진, 만석이면 가격 인상.

| 시점 | 상태 조건 | 명령 |
|---|---|---|
| 1일차 낮 | — | 개점 배치 `baseline_show` 6개 |
| 매일 낮 | 후보 = `bookable(id)`인 전원. `cash ≥ guarantee(id) + book_reserve(0)`인 후보 중 `popularity` 최대 | 그 1명 `artist.book_requested`. 신인 해금(`rep ≥ 150`) 전에도 승급한 아티스트(`discovered`)는 후보다 |
| 매일 낮 | 위 후보가 없음(현금 부족) | `grade == "local"` 후보 중 `popularity` 최대(현금 ≥ 400 일 때). 그것도 없으면 섭외 없음 |
| 매일 낮(2일차~) | `yday.capped_by == "capacity"`이고 `yday.grade ∈ {good, rave}` | `price + price_step(2)`, 상한 `price_max(26)` — 같은 값이면 명령 없음 |
| 매일 낮(2일차~) | `yday.grade ∈ {disaster, poor, ok}` 또는 `yday.admissions × 10000 < price_low_fill_bp(8,500) × yday.capacity` | `price − 2`, 하한 `price_min(20)` |
| 매일 낮(2일차~) | 그 밖 | 가격 명령 없음 |
| 매일 낮 | 건설 예산(#정책-공통, `build_min_cash_after` 1,000, `build_max_per_day` 9) | 아래 건설 큐를 앞에서부터 |
| close | `pending_bailout != null` | `economy.bailout_accept_requested` |
| close | 파산 아님 | `time.next_day_requested` |

**건설 큐** (`build_oracle.py` 로 `baseline_show` 뒤 순서대로 놓아 9개 모두 배치 가능함을 확인 — 2026-10-10, origin/main cfe5392 데이터):

| # | `furniture_id` | `cell` | `rotation` | 건설비 | 누적 | 놓은 뒤 수용 / 음향 bp / 만족 가산 bp / 유지비 |
|---|---|---|---|---|---|---|
| 1 | `speaker_floor` | [5, 10] | 0 | 200 | 200 | 122 / 5,074 / 100 / 138 |
| 2 | `speaker_floor` | [18, 10] | 0 | 200 | 400 | 121 / 7,766 / 100 / 153 (= `baseline_plus_two_speakers`) |
| 3 | `toilet_booth` | [21, 17] | 90 | 250 | 650 | 121 / 7,805 / 400 / 168 |
| 4 | `toilet_booth` | [21, 19] | 90 | 250 | 900 | 120 / 7,844 / 700 / 183 |
| 5 | `neon_sign` | [3, 1] | 180 | 200 | 1,100 | 120 / 7,864 / 800 / 189 |
| 6 | `neon_sign` | [8, 1] | 180 | 200 | 1,300 | 120 / 7,884 / 900 / 195 |
| 7 | `neon_sign` | [16, 1] | 180 | 200 | 1,500 | 120 / 7,904 / 1,000 / 201 |
| 8 | `bench` | [1, 16] | 270 | 120 | 1,620 | 123 / 7,944 / 1,050 / 205 |
| 9 | `bench` | [1, 4] | 270 | 120 | 1,740 | 127 / 7,959 / 1,100 / 209 |

근거: 음향(23.7 % → 79.6 %)과 편의 가산(100 → 1,100)은 show.md "열광까지" 표의 열광 조건(가산 700 이상 + 실력)으로 가는 투자다. 피난 부족(`evac_shortfall`)은 v0 에서 만족·입장에 쓰이지 않아 출구는 넣지 않았다. 1일차: 2,860 − 400(개런티) = 2,460 → 예산 1,460 으로 1~6번(1,300)까지, 나머지는 2일차 이후.

### 정책 3 — 무작위 `random`

"규칙을 모르고 메뉴를 아무렇게나 누르는 플레이어." 개점 배치만 공통이고, 나머지는 봇 RNG 로 고른다. **파산율이 높아야 정상**이다(#목표-범위 M7).

| 시점 | 상태 조건 | 명령(뽑기 번호는 #봇-rng) |
|---|---|---|
| 1일차 낮 | — | 개점 배치 `baseline_show` 6개 |
| 매일 낮 | — | ① `artists.json rows[]` 12명 중 균등 1명 `artist.book_requested` — 잠김·현금 부족 검사 없음(거절되면 그날 공연 없음) |
| 매일 낮 | — | ② 가격 `ticket_price_min..max`(5..40) 균등 정수 `economy.ticket_price_requested` — 현재 가격과 같으면 명령 없음 |
| 매일 낮 | ③ `u mod 10000 < random_build_bp(2,500)` | ④ `furniture.json rows[]` 20종 중 균등 1종, ⑤ `x` ∈ 0..`width−1`, ⑥ `z` ∈ 0..`depth−1`, ⑦ 회전 4종 중 균등 → `build.place_requested` 1개(거절 허용 — 거절 사유는 `build_rejected_by_reason`으로 센다) |
| close | ⑧ `pending_bailout != null`이고 `u mod 10000 < random_accept_bp(5,000)` | `economy.bailout_accept_requested`. 아니면 명령 없이 다음 날(자동 수락, 결과 동일) |
| close | 파산 아님 | `time.next_day_requested` |

### 봇 RNG

- 무작위 정책만 쓴다. 절약형·공격형은 난수를 쓰지 않는다.
- 생성: 러너가 판마다 Godot `RandomNumberGenerator` 하나를 새로 만들고 `seed = game_seed × 1,000 + rng_salt`(`rng_salt` 는 정책 파일, 무작위 정책 7), `state` 는 건드리지 않는다. 세션의 `SeededRng`·스트림(`audience` 등)과 공유하지 않는다(R6).
- 뽑기: `randi()`(uint32) 1회 = 1 뽑기, 범위는 `u mod n`(작은 편향은 허용 — 결정성만 필요). **하루에 정확히 8회**를 고정 순서 ①~⑧로 뽑는다. ③에서 건설하지 않기로 해도 ④~⑦을 뽑고 버리며, ⑧은 구제 제안이 없어도 뽑고 버린다. 그래서 n일차의 뽑기는 앞날의 결과와 무관하게 항상 `8(n−1)+1`번째부터다(같은 시드에서 정책 파라미터를 바꿔 비교할 때 난수 열이 어긋나지 않게).

### 대리 지표

계산은 전부 상태 이벤트에서 한다(R5). `d` = 날짜(1..30). "≤ 3일차" = 3일 close 경계까지. 일 단위 지표가 30일 안에 오지 않았으면 `null`(미도달), 파산한 판은 파산일 close 까지만 센다.

| # | 키 | 대리하는 것 | 정의·계산식 | 출처 이벤트 |
|---|---|---|---|---|
| M1 | `cash_swing_d3` | 10분 안에 돈이 움직인다(긴장) | 시작 현금과 1~3일의 모든 `economy.cash_changed.cash` 값 중 `max − min` | `economy.cash_changed` |
| M2 | `first_profit_day` | 곧 이익이 보인다 | `economy.day_settled.net > 0`인 첫 `day` | `economy.day_settled` |
| M3 | `payback_day` | 개점 투자를 회수한다(첫 목표 달성감) | `economy.day_settled.cash ≥ economy.json starting_cash`인 첫 `day` | `economy.day_settled` |
| M4 | `grade_share_bp.{disaster,poor,ok,good,rave,skipped}` | 공연 결과에 굴곡이 있다 / 투자가 질로 보인다 | 정책별로 모든 시드의 모든 진행일(파산 판은 파산일까지)을 모아 등급별 일수 ÷ 진행일 × 10,000(내림). `skipped` = `show.skipped`인 날. 시드별 값은 `runs[].grade_days` | `show.ended.grade`, `show.skipped` |
| M5 | `rep500_day` | 중기 목표(티어 2 명성)가 손에 닿는다 | `reputation.changed.total ≥ tiers.json tier_2.unlock_reputation`(500)인 첫 `day` | `reputation.changed` |
| M6 | `tier2_day`, `tier2_rate_bp` | 30일 안에 티어 2 가 보인다 | `reputation.tier_unlocked {tier: 2}`의 `day`. 비율 = 해금한 판 ÷ 판 수 × 10,000 | `reputation.tier_unlocked` |
| M7 | `bankrupt_rate_bp`, `bankrupt_day`, `bailouts_taken` | 실수에 벌이 있고, 신중하면 산다 | 파산 판 ÷ 판 수 × 10,000. 파산일 = `economy.bankrupt.day`. 구제 수 = `economy.bailout_taken` 횟수 | `economy.bankrupt`, `economy.bailout_taken` |
| M8 | `first_prompt_day`, `prompts_d10` | 새 선택지가 열린다(결정 분기) | **선택 유발 사건** 5종 — (a) `rookie_unlock`: `reputation.changed.total ≥ artist.json grades[rookie].unlock_reputation`(150) 첫 도달, (b) `promotion`: `artist.grown.promoted == true`(개런티가 오른다 — 유지 vs 교체), (c) `sold_out`: `audience.admissions_decided.capped_by == "capacity"`(수용 확장·가격 인상), (d) `first_failure`: `show.ended.grade ∈ {disaster, poor}`, (e) `bailout`: `economy.bailout_offered`. `first_prompt_day` = 5종 중 아무거나 처음 일어난 날, `prompts_d10` = 10일 close 까지 한 번이라도 일어난 종류 수(0~5). 봇이 실제로 그 선택을 했는지와 무관하게 "플레이어에게 결정을 요구하는 사건"을 센다 | 표 안 |
| M9 | `spread_rep500_days`, `spread_final_cash` | 선택이 결과를 바꾼다(정책 간 차이) | 리포트 단계에서 계산: `median(frugal.rep500_day) − median(aggressive.rep500_day)`(미도달 31 로 셈), `median(frugal.final_cash) − median(random.final_cash)`. `final_cash` = 30일(파산 판은 파산일) 정산 뒤 `day_settled.cash` | M5, `economy.day_settled` |
| M10 | `soldout_sat_mean_bp`, `soldout_below_good_bp`, `soldout_days` | (SE-030 검토 항목 ①) 만석이면 혼잡 감점으로 호평 아래로 떨어지는가 | 만석일 = 그날 `audience.admissions_decided.capped_by == "capacity"`이고 `show.ended`가 난 날. 평균 = 만석일 `show.ended.satisfaction_bp` 합 ÷ 만석일 수(내림), 아래 비율 = 만석일 중 `grade ∈ {disaster, poor, ok}` ÷ 만석일 × 10,000. 시드를 모아(pooled) 정책별 1개 값 | `audience.admissions_decided`, `show.ended` |
| M11 | `fail_days`, `skip_days`, `net_fail_mean`, `net_skip_mean`, `rep_fail_mean` | (SE-030 검토 항목 ②) 공연 포기(`skipped`)가 실패 공연보다 유리해지는가 | 실패일 = `show.ended.grade ∈ {disaster, poor}`, 포기일 = `show.skipped`. 각 날의 `economy.day_settled.net` 평균, 실패일의 `reputation.changed.delta` 평균(포기일은 RG0 으로 0). 시드를 모아 정책별 1개 값. 판정은 `net_fail_mean − net_skip_mean`(실패 공연이 그래도 돈은 더 번다 → 포기가 지배 전략이 아님) | `show.ended`, `show.skipped`, `economy.day_settled`, `reputation.changed` |
| M12 | `zero_admission_shows` | (SE-035 F7 입력) 입장 0 명 공연(`disaster` 처리)이 실제로 나오는가 | `show.ended.admissions == 0`인 날 수(정책별 합)와 공연일 대비 비율 bp | `show.ended` |

보조(목표 없음, 검산·버그 감지용 — 리포트에 함께 싣는다): `final_cash`, `final_rep`, `shows`, `booking_rejected_by_reason`(`artist.booking_rejected.reason`별 수), `build_rejected_by_reason`(`build.rejected.reason`별 수), `distinct_artists`(섭외한 서로 다른 아티스트 수), `price_changes`(`economy.ticket_price_changed` 수).

### 통계 형식

| 항목 | 규칙 |
|---|---|
| 시드 | `1..100`(SE-036 시드 36 포함). 일수 30. 정책 3. 합 300판 |
| 시드별 값 | `runs[]`에 판마다 모든 키. 정수 또는 `null`(미도달) |
| 분위수 | 정책별로 값을 오름차순 정렬(`null`은 맨 뒤, +∞ 로 취급)한 길이 `n` 배열 `v`에서 **최근접 순위**: `P(p) = v[⌈p × n ÷ 100⌉ − 1]`, Q1 = P(25), 중앙값 = P(50), Q3 = P(75). 정수만 나온다(보간 없음 → 바이트 결정성). 결과가 `null`이면 표에 `>30`(미도달)으로 적는다 |
| 비율 | 정수 bp(10,000 = 100 %), 내림. 표에는 % 로 소수 1자리(예: 1,250 bp → 12.5 %) |
| 도달률 | 일 단위 지표(M2·M3·M5·M6·M8 `first_prompt_day`)는 `reached_bp` = `null`이 아닌 판 ÷ 판 수도 함께 |
| 모은 값(pooled) | M4·M10·M11·M12 는 정책별로 모든 판을 합쳐 한 값. 분위수 없음 |
| 정책 간 값 | M9 는 정책 요약에서 계산. 판별 값 없음 |
| 합산 파산율 | `bankrupt_rate_bp_pooled` = 세 정책 300판 중 파산 판 ÷ 300 × 10,000(PRD 관문 "파산율 10~25 %"의 MVP 판 대응값) |

### 목표 범위

v0 목표(이 문서가 첫 정의). "−" 는 목표 없음(기록만). 근거 열의 숫자는 각 문서의 손계산·기준 시나리오다.

| # | 지표(통계) | frugal | aggressive | random | 근거 |
|---|---|---|---|---|---|
| M1 | `cash_swing_d3` 중앙값 | 2,000~5,000 | 2,000~5,000 | − | 시작 현금 5,000 의 40~100 %. 봇 v0 는 1일 2,460(개점 + 개런티 뒤 최저) → 3일 5,573 = 3,113. 2,000 미만이면 첫 3일이 정적, 5,000 초과면 시작 자금보다 크게 흔들림 |
| M2 | `first_profit_day` Q3 | ≤ 2 | ≤ 3 | − | 10분 ≈ 2.5일 안에 흑자 하루. 봇 v0 1일 `net` 853. 공격형은 가격·건설로 늦어질 수 있어 1일 여유 |
| M3 | `payback_day` 중앙값 | 3~8 | 4~10 | − | 개점 2,140 + 개런티를 회수하는 날. 봇 v0 3일(5,573). 2일 이하면 투자가 무의미하게 싸고, 10일 넘으면 40분 넘게 적자 체감 |
| M4 | `grade_share_bp` | good+rave ≥ 70 %, disaster+poor ≤ 10 % | rave ≥ 10 %, disaster+poor ≤ 10 % | disaster+poor+skipped ≥ 30 % | show.md: 기준 배치 + 맞는 라인업 = 호평(6,732). 공격형 가산 1,100 은 "열광까지" 표의 열광 조건(가산 700 + 실력)에 걸친다. 무작위는 가격 40·잠긴 신인 섭외로 실패·포기가 잦아야 한다 |
| M5 | `rep500_day` 중앙값 | 20~30 | 15~26 | 중앙값 `>30` | reputation.md RT1(20~30). 봇 v0 21일. 공격형은 투자가 명성으로 돌아와야 한다(M9 와 짝) |
| M6 | `tier2_rate_bp` / `tier2_day` 중앙값 | ≥ 80 % / 20~30 | ≥ 80 % / 15~28 | ≤ 30 % / − | 목적 2. 봇 v0 22일. economy `checks.tier2_max_days` 30 |
| M7 | `bankrupt_rate_bp` | ≤ 5 % | ≤ 15 % | 30~90 % | 신중한 정책이 죽으면 경제가 가혹하고(economy Q1 재검토), 무작위가 안 죽으면 실수에 벌이 없다. 무작위 100 % 면 회복 수단(구제 2회)이 무의미. **합산** `bankrupt_rate_bp_pooled` 10~25 %(PRD 프로덕션 관문 값의 MVP 대응, MVP 에서는 참고 — 관문 판정은 프로덕션 1,000판) |
| M8 | `first_prompt_day` 중앙값 / `prompts_d10` 중앙값 | ≤ 4 / ≥ 2 | ≤ 4 / ≥ 2 | − | 목적 1. 4일 ≈ 16분(10분 세션 + 다음 세션 초반). 봇 v0 는 신인 해금·승급 7일, 만석 10일 → `first_prompt_day` 7 로 **범위 밖이 예상된다**(아래 "예상 범위 밖") |
| M9 | `spread_rep500_days` / `spread_final_cash` | ≥ 2일 / ≥ 5,000 | (같은 행) | (같은 행) | 공격형 투자가 명성 500 을 2일 이상 당기지 못하면 투자 결정이 무의미. 무작위와 절약형의 30일 자금 차가 시작 자금(5,000)보다 작으면 결정이 결과를 못 바꾼다 |
| M10 | `soldout_below_good_bp` / `soldout_sat_mean_bp` | ≤ 20 % / ≥ 6,200 | ≤ 20 % / − | − | SE-030 검토 ①: 부록 C 의 만석(122) s07 6,198 은 good 임계 6,000 과 198 차. 만석일의 20 % 넘게 보통 이하면 "꽉 채우기"가 벌을 받는 정도가 의도(혼잡 = 다른 선택)보다 크다. 평균 6,200 은 임계 + 200(노이즈 여유) |
| M11 | `net_fail_mean − net_skip_mean` | − | − | ≥ 300 | SE-030 검토 ②: 포기일은 명성 0·현금 약 −800(임대 600 + 유지비), 실패일은 명성 −5~−30 이지만 티켓·바 매출이 있다. 실패 공연이 포기보다 하루 300 이상 더 벌어야 "공연을 여는 것"이 지배당하지 않는다. 무작위만 두 경우가 충분히 나온다 |
| M12 | `zero_admission_shows` 비율 | − | − | − | 목표 없음 — SE-035 F7 판정 입력: 세 정책 합산 공연일의 1 % 이상이면 F7(입장 0 명인 날의 명성 처리) 재검토 티켓, 미만이면 현행(`disaster`) 유지 |

**예상 범위 밖(사전 기록).** 봇 v0 궤적으로 보면 M8 `first_prompt_day`(7일)는 범위 밖일 가능성이 높다. 첫 3일에는 새 선택지가 열리지 않는다는 뜻이고, PRD MVP 질문("10분 뒤 한 번 더")과 가장 직접 충돌한다. 결과가 그렇게 나오면 수치(신인 해금 명성 150, 승급 인기 40, 개점 배치 수용)를 당기는 밸런스 티켓 후보 1순위로 둔다 — 목표를 결과에 맞춰 늦추지 않는다.

### 범위 밖 결과의 처리

1. qa 는 리포트 표의 각 칸에 **안 / 밖**을 적고, 밖인 칸마다 "밸런스 티켓 후보" 1줄(지표, 정책, 관측 중앙값 [Q1, Q3], 목표, 아래 레버 표의 담당 문서)을 쓴다. 수치 제안은 하지 않는다(관찰만 — 티켓 AC3).
2. producer 가 후보를 묶어 game-designer 밸런스 티켓을 발행한다. game-designer 는 `docs/gdd/balance/YYYY-MM-DD.md` 에 바꾼 수치와 이유를 적고, 같은 정책·시드로 다시 돌린 결과를 근거로 단다.
3. **버그 감지와 밸런스를 섞지 않는다.** 다음은 밸런스가 아니라 버그 후보(qa → sim-engineer/qa 티켓): 절약형·공격형의 `build_rejected_by_reason`에 `insufficient_cash` 밖의 사유가 있음(큐 좌표가 데이터와 어긋남), 절약형·공격형의 `booking_rejected_by_reason` 0 이 아님(봇 예측 `bookable`과 K4 불일치), `v0_replay` 보정(#봇-v0-와의-관계)이 SE-036 값과 다름, 같은 입력 2회 결과가 다름.
4. 목표 범위 자체가 틀렸다고 판단되면(예: 모든 정책이 같은 방향으로 벗어나고 플레이 감각은 괜찮음) game-designer 가 이 문서의 목표를 고치고 변경 이력에 근거를 남긴다. 결과에 맞춰 목표를 옮기는 것은 SE-043 판정 뒤에만 한다.

| 지표 | 주 레버(데이터) | 담당 문서 |
|---|---|---|
| M1·M2·M3 | `economy.json starting_cash`·`rent_per_day`, 가구 `build_cost`, 개점 배치 | economy.md, build.md |
| M4·M10 | `show.json grades[].min_bp`, `audience.json satisfaction.*`(`crowd_comfort_bp`, `penalty_weights_bp`), 가구 `satisfaction_bonus_bp` | show.md, audience.md, build.md |
| M5·M6·M9 | `reputation.json base_by_grade`·`admission_factor`·보정, `tiers.json` 해금 값(PRD 결정 — 바꾸려면 ADR) | reputation.md |
| M7·M11 | `economy.json bailout_*`·`bailout_count`(Q1), `guarantee_by_grade` | economy.md |
| M8 | `artist.json grades[rookie].unlock_reputation`·`promote_at_popularity`, 개점 배치 수용 | artist.md, audience.md |
| M12 | reputation RG2(입장 0 명 처리) | reputation.md, show.md DS5 |

### 봇 v0 와의 관계

- SE-036 30일 리플레이(`project/tests/sim/replay/test_replay_tier1_loop.gd`)의 명령 열이 **봇 v0** 다: 시드 36, 1일차 `baseline_show`, 매일 `thumbnail_soda` 섭외(승급 뒤에도 같은 아티스트, 개런티 800), 가격 20, 추가 건설 없음. 결과: 명성 500 21일, 자금 30,000·티어 2 해금 22일, 30일 끝 41,294 / 756, 구제·파산·거절 0(docs/tickets/SE-036.md 결과 절, SE-057 이 reputation.md "통합 기준 시나리오"로 승인 중).
- 러너는 보정용 정책 `v0_replay`(정책 파일 `tools/bot/policies/v0_replay.json`, `artist_pick: "fixed"`, `artist_id: "thumbnail_soda"`)를 함께 갖는다. **시드 36·30일로 돌린 결과가 위 값과 같아야** 러너가 세션을 SE-036 과 같은 방식으로 구동한다고 본다(R2). 이 정책은 통계 표의 정책 3종에 넣지 않는다.
- 절약형은 봇 v0 와 승급 전(1~7일)까지 같은 명령을 낸다. 8일부터 갈라진다(절약형은 로컬로 갈아탐). 그래서 시드 36 의 절약형 1~7일 close 값 = SE-036 표 1~7일(현금 3,713 … 11,053, 명성 18 … 158)이어야 한다(러너 단위 테스트에 쓸 수 있는 고정점).
- 리플레이 테스트는 회귀(시스템이 함께 도는가), 이 문서는 분포(정책·시드가 바뀌면 어디까지 흔들리는가)다. 리플레이의 단언 범위(해금 20~30일)는 바꾸지 않는다.

### 정책 파일 형식 (`tools/bot/policies/<id>.json`, qa 작성)

키 목록. 값은 이 문서의 정책 표에서 옮긴다(숫자를 러너 코드에 넣지 않는다 — CLAUDE.md 데이터 주도 원칙을 도구에도 적용).

| 키 | 타입 | frugal | aggressive | random | v0_replay | 뜻 |
|---|---|---|---|---|---|---|
| `version` | int | 1 | 1 | 1 | 1 | 파일 형식 버전 |
| `id` | String | `"frugal"` | `"aggressive"` | `"random"` | `"v0_replay"` | 파일 이름과 같음 |
| `spec` | String | `"docs/gdd/bot_metrics.md#정책-1--절약형-frugal"` 등 | | | | 출처 |
| `opening_layout` | String | `"baseline_show"` | 〃 | 〃 | 〃 | `tier1_club.json reference_layouts[].id` |
| `artist_pick` | String | `"max_popularity_local"` | `"max_popularity"` | `"uniform_random"` | `"fixed"` | 섭외 규칙 |
| `artist_id` | String\|null | null | null | null | `"thumbnail_soda"` | `fixed` 일 때만 |
| `book_reserve` | int | 0 | 0 | null | 0 | 섭외 조건 `cash ≥ guarantee + book_reserve`. `null` = 검사 안 함 |
| `price_mode` | String | `"fixed"` | `"demand_step"` | `"uniform_random"` | `"fixed"` | |
| `price_fixed` | int\|null | null(기본가 유지 = 명령 없음) | null | null | null | 값이 있으면 1일차에 그 가격 명령 |
| `price_min` / `price_max` / `price_step` | int\|null | null | 20 / 26 / 2 | null(경제 범위 5..40 사용) | null | |
| `price_low_fill_bp` | int\|null | null | 8,500 | null | null | |
| `build_queue` | Array[{`furniture_id`, `cell`, `rotation`}] | `[]` | 위 건설 큐 9개 | `[]` | `[]` | 개점 배치 뒤 순서대로 |
| `build_min_cash_after` | int | 0 | 1,000 | 0 | 0 | 건설 뒤 남길 현금(개런티 뺀 뒤) |
| `build_max_per_day` | int | 0 | 9 | 1 | 0 | |
| `random_build_bp` | int\|null | null | null | 2,500 | null | ③ 확률 |
| `random_accept_bp` | int\|null | null | null | 5,000 | null | ⑧ 확률 |
| `rng_salt` | int\|null | null | null | 7 | null | 봇 RNG 시드 = `game_seed × 1,000 + rng_salt` |
| `bailout_accept` | String | `"always"` | `"always"` | `"random"` | `"always"` | close 수락 명령 |

목표 범위는 `tools/bot/policies/targets.json`(qa)에 #목표-범위 표를 그대로 옮긴다: `{"version": 1, "spec": "docs/gdd/bot_metrics.md#목표-범위", "targets": [{"metric": "cash_swing_d3", "stat": "median", "policy": "frugal", "min": 2000, "max": 5000}, …]}` — 한쪽만 있으면 다른 쪽 `null`, 비율은 bp. reviewer 가 표와 파일을 대조한다.

### 결과 파일 형식

**`tools/bot/results/SE-042.json`** — 같은 입력이면 바이트 동일(AC2). 실행 시간·날짜·경로처럼 실행마다 달라지는 값은 넣지 않는다(실행 시간은 리포트 md 에만). 키 순서는 아래 순서, `JSON.stringify(v, "  ", false)`(정렬 안 함 — 삽입 순서 고정).

```json
{
  "ticket": "SE-042",
  "spec": "docs/gdd/bot_metrics.md",
  "spec_version": 1,
  "days": 30,
  "seeds": {"first": 1, "count": 100},
  "policies": ["frugal", "aggressive", "random"],
  "by_policy": {
    "frugal": {
      "policy_file_sha1": "<tools/bot/policies/frugal.json 의 sha1>",
      "summary": {
        "cash_swing_d3": {"n": 100, "q1": 2980, "median": 3113, "q3": 3260, "reached_bp": 10000},
        "first_profit_day": {"n": 100, "q1": 1, "median": 1, "q3": 1, "reached_bp": 10000},
        "rep500_day": {"n": 100, "q1": 22, "median": 24, "q3": null, "reached_bp": 7300},
        "...": "M1~M3·M5·M6·M8 일 단위·정수 지표 전부 같은 꼴"
      },
      "pooled": {
        "grade_share_bp": {"disaster": 0, "poor": 0, "ok": 120, "good": 9880, "rave": 0, "skipped": 0},
        "bankrupt_rate_bp": 0,
        "tier2_rate_bp": 8100,
        "soldout": {"days": 1712, "sat_mean_bp": 6241, "below_good_bp": 1400},
        "fail_vs_skip": {"fail_days": 0, "skip_days": 0, "net_fail_mean": null, "net_skip_mean": null, "rep_fail_mean": null},
        "zero_admission_shows": {"count": 0, "of_shows": 3000}
      },
      "runs": [
        {"seed": 1, "bankrupt_day": null, "bailouts_taken": 0, "final_cash": 39120, "final_rep": 702,
         "metrics": {"cash_swing_d3": 3090, "first_profit_day": 1, "payback_day": 3, "rep500_day": 23, "tier2_day": 24,
                     "first_prompt_day": 7, "prompts_d10": 3},
         "grade_days": {"disaster": 0, "poor": 0, "ok": 0, "good": 30, "rave": 0, "skipped": 0},
         "rejections": {"booking": {}, "build": {}},
         "shows": 30, "distinct_artists": 4, "price_changes": 0}
      ]
    },
    "aggressive": {"...": "같은 꼴"},
    "random": {"...": "같은 꼴"}
  },
  "cross_policy": {"spread_rep500_days": 3, "spread_final_cash": 21400, "bankrupt_rate_bp_pooled": 1567},
  "calibration": {"v0_replay": {"seed": 36, "tier2_day": 22, "rep500_day": 21, "final_cash": 41294, "final_rep": 756, "match": true}}
}
```

(숫자는 형식 예시다. 기대값이 아니다.)

**`docs/reports/SE-042.md`** — 표 3개 + 후보 목록.

1. 실행 정보: 커밋, 명령, 시드 수(100 또는 축소한 수와 이유), 정책 파일 sha1, 실행 시간(정책별, 분), 결정성 확인(2회 `cmp`), `v0_replay` 보정 일치.
2. **정책 × 지표 표**(분위 지표): 행 = 지표 키, 열 = 정책별 `중앙값 [Q1, Q3]`·도달률, 목표, **안/밖**.
3. **모은 값 표**: M4 등급 분포(% 6칸), M7 파산율·합산 파산율, M6 해금률, M10·M11·M12, 각 목표와 안/밖.
4. 범위 밖 항목마다 "밸런스 티켓 후보: <지표> <정책> 관측 <값> 목표 <범위> → <담당 문서>" 1줄. 버그 후보는 별도 목록(#범위-밖-결과의-처리 3).

### 실행 시간

SE-036 측정은 하루 약 1.2 초(관객 120명대)다. 300판 × 30일 = 9,000일이면 단일 프로세스로 약 3시간이라 티켓 예상(≤ 10분)을 넘는다. 순서대로 적용한다.

1. 파산 판은 파산일에 끝난다(R1). 오토세이브를 끈다(R1).
2. 러너는 `--seed-start <s> --seeds <n>`로 시드 구간을 나눠 여러 프로세스로 돌리고, `--merge`로 시드 순서대로 합친다(합친 결과가 한 번에 돌린 결과와 바이트 동일해야 한다 — 판 사이에 상태를 공유하지 않으므로 가능).
3. 그래도 벽시계 60분을 넘으면 시드를 `1..30`으로 줄이고 리포트 실행 정보에 이유·측정 시간을 적는다(티켓 범위의 "시드 30" 대체안). 30판이면 파산율의 해상도가 3.3 %p 라 M7 판정은 "참고"로 표시한다.

## 수용 기준

| # | 기준 | 확인 |
|---|---|---|
| BM1 | 정책 3종이 "시점·상태 조건 → 명령" 표로 있고, 명령 열에는 events.md 명령 이벤트 이름만 나온다 | reviewer grep |
| BM2 | 대리 지표 ≥ 6(M1~M12)이 각각 정의·계산식·출처 이벤트·목표 범위·근거를 갖고, "대리"임이 #목적에 적혀 있다 | reviewer |
| BM3 | 무작위 정책의 난수는 시드 고정 봇 RNG 에서만, 하루 8회 고정 순서로 뽑는다. 세션 RNG 스트림을 쓰지 않는다 | reviewer, qa 단위 테스트(같은 정책·시드 2회 바이트 동일) |
| BM4 | 공격형 건설 큐 9개는 `baseline_show` 뒤 순서대로 놓으면 전부 배치된다(`build_rejected_by_reason`에 `insufficient_cash` 밖 사유 0) | qa 실행 결과 |
| BM5 | `v0_replay` 시드 36·30일 = 해금 22일, 명성 500 21일, 30일 끝 41,294 / 756 | qa 실행 결과 `calibration.match == true` |
| BM6 | 결과 JSON 이 #결과-파일-형식 의 키를 전부 갖고, 실행마다 달라지는 값이 없다 | qa 단위 테스트 `test_bot_runner.gd` |

## 테스트 방법

- 이 문서(1차): `python3 tools/validate_data.py --strict` exit 0(데이터 변경 없음 확인). reviewer 가 BM1·BM2 를 표로 대조.
- 2차(qa): `tools/run_tests.sh project/tests/e2e` → `test_bot_runner.gd`(정책 `frugal`·시드 1·3일 2회 → 결과 바이트 동일, #결과-파일-형식 키 전부, 시드 36 `frugal` 1~3일 close 현금 = SE-036 표 3,713 / 4,652 / 5,573). `tools/bot/play_bot.sh --policy <id> --seeds 100 --days 30`(× 3 정책) + `--policy v0_replay --seed-start 36 --seeds 1 --days 30`.

## 열린 질문

| # | 질문 | 선택지 | 추천 | 바꾸면 |
|---|---|---|---|---|
| Q1 | SE-043 결정 로그의 "봇 1,000판" 과 이 티켓의 300판(100 × 3) | (a) MVP 판정은 이 문서의 300판(또는 축소 90판)으로, 1,000판은 PRD 대로 프로덕션 관문 (b) SE-043 전에 1,000판 | **(a).** 실행 시간(약 3시간/300판, #실행-시간)과 CI 결정(2026-10-09 "봇은 관문 때 수동"). 1,000판은 러너가 빨라지면 nightly 티켓 | (b)는 시드 수만 바꿔 같은 러너로 |
| Q2 | 정책 혼합 비율 | 합산 파산율을 세 정책 같은 비중으로 셀지 | **같은 비중.** 실제 플레이어 분포 근거가 없다. SE-043 뒤 사람 플레이 로그가 생기면 비중을 정한다 | `cross_policy` 계산만 |
| Q3 | 장르 집중 vs 확산(reputation.md Q5)의 봇 측정 | (a) 이번엔 안 함 (b) 정책 4 `identity`(한 장르 고정) 추가 | **(a).** `reputation.changed`에 `focus`가 없어 이벤트만으로는 못 센다. 필요하면 `compute_delta` 재계산을 리포트 단계에서 하는 후속 티켓 | (b)는 정책 파일 1개 + 지표 1개 |
| Q4 | 공격형 가격 상한 26 | 26 / 30 | **26.** 30 이면 가격 만족(SF3)이 1,500 → 600 으로 떨어져 호평이 보통으로 내려간다(audience.md 가격 반응 표, `local_top_price30` 5,730). 공격형의 실패 원인이 가격 하나로 정해지지 않게 | 정책 파일 값만 |

## 변경 이력

| 날짜 | 버전 | 티켓 | 내용 |
|---|---|---|---|
| 2026-10-10 | bot_metrics.md v0 (spec_version 1) | SE-042 1차 | 신규. 실행 규칙 R1~R6, 관측 상태, 정책 3종(절약형·공격형·무작위) + 보정 정책 `v0_replay`, 봇 RNG(하루 8회 고정 순서), 대리 지표 M1~M12(SE-030 검토 항목 2건 = M10·M11, SE-035 F7 입력 = M12), 통계 형식(최근접 순위 분위수, bp 정수), 목표 범위, 범위 밖 처리·레버 표, 정책·목표·결과 파일 형식, 실행 시간 대책. 데이터 테이블 변경 없음 |
