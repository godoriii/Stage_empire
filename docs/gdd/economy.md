# 경제 (economy.md)

| 항목 | 값 |
|---|---|
| 상태 | v0 |
| 스펙 티켓 | SE-005 (game-designer) |
| 구현 티켓 | SE-012 (sim-engineer) — `project/sim/economy_config.gd`, `project/sim/economy.gd`, `project/tests/sim/test_economy_config.gd`, `project/tests/sim/test_economy.gd` (`tools/hooks/check_commit.py`가 `.gd`마다 짝 테스트 `test_<이름>.gd`를 요구한다). `TickLoop` 스냅샷 연결은 SE-011(스펙)·SE-012(구현) |
| 데이터 | [`project/data/economy/economy.json`](../../project/data/economy/economy.json) (version 1), 스키마 [`economy.schema.json`](../../project/data/schemas/economy.schema.json). 읽기 참조: [`tiers.json`](../../project/data/tiers/tiers.json) `unlock_cash`, [`sim.json`](../../project/data/sim/sim.json) 구간·`rng_streams`·`system_order` |
| 이벤트 | [events.md](events.md)의 `economy.*` 행 전부. 이 문서에 나오는 이벤트 이름은 전부 거기 표에 있다 |
| 근거 | PRD "핵심 시스템 상세"(경제 행), "성장 티어"(해금 자금, "티어 2까지 약 2시간"), "기술 요구사항"(배치 규칙 "철거 환불 70%"), "결정이 필요한 질문"(파산 = 게임 오버, 구제 N회는 밸런스 시트), [tick.md](tick.md) |

## 목적

티어 1 의 돈 흐름을 공식 하나로 고정한다. 현금(`cash`)은 economy 시스템만 바꾸고, 다른 시스템은 이벤트로 지출·환불·매출을 **제안·보고**만 한다.
하루에 한 번, close 구간 진입 틱에 정산하고, 정산 뒤 현금이 음수면 구제(긴급 대출)를 제안하며, 구제를 다 쓴 뒤 다시 음수면 파산(게임 오버)이다.
모든 금액은 정수이고 경제 v0 는 난수를 쓰지 않는다. 이 문서와 `economy.json`만 보고 구현 티켓이 `economy.gd`·`economy_config.gd`와 짝 테스트(`test_economy.gd`·`test_economy_config.gd`)를 질문 없이 쓸 수 있어야 한다.

v0 범위: 수익 2종(티켓, 바), 비용 4종(개런티, 임대료, 유지비, 세금), 즉시 반영 3종(건설비, 철거 환불, 개런티 선지급), 하루 1회 정산, 파산·구제, 시작 자금, 티켓 가격 변경.
범위 밖: 음식·굿즈·스폰서·중계권(티어 2+), 인건비(`staff.md`), 개런티 동적 공식·발굴 할인(`artist.md`), 관객 수 결정(`audience.md` — v0 는 입력), 명성·티어 해금 판정(`reputation.md`), 게임 오버 화면·흐름(후속 UI 티켓).

PRD 결정(파산 = 게임 오버, 구제 횟수는 밸런스 시트 값, 해금 자금 3만/20만/100만/500만/3,000만, 철거 환불 70%)은 바꾸지 않는다.

## 규칙

### 단위와 반올림

| # | 규칙 |
|---|---|
| R1 | 모든 금액은 `int`(게임 화폐 1 단위). 경제 상태와 이벤트 페이로드에 `float` 금액은 없다 |
| R2 | 비율은 `rate_scale`(= 10,000) 분의 정수로 적는다(필드 이름 `*_bp`). 예: `tax_rate_bp` 1,000 = 10%. 비율 필드는 `float`이 아니다(플랫폼 간 부동소수 차이 제거) |
| R3 | 비율 곱은 `⌊x × bp ÷ rate_scale⌋`, 정수 나눗셈(내림). 이 연산의 `x`는 항상 0 이상이다(세금은 `max(0, …)` 뒤에 적용). GDScript `int / int`는 0 쪽 버림이라 `x ≥ 0`에서 내림과 같다 |
| R4 | 내림은 아래 공식에 `⌊ ⌋`로 표시한 단계에서만, 그 단계마다 한 번. 합·차는 정수 그대로 계산한다(중간 반올림 없음) |
| R5 | 몫으로 나눠 갚는 금액(대출 회차)은 `q = total ÷ n`, `r = total mod n`이고 앞의 `r`회차가 `q + 1`, 나머지가 `q`. 회차 합 = `total` 정확히 |
| R6 | 범위: 티어 1 금액은 10^7 미만, 곱 `x × bp`는 10^11 미만이라 int64 안이다 |

### 상태

Economy 가 소유하는 상태. 전부 기본형이며 스냅샷 대상이다(#스냅샷).

| 필드 | 타입 | 새 게임 값 | 설명 |
|---|---|---|---|
| `cash` | int | `starting_cash` | 현금. 음수는 "정산 직후 ~ 구제 수락 전"과 파산 뒤에만 |
| `tier` | int | 1 | 쓰는 경제 행(`rows[].tier`). 티어 변경은 reputation 후속 티켓 |
| `day` | int | 1 | `time.phase_changed.day` / `time.day_started.day`를 따라온 현재 날 |
| `phase` | String | `"day"` | `time.phase_changed.to`를 따라온 현재 구간 |
| `ticket_price` | int | 행의 `ticket_price_default` | 현재 티켓 가격. 날을 넘어 유지 |
| `upkeep_per_day` | int | 0 | 마지막 `economy.upkeep_reported.total` |
| `ledger` | Dictionary | `{admissions: 0, audience: 0, guarantee: 0}` | 현재 회계일 누적. `guarantee`는 회계일 안에서 승인된 `operating` 지출(사유 `guarantee`)의 합. 키는 고정 이름으로만 접근(순회 금지) |
| `last_settled_day` | int | 0 | 마지막으로 정산한 날 |
| `bailouts_left` | int | `bailout_count` | 남은 구제 횟수 |
| `pending_bailout` | Dictionary 또는 `null` | `null` | 제안 중인 구제 조건 `{day, kind, deficit, amount, interest, total_due, repay_days, installments}` |
| `loans` | Array | `[]` | 상환 중인 대출, 받은 순서. 원소 `{day_taken, amount, total_due, installments: Array[int], paid: int}`. `day_taken`은 **제안일**(`pending_bailout.day`)이다. 수락 경로(수동·자동)와 무관하게 같은 값이고, 상환 시점 판정에는 쓰지 않는다(기록·표시용, S13) |
| `bankrupt` | bool | false | 파산(게임 오버) 여부 |

**회계일.** 회계일 `d` = 직전 정산 직후부터 `d`일 정산까지. 새 게임은 1회계일의 시작이다. close 에서 정산 뒤에 일어난 지출·매출은 다음 회계일에 들어간다.

### 입력 계약

economy 는 다른 시스템을 직접 호출하지 않고(CLAUDE.md 원칙 4) 아래 이벤트만 받는다. 발행 주체(build, artist, audience/show)는 아직 없으므로 v0 테스트가 직접 발행한다. build.md·artist.md·audience.md 는 이 계약을 그대로 쓴다.

| 이벤트 | 종류 | 발행 주체(후속) | economy 동작 |
|---|---|---|---|
| `economy.charge_proposed {request_id, reason, amount}` | 상태 | build(설치), artist(섭외) | 지출 판정 C1~C4 (#즉시-반영-항목과-정산-반영-항목) |
| `economy.refund_proposed {request_id, reason, base_amount}` | 상태 | build(철거) | 환불 F1~F3 |
| `economy.sales_reported {admissions, audience}` | 상태 | audience/show | `ledger` 누적 |
| `economy.upkeep_reported {total}` | 상태 | build(설치 목록이 바뀔 때마다) | `upkeep_per_day` 교체 |
| `economy.ticket_price_requested {price}` | 명령 | ui | #티켓-가격 |
| `economy.bailout_accept_requested {}` | 명령 | ui, 봇 | #파산과-구제 수락 |
| `time.phase_changed` | 상태 | TickLoop | `phase`, `day` 갱신. `to == "close"`면 정산. `to`가 `sim.json` `phases[].id`가 아니면 `push_error` 1회 후 무시(`day`·`phase` 불변, 정산 없음, SE-044) |
| `time.day_started` | 상태 | TickLoop | `day` 갱신. 제안 중인 구제 자동 수락 |

- 명령 입력(`economy.ticket_price_requested`, `economy.bailout_accept_requested`)의 숫자는 `int`만이다(tick.md E4). `float`는 정수값이어도 버스가 `publish()`에서 거부(`push_error` + `false`, 큐잉 안 함)하므로 economy 핸들러에 오지 않는다. 핸들러는 `int`가 아닌 값(키 없음·문자열·`bool`·`null`)만 각 표의 무효 행(P1)으로 처리한다.
- 상태 입력(`economy.charge_proposed`·`economy.refund_proposed`·`economy.sales_reported`·`economy.upkeep_reported`)은 E4 상 버스가 `float`를 막지 않는다. 발행 주체는 R1 에 따라 `int`를 싣는다. economy 는 방어적으로 정수 필드에 `int` 또는 정수값인 `float`를 받아 `int()`로 정규화하고, 그 밖은 각 표의 무효 행(C2, F2 등)이다. 이 입력은 즉시 전달되어 스냅샷에 남지 않으므로 이 정규화는 세이브 동치에 영향이 없다.
- economy 는 `system_order`에서 crisis 뒤, reputation 앞에 구독한다(tick.md "시스템 등록").
- 정산 결과가 필요한 시스템은 `cash`를 읽지 않고 `economy.day_settled`를 구독한다. 티어 해금 자금 판정은 reputation.md 가 `economy.day_settled.cash`(정산 뒤·구제 전 값)를 구독해서 한다. 이 이벤트는 E2 로 큐에 들어가 `time.phase_changed {to:"close"}`의 모든 구독자가 끝난 뒤 전달되므로 판정 결과는 구독 순서에 의존하지 않는다.

**같은 경계 안의 핸드셰이크.** build 가 설치 명령을 처리하며 `economy.charge_proposed`를 발행 → (tick.md E2, FIFO) economy 가 판정하고 `economy.charge_resolved`를 발행 → build 가 `approved`를 보고 설치를 확정(`build.placed`)하거나 `build.rejected {reason:"insufficient_cash"}`를 낸다.
명령 하나의 연쇄는 다음 명령보다 먼저 끝나므로(tick.md E5) 같은 경계의 두 번째 설치 명령은 갱신된 `cash`로 판정된다. 다른 시스템은 `cash`를 직접 읽지 않는다.
`request_id`는 제안한 시스템이 정하는 문자열이고(예: `"build:<tick>:<seq>"`) economy 는 그대로 돌려줄 뿐 유일성을 검사하지 않는다.

### 수익: 티켓

| 입력 | 출력 | 공식 |
|---|---|---|
| `ledger.admissions`(회계일 유료 입장 수 합), `ticket_price`(정산 시점) | `ticket_revenue` | `ticket_revenue = ticket_price × ledger.admissions` |

- 입장 수는 v0 입력(`economy.sales_reported.admissions`)이다. 입장 수를 정하는 공식은 audience.md.
- 가격은 낮 구간에서만 바뀌므로(#티켓-가격) 저녁·공연 입장분은 모두 같은 가격이다. 정산 시점 가격을 쓴다.
- 반영: 정산. 입장 시점에는 현금이 바뀌지 않는다.

### 수익: 바

| 입력 | 출력 | 공식 |
|---|---|---|
| `ledger.audience`, 행의 `bar_purchase_rate_bp`, `bar_avg_spend`, `bar_cost_rate_bp` | `bar_buyers`, `bar_revenue`, `bar_cost` | `bar_buyers = ⌊ledger.audience × bar_purchase_rate_bp ÷ rate_scale⌋`<br>`bar_revenue = bar_buyers × bar_avg_spend`<br>`bar_cost = ⌊bar_revenue × bar_cost_rate_bp ÷ rate_scale⌋` |

- `audience`는 관람 인원(v0 입력, 초대 관객이 없으면 `admissions`와 같다).
- `bar_cost`(원가)는 영업 비용이다(세전 순이익에서 뺀다). 바 대기열·서비스 반경에 따른 구매 변화는 audience.md/build.md 가 정하며, 그때 이 공식의 입력을 바꾸는 스키마 변경 티켓을 낸다.
- 반영: 정산.

### 비용: 개런티

| 입력 | 출력 | 공식 |
|---|---|---|
| 섭외 확정 시 `economy.charge_proposed {reason:"guarantee", amount}` | 즉시 `cash -= amount`, `ledger.guarantee += amount` | v0 `amount = guarantee_by_grade[grade]` (artist 가 테이블에서 읽어 넣는다). v0 등급: `local`(로컬), `rookie`(신인) |

- 선지급이라 즉시 반영이다. `charge_reasons.guarantee == "operating"`이므로 그 회계일 손익의 비용으로 잡히지만, 정산 때 현금을 다시 빼지 않는다.
- 동적 개런티(인기·관계·발굴 할인)는 artist.md 가 정하고, 그때 `guarantee_by_grade`는 artist 데이터로 옮긴다. 노쇼·취소 환불은 events_crisis.md(v0 없음).

### 비용: 임대료

| 입력 | 출력 | 공식 |
|---|---|---|
| 현재 `tier`의 행 | `rent` | `rent = rent_per_day`. 정산마다 1회, 공연 유무와 무관 |

### 비용: 유지비

| 입력 | 출력 | 공식 |
|---|---|---|
| `upkeep_per_day`(정산 시점 상태) | `upkeep` | `upkeep = upkeep_per_day` |

- `upkeep_per_day`는 build 가 보내는 설치 가구 유지비 합 `Σ furniture[f].upkeep_per_day`(설치된 인스턴스마다)다. 가구 테이블 필드 이름 **`upkeep_per_day`**(int ≥ 0, 1일 유지비)를 여기서 예약한다. 값과 스키마는 furniture 티켓.
- 일할 계산은 없다. 정산 시점에 설치되어 있으면 하루치 전액, 없으면 0. 정산 직전 철거·다음 날 재설치는 건설비의 30%(환불 70% 의 나머지)를 잃으므로 furniture 티켓은 모든 가구에서 `⌊build_cost × (rate_scale − demolish_refund_rate_bp) ÷ rate_scale⌋ > upkeep_per_day`를 지킨다(가구 건설비 필드 이름 `build_cost` 제안).

### 비용: 세금

| 입력 | 출력 | 공식 |
|---|---|---|
| `pretax`(정산 S10), 행의 `tax_rate_bp` | `tax` | `tax = ⌊max(0, pretax) × tax_rate_bp ÷ rate_scale⌋` |

- 손실일 세금은 0, 손실 이월은 없다(v0). `tax_rate_bp == 0`이면 항상 0.

### 즉시 반영 항목과 정산 반영 항목

| 항목 | 반영 시점 | 세전 순이익(`pretax`)에 포함 | 이벤트 `reason` |
|---|---|---|---|
| 건설비 (`charge_proposed`, `reason:"build"`) | 즉시 | 아니오 (`capital`) | `"build"` |
| 철거 환불 (`refund_proposed`, `reason:"demolish"`) | 즉시 | 아니오 | `"demolish_refund"` |
| 개런티 선지급 (`charge_proposed`, `reason:"guarantee"`) | 즉시 | 예 (`operating`) | `"guarantee"` |
| 티켓 매출, 바 매출, 바 원가, 임대료, 유지비, 세금 | 정산 | 예(세금은 결과) | `"settlement"` |
| 대출 상환 | 정산 | 아니오(재무) | `"settlement"`에 합산 |
| 구제 대출 수령 | 수락 시 | 아니오(재무) | `"bailout"` |

**지출 판정** `economy.charge_proposed {request_id: String, reason: String, amount: int}`. 위에서부터 처음 맞는 행 하나만 적용한다.

| # | 조건 | 결과 |
|---|---|---|
| C1 | `bankrupt` | 거절 `decline_reason: "bankrupt"` |
| C2 | `reason`이 `charge_reasons`의 키가 아님, 또는 `amount`가 정수가 아님, 또는 `amount < 0` | 거절 `"invalid"` |
| C3 | `cash < amount` | 거절 `"insufficient_cash"` |
| C4 | 그 밖 | 승인. `cash -= amount`. `charge_reasons[reason] == "operating"`이면 `ledger[reason] += amount`. K5 때문에 v0 에서 이 분기에 들어오는 사유는 `guarantee` 하나다(아래 "회계 분류와 장부 키") |

이벤트(상태를 먼저 갱신, tick.md E8): 승인이고 `amount > 0`이면 `economy.cash_changed {cash, delta: −amount, reason}` → 항상 `economy.charge_resolved {request_id, reason, amount, approved, decline_reason, cash}`.
`decline_reason`은 승인이면 `""`, `cash`는 처리 뒤 값. C2 에서 `request_id`·`reason`이 문자열이 아니면 `""`, `amount`가 정수가 아니면 0 을 싣는다.
C3 때문에 즉시 지출로는 `cash`가 음수가 되지 않는다. 음수는 정산에서만 생긴다.

**회계 분류와 장부 키 (SE-012 결정).** `ledger`의 키는 #상태 표의 세 개(`admissions`, `audience`, `guarantee`)로 고정이다. `operating` 지출을 담는 키는 `guarantee` 하나뿐이고, S8 이 그 키를 읽는다.
- `charge_reasons`에서 값이 `operating`인 사유는 `ledger`에 같은 이름의 키가 있는 사유뿐이다(v0: `guarantee`). `EconomyConfig`가 로드 때 이것을 K5 로 검사한다. 스키마는 `build: operating`을 허용하지만 K5 에서 `null`이 된다. K4 처럼 스키마 enum 은 넓게 두고 v0 가 지원하는 조합은 교차 검사로 좁힌다.
- `capital`은 어느 사유든 허용한다. `guarantee: capital`이면 개런티는 C4 에서 현금만 빠지고 `ledger.guarantee`·S8 은 0 이다. 개런티를 손익 밖으로 빼는 데이터 결정이라 `reference_scenarios` 기대값도 같이 고쳐야 한다.
- 방어 경로: K5 를 통과한 설정으로는 C4 에서 `ledger`에 키가 없는 `operating` 사유가 나올 수 없다. 그래도 나오면 지출은 C4 대로 승인되고(`cash` 차감, 이벤트 정상), `push_error` 1회를 내고, `ledger`는 바뀌지 않는다. 그 금액은 S8 에 들어가지 않는다.
- 새 `operating` 사유(예: 후속 인건비 선지급)를 더하려면 한 번의 스펙 개정에서 함께 바꾼다: `economy.schema.json` `charge_reasons` 속성 추가(스키마 version 올림), `ledger` 키 추가, S8·S9 와 `economy.day_settled` 페이로드 키 추가(events.md), K5 대상 목록. `ledger`를 `charge_reasons` 키로 만드는 일반화는 하지 않는다. `ledger`는 고정 키로만 접근한다(#결정성과-rng, Dictionary 순회 없음).

**환불** `economy.refund_proposed {request_id: String, reason: String, base_amount: int}`.

| # | 조건 | 결과 |
|---|---|---|
| F1 | `bankrupt` | 무시(상태 불변, 이벤트 없음) |
| F2 | `reason != "demolish"`, 또는 `base_amount`가 정수가 아님, 또는 `< 0` | `push_warning`, 무시 |
| F3 | 그 밖 | `refund = ⌊base_amount × demolish_refund_rate_bp ÷ rate_scale⌋`, `cash += refund`. `refund > 0`이면 `economy.cash_changed {cash, delta: refund, reason: "demolish_refund"}` |

`base_amount`는 그 가구를 설치할 때 승인된 `build` 지출 금액이다(build 가 인스턴스마다 기억한다). 예: 1,000 → 700, 999 → ⌊699.3⌋ = 699, 1 → 0(이벤트 없음).

**매출 보고** `economy.sales_reported {admissions: int, audience: int}`: `bankrupt`면 무시. 둘 다 정수 ≥ 0 이면 `ledger.admissions += admissions`, `ledger.audience += audience`, 아니면 `push_warning` 후 무시. 이벤트 없음. 한 회계일에 여러 번 보내도 된다(합산).

**유지비 보고** `economy.upkeep_reported {total: int}`: `bankrupt`면 무시. 정수 ≥ 0 이면 `upkeep_per_day = total`(누적 아님, 교체), 아니면 `push_warning` 후 무시. 이벤트 없음.

### 정산

**시점.** `time.phase_changed {to: "close"}` 구독 핸들러 = tick.md "한 틱의 순서" 단계 4, close 진입 틱에 1회, 틱 경계 안이다. 정산 이벤트는 그 틱의 `tick.advanced`보다 먼저 끝나고, 오토세이브(close 진입 경계)에 정산 결과가 들어간다.

**1회성.** `bankrupt`이거나 `last_settled_day == payload.day`이면 아무것도 하지 않는다(중복 이벤트·복원 방어). 이때 `pending_bailout`도 그대로 둔다.

**S0 (미수락 구제 정리, SE-012 결정).** 1회성 검사를 통과했는데 `pending_bailout != null`이면 S1 전에 `push_warning` 1회를 내고 #파산과-구제의 수락 동작을 `auto: true`로 실행한다. 이 경우는 `time.day_started` 없이 다음 close 가 온 것이고, 시간 이벤트 계약 위반이다. `TickLoop` 경로에서는 생기지 않는다(다음 날 전환은 항상 `time.day_started`를 먼저 낸다). 테스트가 `time.*`을 직접 발행할 때만 생긴다.
결과는 빠진 `time.day_started`가 왔을 때와 같다. 그 대출의 첫 회차는 이번 정산 S13 에서 나간다. 그래서 B2 가 `pending_bailout`을 덮어쓰는 일은 없다(B2 시점에는 항상 `null`).

**공식.** 행은 현재 `tier`의 행. 순서대로 계산한다.

| 단계 | 값 | 공식 |
|---|---|---|
| S1 | `ticket_revenue` | `ticket_price × ledger.admissions` |
| S2 | `bar_buyers` | `⌊ledger.audience × bar_purchase_rate_bp ÷ rate_scale⌋` |
| S3 | `bar_revenue` | `bar_buyers × bar_avg_spend` |
| S4 | `bar_cost` | `⌊bar_revenue × bar_cost_rate_bp ÷ rate_scale⌋` |
| S5 | `revenue` | `ticket_revenue + bar_revenue` |
| S6 | `rent` | `rent_per_day` |
| S7 | `upkeep` | `upkeep_per_day`(상태) |
| S8 | `guarantee` | `ledger.guarantee`(이미 지불한 금액, 손익 계산용) |
| S9 | `operating_costs` | `bar_cost + rent + upkeep + guarantee` |
| S10 | `pretax` | `revenue − operating_costs` |
| S11 | `tax` | `⌊max(0, pretax) × tax_rate_bp ÷ rate_scale⌋` |
| S12 | `net` | `pretax − tax` (세후 순이익) |
| S13 | `loan_repayment` | `loans`를 배열 순서로 돌며 각 대출의 `installments[paid]`를 더하고 `paid += 1`. `paid == installments.size()`가 된 대출은 제거 |
| S14 | `settlement_delta` | `revenue − bar_cost − rent − upkeep − tax − loan_repayment` (= `net + guarantee − loan_repayment`) |
| S15 | `cash` | `cash + settlement_delta` |
| S16 | 장부 | `last_settled_day = day`, `ledger`의 세 값 0 |
| S17 | 파산 판정 | #파산과-구제 B1~B3 |

한 회계일의 현금 변화 = −(즉시 지출 합) + (환불 합) + `settlement_delta` (+ 구제 원금). 건설·환불·대출이 없으면 정확히 `net`이다.

**이벤트.** S1~S17 상태를 먼저 전부 갱신한 뒤 이 순서로 발행한다.

1. `settlement_delta ≠ 0`이면 `economy.cash_changed {cash, delta: settlement_delta, reason: "settlement"}`
2. `economy.day_settled {day, ticket_price, admissions, audience, ticket_revenue, bar_buyers, bar_revenue, bar_cost, revenue, rent, upkeep, guarantee, operating_costs, pretax, tax, net, loan_repayment, settlement_delta, cash}` — 항상. 값은 전부 int, `admissions`·`audience`는 정산에 쓴 `ledger` 값, `cash`는 S15 값(구제 전)
3. B2 면 `economy.bailout_offered`, B3 면 `economy.bankrupt`

이 연쇄는 최외곽 `time.phase_changed` 발행 안에서 끝나므로(tick.md E2·E3) 같은 틱의 `time.speed_changed {speed: 0}`과 `tick.advanced`보다 먼저 전달된다.

**틱 업데이트·등록.** v0 경제는 틱마다 할 일이 없지만 `TickLoop`에 `system_order`의 `"economy"`로 **반드시** 등록한다: `loop.register_system("economy", economy.update, economy.snapshot, economy.restore)`. `update(ctx)`는 no-op 이다.
등록하는 이유는 스냅샷 훅이다. 등록하지 않으면 경제 상태가 `TickLoop.snapshot()`에 들어가지 않아 세이브·복원에서 사라진다(#스냅샷, tick.md #명령-큐와-틱-순서 "시스템 등록", SE-011).
등록은 `Economy` 생성(=구독) 직후, 첫 `advance`/`step`/`restore` 전에 구동기(테스트, 후속 부트스트랩)가 한다. 경제 상태는 이벤트 핸들러와 `restore`에서만 바뀐다.

### 파산과 구제

정산 S15 뒤에 판정한다.

| # | 조건 | 결과 |
|---|---|---|
| B1 | `cash ≥ 0` | 끝 |
| B2 | `cash < 0`, `bailouts_left > 0` | 구제 제안: `pending_bailout` 설정 → `economy.bailout_offered`. 이 시점의 `pending_bailout`은 항상 `null`이다(S0) |
| B3 | `cash < 0`, `bailouts_left == 0` | 파산: `bankrupt = true` → `economy.bankrupt {day, cash, bailouts_used}` (`bailouts_used = bailout_count − bailouts_left`). **게임 오버** |

**구제 = 긴급 대출** (v0 의 유일한 종류, `kind: "loan"`. 스폰서 구제는 Q2). 조건은 제안 시점에 확정해 `pending_bailout`에 저장한다.

| 값 | 공식 |
|---|---|
| `deficit` | `−cash` (> 0) |
| `amount`(원금) | `deficit + bailout_loan_amount`. 받으면 `cash`가 정확히 `bailout_loan_amount`가 된다 |
| `interest` | `⌊amount × bailout_interest_bp ÷ rate_scale⌋` (원금에 1회 부과하는 단리) |
| `total_due` | `amount + interest` |
| `repay_days` | `bailout_repay_days` |
| `installments` | R5: `q = total_due ÷ repay_days`, `r = total_due mod repay_days`, 회차 `k = 1..repay_days`의 금액은 `k ≤ r`이면 `q + 1`, 아니면 `q` |

`economy.bailout_offered {day, kind, deficit, amount, interest, total_due, repay_days, first_installment, bailouts_left_after}` — `first_installment = installments[0]`, `bailouts_left_after = bailouts_left − 1`.

**수락.** 아래 둘 중 먼저 오는 것.

- `economy.bailout_accept_requested {}` 명령(close 에서 UI·봇이 보냄, 다음 경계 처리에서 적용, `auto: false`).
- `time.day_started` 수신(플레이어가 수락하지 않고 다음 날로 넘어감, `auto: true`). v0 에서 구제는 거절할 수 없다(Q5).
- (계약 위반 방어) `time.day_started` 없이 다음 정산이 시작됨 → #정산 S0 에서 `push_warning` 1회 후 `auto: true`로 수락. 이벤트는 `economy.cash_changed {reason:"bailout"} → economy.bailout_taken {auto:true}` 다음에 그 정산의 이벤트가 나온다.

수락 동작: `cash += amount`, `bailouts_left −= 1`, `loans.append({day_taken: pending_bailout.day, amount, total_due, installments, paid: 0})`, `pending_bailout = null` → `economy.cash_changed {cash, delta: amount, reason: "bailout"}` → `economy.bailout_taken {day, kind, amount, total_due, repay_days, bailouts_left, cash, auto}`.
`day_taken`과 `economy.bailout_taken.day`는 둘 다 **제안일**(`pending_bailout.day`)이다. 현재 `day`를 쓰지 않는다. 자동 수락은 `time.day_started` 핸들러에서 `day`를 갱신한 뒤 일어나서, 현재 `day`를 쓰면 수동 수락과 값이 하루 달라지기 때문이다.
`pending_bailout == null`일 때 받은 수락 명령은 무시한다(상태 불변, 이벤트 없음).
첫 회차는 **수락 뒤 첫 정산(S13)**에서 나가고, 그 뒤 정산마다 1회차씩 나간다. S13 은 날짜를 보지 않고 `loans`의 모든 대출에서 `installments[paid]`를 뺀다. 그래서 상환 시점을 `day_taken`과 비교하는 조건(예: "`day > day_taken`일 때만")을 넣지 않는다.
예: 8일 close 에서 제안된 구제는 수동 수락(8일 close)이든 자동 수락(9일 `time.day_started`)이든 9일 정산에서 첫 회차가 나간다. 두 경로 사이에 현금을 바꾸는 입력이 없으면 9일 정산 뒤 `cash`도 같다.
자동 수락의 이벤트 순서는 tick.md E2 FIFO 에 따라 `time.day_started → time.phase_changed {close→day} → time.speed_changed → economy.cash_changed → economy.bailout_taken`이다.

**파산 뒤.** `bankrupt == true`면 economy 는 **경제 입력**을 무시한다. 지출은 C1 거절, 환불·매출·유지비 보고 무시, 정산 없음(S0 포함), 티켓 가격은 P2 `not_allowed`, 구제 없음(제안·수동 수락·자동 수락 전부). `economy.bankrupt`는 게임당 정확히 1회다.
**`day`·`phase` 추적은 유지한다(SE-016).** `time.day_started`·`time.phase_changed`를 받으면 파산 전과 같은 페이로드 검사(잘못되면 `push_warning` 후 무시)를 하고 `day`·`phase`만 갱신한 뒤 끝낸다. `time.phase_changed`의 `to`가 `sim.json` `phases[].id`가 아니면 파산 전과 같이 `push_error` 1회 후 무시한다(`day`·`phase` 불변, SE-044). #상태 표의 정의("따라온 현재 날/구간")가 파산 뒤에도 그대로 성립하고, 게임 오버 UI 와 `economy.ticket_price_rejected.phase`가 현재 구간을 본다. close 진입이어도 정산·S0 을 하지 않고, `time.day_started`여도 자동 수락을 하지 않는다(파산 시점의 `pending_bailout`은 S0 뒤라 항상 `null`이다). `day`·`phase` 밖의 상태(`cash`, `ledger`, `last_settled_day`, `loans`, `pending_bailout`, `bailouts_left`, `ticket_price`, `upkeep_per_day`)는 바뀌지 않고, 이 경로는 이벤트를 내지 않는다.
게임 오버 화면, TickLoop 정지, 세이브 처리는 후속 UI·게임 흐름 티켓 몫이다. economy 는 TickLoop 을 멈추지 않는다.

### 시작 자금

| 입력 | 출력 | 공식 |
|---|---|---|
| `starting_cash`, `bailout_count`, `rows[tier_1]` | 새 게임 경제 상태 | `cash = starting_cash`, `tier = 1`, `ticket_price = ticket_price_default`, `bailouts_left = bailout_count`, 나머지는 #상태 "새 게임 값" 열 |

- `Economy` 생성자는 이벤트를 내지 않는다(tick.md 와 같은 규칙). UI 의 첫 표시는 `Economy`의 읽기 전용 `cash`를 읽는다(상태를 바꾸지 않는 읽기).
- 시작 자금은 새 게임에만 쓴다. 티어가 올라가도 현금은 그대로 이월된다.

### 티켓 가격

`economy.ticket_price_requested {price}` (명령, 경계 처리에서 적용). 위에서부터 처음 맞는 행.

| # | 조건 | 결과 |
|---|---|---|
| P1 | `price`가 없거나 `int`가 아님(문자열·`bool`·`null` 등). `float`는 정수값(`25.0`)이어도 버스가 먼저 거부하므로(tick.md E4, `publish()` `false`) 이 표에 오지 않는다 | `economy.ticket_price_rejected {price, reason: "invalid", phase}` (`price`는 받은 값, 없으면 `null`) |
| P2 | `bankrupt`, 또는 `phase != "day"` | 거절 `reason: "not_allowed"` |
| P3 | `price < ticket_price_min` 또는 `price > ticket_price_max` | 거절 `reason: "out_of_range"` |
| P4 | `price == ticket_price` | 무시(이벤트 없음) |
| P5 | 그 밖 | `ticket_price = price` → `economy.ticket_price_changed {price, from}` |

가격은 다음 날 이후에도 유지된다. v0 에서 가격은 `ticket_revenue`에만 영향을 준다. 가격에 따른 입장 수 변화는 audience.md(Q4).

### 결정성과 RNG

- 경제 v0 는 **난수를 쓰지 않는다.** `economy` 스트림을 한 번도 뽑지 않는다(`rng.get_state()["economy"]`가 정산 전후로 같다).
- 공식은 정수 연산뿐이고, 순회는 `loans` 배열(받은 순서) 하나뿐이다. `ledger`는 고정 키로만 접근한다(Dictionary 순회 없음).
- 입력이 같으면(같은 시드, 같은 명령 열, 같은 입력 이벤트 열) 같은 경제 상태와 같은 `economy.*` 이벤트 열이 나온다.
- 후속에서 난수가 필요해지면(예: 바 매출 변동) 스트림은 `economy`만, 호출 지점은 정산 핸들러(단계 4) 또는 economy `update`(단계 2)만 쓰고, 공식과 한 번 정산당 뽑는 횟수를 이 문서에 먼저 적는다.

### 스냅샷

`Economy.snapshot() -> Dictionary`는 #상태 표의 필드 전부(기본형, JSON 왕복 가능)를 담는다.
`Economy.restore(d: Dictionary) -> bool`은 숫자 필드를 `int()`로 정규화(`loans[].installments` 포함)하고, 필드가 빠졌거나 타입이 틀리면 `push_error` 1회, `false`, 상태 불변이다. 이벤트를 내지 않는다. 타입 검사에는 `phase`가 빈 문자열이 아닌 문자열, `bankrupt`가 `bool`, `pending_bailout`이 `null` 또는 객체, `installments`가 비어 있지 않은 정수 배열인지가 들어간다.
**범위 검사(SE-015).** 필드 누락·타입 외에 다음 범위도 검사한다. 위반이면 타입 오류와 같은 처리다(`push_error` 1회, `false`, 상태 불변, 이벤트 0): ① `tier` 행 존재(`EconomyConfig.has_row(tier)`, 즉 `rows[tier_N]`), ② `day ≥ 1`, ③ `upkeep_per_day`·`last_settled_day`·`bailouts_left`·`ticket_price ≥ 0`, ④ `ledger.*`(고정 3키) 전부 ≥ 0, ⑤ `pending_bailout`이 있으면 `installments` 개수 == `repay_days`, ⑥ `loans[]`마다 `0 ≤ paid < installments` 개수.
검사는 전부 적용 전에 끝난다(tick.md SH3 "`d`를 전부 검사한 뒤 적용"). 첫 위반에서 멈추므로 위반이 여러 개여도 `push_error`는 1회다. ⑥은 손으로 고친 세이브가 S13 `installments[paid]`에서 범위 밖 인덱스로 실패하는 것을 막는다. 그 밖의 의미 검사(`cash` 부호, `installments` 합 == `total_due`, `pending_bailout` 금액 필드 사이 관계, `ticket_price`가 행의 min~max 안인지)는 하지 않는다. `cash < 0`은 정상 상태(#상태 `cash`)이고, 나머지는 위반해도 크래시 없이 진행되기 때문이다.
복원 후 진행 = 연속 진행: 같은 입력 열을 주면 경제 상태 해시(`JSON.stringify(snapshot(), "", true)`)가 같다.
**`TickLoop` 연결(SE-011 결정, Q7).** economy 는 위 "틱 업데이트·등록"으로 훅을 준다. 그래서 `TickLoop.snapshot()["systems"]["economy"]`가 `Economy.snapshot()`과 같은 값(깊은 복사본)이다. 최상위 `economy` 키는 만들지 않는다.
`TickLoop.restore(s)`는 `s.systems.economy`를 `Economy.restore()`에 넘긴다(tick.md #스냅샷 restore 5~7단계). `systems`에 `economy` 항목이 없으면 `TickLoop.restore()`가 실패한다. 경제 복원이 실패하면 먼저 복원한 시스템이 롤백된다. 어느 경우든 시간·RNG·명령 큐도 바뀌지 않는다.
`Economy`의 두 메서드는 tick.md 훅 규약 SH1~SH7 을 지킨다. `snapshot()`은 상태를 바꾸지 않는다. `restore(d)`는 실패하면 상태 불변이고, 자기 스냅샷(JSON 왕복 포함)은 항상 받아들인다. 둘 다 이벤트를 내지 않고 난수를 쓰지 않는다.
`sim.json.snapshot_schema_version`은 2(최상위 10개 키 형식)이고, `sim.json` version 3 과 함께 적용됨(SE-012). 경제 항목 형식을 바꾸면 tick.md 변경 이력에 한 줄을 남긴다(tick.md Q7).

### 설정 로드와 공개 API

`EconomyConfig.load(path := "res://data/economy/economy.json") -> EconomyConfig`(테스트 사본은 `from_dict(d)`, 같은 검사). 스키마로 못 하는 교차 검사 K1~K5 를 하고, 실패하면 `push_error`, `null`.

| # | 검사 |
|---|---|
| K1 | `rows[].id == "tier_" + str(rows[].tier)`, `tier` 중복 없음, `tier == 1` 행이 있음 |
| K2 | 행마다 `ticket_price_min ≤ ticket_price_default ≤ ticket_price_max` |
| K3 | `version == 1`, `rate_scale == 10000` |
| K4 | 모든 `reference_scenarios[].guarantee_grade`가 `guarantee_by_grade`의 키다. 스키마 enum(5종)은 artist.md 가 쓸 등급 이름의 목록이다. 그래서 v0 테이블에 값이 없는 등급(`midlevel` 등)도 스키마는 통과하고, 이 검사가 그런 등급을 막는다 |
| K5 | `charge_reasons`에서 값이 `"operating"`인 사유가 모두 `ledger` 키 이름이다(v0: `guarantee`만). `build: operating`처럼 스키마는 통과하지만 v0 장부에 자리가 없는 조합을 막는다(#즉시-반영-항목과-정산-반영-항목 "회계 분류와 장부 키"). `capital`은 제한하지 않는다 |

| 클래스 | 멤버 | 설명 |
|---|---|---|
| `EconomyConfig` | `row(tier: int) -> Dictionary`, `guarantee(grade: String) -> int`, `starting_cash`, `bailout_count`, `rate_scale`, `demolish_refund_rate_bp`, `charge_reasons`, `reference_scenarios` | 읽기 전용. `guarantee(grade)`는 `guarantee_by_grade`에 있는 키면 그 값(int ≥ 0)을 돌려준다. 없는 키(v0 의 `midlevel`·`headliner`·`legend`, 오타 포함)면 `push_error` 후 **`-1`**을 돌려준다. `-1`을 그대로 `charge_proposed.amount`에 넣으면 C2(`amount < 0`)로 거절(`"invalid"`)되므로 현금은 바뀌지 않는다. `row(tier)`는 없는 티어면 `push_error`, `{}` |
| | `has_row(tier: int) -> bool` | 그 티어의 경제 행이 있으면 `true`. 오류를 내지 않는다(`row()`와 달리 `push_error` 없음). #스냅샷 범위 검사 ①이 쓴다 |
| | `scenario(id: String) -> Dictionary` | `reference_scenarios`에서 `id`가 같은 시나리오의 깊은 복사본. 없는 `id`면 `{}`(**`push_error` 없음**). 테스트·qa 용 |
| | (`static as_int` 없음) | SE-044 에서 core `JsonUtil.as_int`로 옮겼다(이 표 마지막 행) |
| | 상수 `START_TIER`(1), `LEDGER_ADMISSIONS`(`"admissions"`)·`LEDGER_AUDIENCE`(`"audience"`)·`LEDGER_GUARANTEE`(`"guarantee"`), `LEDGER_KEYS: Array[String]`(앞의 3개, 이 순서) | `START_TIER`는 #시작-자금 `tier = 1`과 K1 의 필수 행. `LEDGER_*`는 #상태 `ledger`의 고정 키 이름이고 `Economy`가 같은 이름을 쓴다. `LEDGER_KEYS`는 K5 검사용 목록이다(상태 `ledger` 순회에 쓰지 않는다, #결정성과-rng) |
| `Economy` | `new(config: EconomyConfig, bus: EventBus)` | #입력-계약의 이벤트를 구독. 이벤트 발행 없음 |
| | `cash`, `tier`, `day`, `phase`, `ticket_price`, `upkeep_per_day`, `ledger`, `bailouts_left`, `pending_bailout`, `loans`, `bankrupt` | 읽기 전용 |
| | `update(ctx: Dictionary) -> void` | no-op. `TickLoop` 등록용(#정산 "틱 업데이트·등록") |
| | `snapshot() -> Dictionary`, `restore(d) -> bool` | #스냅샷. `TickLoop` 훅으로 그대로 등록한다 |
| | `static compute_settlement(row: Dictionary, rate_scale: int, inputs: Dictionary) -> Dictionary` | 순수 함수. `inputs = {ticket_price, admissions, audience, upkeep, guarantee, loan_repayment}` → S1~S12, S14 의 값(`day_settled`에서 `day`·`cash` 뺀 키). 상태 불변 |
| | `static split_installments(total: int, n: int) -> Array` | 순수 함수. R5 회차 분할: 길이 `n`, 앞의 `total mod n`개가 `total ÷ n + 1`, 나머지가 `total ÷ n`, 합 = `total`. 구제 제안의 `installments`가 쓴다. 호출자는 `n ≥ 1`, `total ≥ 0`을 보장한다(`bailout_repay_days`는 1 이상) |
| `JsonUtil`(core, `project/core/json_util.gd`) | `static as_int(v: Variant) -> Variant` | `int`면 그대로, 정수값이고 `\|v\| < 2^63`인 유한 `float`(`25.0`)면 `int`, 그 밖(`bool`·문자열·`1.5`·`null`·`inf`·`nan`·`\|v\| ≥ 2^63`인 `±1e19`)이면 `null`. 상태 입력·스냅샷 정규화에 쓴다. SE-044 에서 `EconomyConfig.as_int`를 core 로 옮겼다(`MapConfig`와 공용, 2^63 가드 추가 — 그런 값이 든 스냅샷·입력은 "정수가 아님"으로 거절) |

## 수치표

모든 값은 [`project/data/economy/economy.json`](../../project/data/economy/economy.json) (version 1). 이 절의 숫자는 그 파일 값이거나 그 값으로 계산한 파생값이다.

### 전역 필드

| 필드 | 값 | 쓰는 곳 | 근거 |
|---|---|---|---|
| `rate_scale` | 10,000 | R2, R3, 모든 `⌊ ⌋` | 단위 정의. 스키마가 `enum [10000]`으로 고정 |
| `starting_cash` | 5,000 | #시작-자금 | 적자 공연만 해도 첫 구제까지 8일(#파산-시나리오), 기준 공연이면 건설 3,000 후에도 첫날 흑자 |
| `bailout_count` | 2 | B2·B3 | Q1 추천. 적자만 반복하면 14일째 파산 |
| `demolish_refund_rate_bp` | 7,000 (70%) | F3 | PRD 결정. 스키마가 `enum [7000]`으로 고정(변경은 ADR) |
| `guarantee_by_grade.local` | 400 | 개런티 | 기준 매출 2,720 의 약 15% |
| `guarantee_by_grade.rookie` | 800 | 개런티 | local 의 2배. 관객 끌기 효과는 artist.md·audience.md |
| `charge_reasons` | `build: capital`, `guarantee: operating` | C2, C4 | 건설은 자산, 개런티는 그날 영업비 |

### 티어 행 (`rows[tier_1]`)

| 필드 | 값 | 쓰는 곳 | 근거 |
|---|---|---|---|
| `rent_per_day` | 600 | S6 | 기준 시나리오 세후 순이익 1,142 = 임대료의 1.90배(목표 1.5~2.5) |
| `tax_rate_bp` | 1,000 (10%) | S11 | Q3 추천 |
| `ticket_price_default` | 20 | 시작 가격 | 기준 시나리오 |
| `ticket_price_min` / `max` | 5 / 40 | P3 | Q4. 기본가의 1/4 ~ 2배 |
| `bar_purchase_rate_bp` | 6,000 (60%) | S2 | 관객 10명 중 6명이 바를 이용 |
| `bar_avg_spend` | 12 | S3 | 티켓가의 60% |
| `bar_cost_rate_bp` | 3,500 (35%) | S4 | 바 매출의 65%가 이익. 바가 티켓보다 이익률이 낮지만 유일한 추가 수익원 |
| `bailout_loan_amount` | 3,000 | 구제 원금 | 기준 공연(개런티 400 + 유지·임대 800) 약 2.5일분 운영 자금 |
| `bailout_interest_bp` | 1,000 (10%) | 이자 | 구제 1회의 대가 = 원금의 10% |
| `bailout_repay_days` | 10 | 회차 | 회차당 약 400 = 공연 하루 적자(706)보다 작아, 흑자 전환하면 갚을 수 있음 |

### 기준 시나리오 (`reference_scenarios[tier1_baseline]`)

입력: 티어 1, `admissions` 100, `audience` 100, 티켓가 = `ticket_price_default`(20), 개런티 `local`(400, `book_if_affordable`), `upkeep_per_day` 200, 대출 없음.
유지비 200 은 **가구 v0 가정 목록**의 `upkeep_per_day` 합이다: 소형 무대 1, 바 카운터 1, 스피커 2, 조명 4, 화장실 2, 비상구 1. furniture 티켓은 이 목록의 합이 `reference_scenarios[tier1_baseline].upkeep_per_day`와 같도록 값을 정하거나, 다르면 이 시나리오를 함께 고친다.

| 단계 | 항목 | 계산 | 값 |
|---|---|---|---|
| (낮) | 개런티 선지급 | 즉시, `cash −= 400` | 400 |
| S1 | `ticket_revenue` | 20 × 100 | 2,000 |
| S2 | `bar_buyers` | ⌊100 × 6,000 ÷ 10,000⌋ = ⌊60⌋ | 60 |
| S3 | `bar_revenue` | 60 × 12 | 720 |
| S4 | `bar_cost` | ⌊720 × 3,500 ÷ 10,000⌋ = ⌊252.0⌋ | 252 |
| S5 | `revenue` | 2,000 + 720 | 2,720 |
| S6 | `rent` | | 600 |
| S7 | `upkeep` | | 200 |
| S8 | `guarantee` | `ledger.guarantee` | 400 |
| S9 | `operating_costs` | 252 + 600 + 200 + 400 | 1,452 |
| S10 | `pretax` | 2,720 − 1,452 | 1,268 |
| S11 | `tax` | ⌊1,268 × 1,000 ÷ 10,000⌋ = ⌊126.8⌋ | 126 |
| S12 | `net` | 1,268 − 126 | **1,142** |
| S13 | `loan_repayment` | 대출 없음 | 0 |
| S14 | `settlement_delta` | 2,720 − 252 − 600 − 200 − 126 − 0 | 1,542 |
| 합 | 하루 현금 변화 | −400 + 1,542 | +1,142 (= `net`) |

판정(AC4): `net ÷ rent_per_day` = 1,142 ÷ 600 = 1.903 (bp 로 ⌊1,142 × 10,000 ÷ 600⌋ = 19,033) → `checks.net_to_rent_min_bp` 15,000 ~ `net_to_rent_max_bp` 25,000 안.

참고(파생값, 같은 공식·같은 입력에서 `admissions = audience`만 바꿈):

| 입장 = 관객 | `pretax` | `tax` | `net` | `net ÷ rent` | 티어 2 자금까지(아래 공식) |
|---|---|---|---|---|---|
| 48 | −21 | 0 | −21 | — | 도달 불가 |
| 49 | 7 | 0 | 7 | 0.01 | 4,000일 |
| 50 | 34 | 3 | 31 | 0.05 | 904일 |
| 80 | 775 | 77 | 698 | 1.16 | 41일 |
| 91 | 1,042 | 104 | 938 | 1.56 | 30일 |
| 100 | 1,268 | 126 | 1,142 | 1.90 | 25일 |
| 120 | 1,762 | 176 | 1,586 | 2.64 | 18일 |
| 150 | 2,502 | 250 | 2,252 | 3.75 | 13일 |

손익분기는 입장 49명(로컬 개런티, 티켓 20)이고 티어 1 수용 하한 `tiers.json` `capacity_min` 50 과 맞물린다. 꽉 찬 150명이면 임대료의 3.75배다.

### 티어 2 해금 자금 도달 추정 (AC6)

공식: `days = ⌈(tiers[tier_2].unlock_cash − starting_cash + initial_build_spend) ÷ net⌉`
= ⌈(30,000 − 5,000 + 3,000) ÷ 1,142⌉ = ⌈24.52⌉ = **25 게임일** ≤ `checks.tier2_max_days` 30.

- `initial_build_spend` 3,000 은 1일차 낮 건설비 가정값(`reference_scenarios[tier1_baseline].initial_build_spend`, capital 이라 손익 밖). 가구 건설비가 정해지면 furniture 티켓이 갱신한다.
- 일자 검증: 1일차 건설 뒤 2,000 → 매일 +1,142 → 24일 정산 뒤 29,408(미달), 25일 정산 뒤 30,550(도달).
- 시간 근거: PRD "티어 2까지 약 2시간". 1일 = 3,300틱(`sim.json`) = 낮 1,800틱(3배속 60초) + 저녁 600틱(1배속 60초) + 공연 900틱(90초) + 정산 리포트(약 30초, 플레이어 체류 가정) ≈ 4분. 2시간 ≈ 30일. 25일 ≈ 100분.
- 30일 안에 들려면 평균 입장이 91명 이상이어야 한다(위 표). 입장 수 곡선은 audience.md 와 qa 봇 플레이로 맞춘다.
- 범위 밖: 티어 2 의 다른 조건 **명성 500**(`tiers.json` `unlock_reputation`)은 reputation.md 소관이고 이 추정에 넣지 않았다. "자금 3만"은 `economy.day_settled.cash ≥ unlock_cash`로 해석했다(판정은 reputation.md 가 확정, #입력-계약).

### 파산 시나리오 (`reference_scenarios[tier1_bankrupt]`)

입력: 티어 1, 시작 5,000, 건설 0, 매일 낮에 로컬 섭외 시도(`book_if_affordable`: `cash ≥ 400`이면 승인되어 공연, 아니면 C3 거절로 그날 공연 없음), 공연한 날 `admissions = audience = 20`, `upkeep_per_day` 200, 티켓가 20, 구제는 제안된 close 에서 바로 수락.

공연한 날 1일 손익: `ticket_revenue` 400, `bar_buyers` ⌊20 × 6,000 ÷ 10,000⌋ = 12, `bar_revenue` 144, `bar_cost` ⌊144 × 3,500 ÷ 10,000⌋ = ⌊50.4⌋ = 50, `revenue` 544, `operating_costs` 50 + 600 + 200 + 400 = 1,250, `pretax` −706, `tax` 0, `net` −706, `settlement_delta` 544 − 50 − 600 − 200 − 0 = −306(상환 전).
공연 없는 날: `revenue` 0, `operating_costs` 800, `pretax` −800, `settlement_delta` −800(상환 전).

| 일 | 시작 현금 | 개런티(즉시) | 공연 | `settlement_delta` 상환 전 | 상환 | 정산 뒤 현금 | 판정 | 구제 후 현금 |
|---|---|---|---|---|---|---|---|---|
| 1 | 5,000 | 400 | ○ | −306 | 0 | 4,294 | | |
| 2 | 4,294 | 400 | ○ | −306 | 0 | 3,588 | | |
| 3 | 3,588 | 400 | ○ | −306 | 0 | 2,882 | | |
| 4 | 2,882 | 400 | ○ | −306 | 0 | 2,176 | | |
| 5 | 2,176 | 400 | ○ | −306 | 0 | 1,470 | | |
| 6 | 1,470 | 400 | ○ | −306 | 0 | 764 | | |
| 7 | 764 | 400 | ○ | −306 | 0 | 58 | | |
| 8 | 58 | 거절(58 < 400) | × | −800 | 0 | **−742** | **구제 1 제안** | 3,000 |
| 9 | 3,000 | 400 | ○ | −306 | 412 | 1,882 | | |
| 10 | 1,882 | 400 | ○ | −306 | 412 | 764 | | |
| 11 | 764 | 400 | ○ | −306 | 412 | **−354** | **구제 2 제안** | 3,000 |
| 12 | 3,000 | 400 | ○ | −306 | 412 + 369 = 781 | 1,513 | | |
| 13 | 1,513 | 400 | ○ | −306 | 781 | 26 | | |
| 14 | 26 | 거절(26 < 400) | × | −800 | 781 | **−1,555** | **파산(게임 오버)** | — |

| 구제 | 제안일 | `deficit` | `amount` | `interest` | `total_due` | `installments` |
|---|---|---|---|---|---|---|
| 1 | 8 | 742 | 742 + 3,000 = 3,742 | ⌊3,742 × 1,000 ÷ 10,000⌋ = ⌊374.2⌋ = 374 | 4,116 | 4,116 = 411 × 10 + 6 → 412 × 6회, 411 × 4회 |
| 2 | 11 | 354 | 354 + 3,000 = 3,354 | ⌊335.4⌋ = 335 | 3,689 | 3,689 = 368 × 10 + 9 → 369 × 9회, 368 × 1회 |

결과: **구제 1 은 8일째, 구제 2 는 11일째 제안, 14일째 정산에서 게임 오버.** 기대값은 `reference_scenarios[tier1_bankrupt].expected`(`cash_by_day`, `bailout_offered_days`, `bailout_amounts`, `bankrupt_day`).
`bailout_count`만 바꿨을 때(같은 입력): 0회 → 8일, 1회 → 11일, 2회 → 14일, 3회 → 16일에 게임 오버(Q1).

이 시나리오는 "제안된 close 에서 바로 수락"(수동 수락, `day_taken` = 제안일)으로 계산했다. 자동 수락(다음 날 `time.day_started`)으로 바꿔도 기대값은 같다.
- 두 수락 시점 사이에 현금을 바꾸는 입력이 없다. 개런티 지출은 다음 날 낮, `day_started` 뒤에 온다. 그래서 다음 날 낮의 시작 현금이 3,000 으로 같다.
- S13 은 날짜를 보지 않는다. 그래서 두 경로 모두 구제 1 의 첫 회차는 9일 정산, 구제 2 의 첫 회차는 12일 정산에서 나간다.

**기대값 변경 없음 근거(2026-10-09 후속).** `day_taken` 정의 변경(제안일 고정)은 상환 시점을 바꾸지 않는다. S13 은 원래부터 수락 뒤 첫 정산에 첫 회차를 뺐다. 그래서 `reference_scenarios` 기대값은 그대로다.
- `tier1_bankrupt`: `cash_by_day`, `bailout_offered_days` [8, 11], `bailout_amounts` [3,742, 3,354], `bankrupt_day` 14.
- `tier1_baseline`: 대출이 없어 영향이 없다.

## 수용 기준

구현 티켓(SE-012)의 테스트 케이스 목록이다. 파일은 EC1 만 `project/tests/sim/test_economy_config.gd`이고 EC2~EC16 은 `project/tests/sim/test_economy.gd`다. 기대 수치는 테스트에 하드코딩하지 않고 `economy.json`의 `reference_scenarios`와 행 값에서 읽는다(수치가 바뀌어도 테스트 코드는 그대로).

| # | 케이스 | 검증 |
|---|---|---|
| EC1 | `test_economy_config.gd::test_config_loads_and_cross_checks` | `EconomyConfig.load()`가 성공하고 `row(1)`·`guarantee("local")`가 JSON 값과 같음. K1~K5 를 하나씩 깬 사본(예: `ticket_price_min > ticket_price_default`, K4 는 `reference_scenarios[0].guarantee_grade = "midlevel"`, K5 는 `charge_reasons.build = "operating"`인 사본)은 `null`. `charge_reasons.guarantee = "capital"` 사본은 로드 성공(K5 는 `operating`만 제한). 정상 설정에서 `guarantee("midlevel") == -1`, `guarantee("nope") == -1` (#설정-로드와-공개-API). K5 두 케이스는 SE-012 후속 |
| EC2 | `test_economy.gd::test_new_game_state` | 생성 직후 `cash == starting_cash`, `ticket_price == ticket_price_default`, `bailouts_left == bailout_count`, `bankrupt == false`, 생성자가 이벤트 0개 (#시작-자금) |
| EC3 | `test_economy.gd::test_settles_once_on_close_entry` | `TickLoop`으로 `advance(3300)` → `economy.day_settled` 정확히 1회(`day: 1`), 그 틱의 `tick.advanced`보다 먼저. 같은 `time.phase_changed {to:"close", day:1}`를 다시 발행해도 정산 0회. 다음 날 close 에서 `day: 2`로 1회 더 (#정산 1회성) |
| EC4 | `test_economy.gd::test_immediate_vs_settlement_items` | `charge_proposed {reason:"build", amount:1000}` → 즉시 `cash −1000`, `day_settled.operating_costs`·`pretax`에 안 들어감. `{reason:"guarantee", amount:400}` → 즉시 `cash −400`, `day_settled.guarantee == 400`이고 `operating_costs`에 포함, `settlement_delta`에는 안 들어감. `sales_reported`는 정산 전까지 `cash` 불변 (#즉시-반영-항목과-정산-반영-항목) |
| EC5 | `test_economy.gd::test_charge_declines` | C1(파산 뒤) `"bankrupt"`, C2(모르는 사유·음수·비정수) `"invalid"`, C3(`cash < amount`) `"insufficient_cash"` 각각 `charge_resolved {approved:false}` 1개, `cash_changed` 0개, 상태 불변. `amount == cash`는 승인되어 `cash == 0` |
| EC6 | `test_economy.gd::test_tax_floor_zero_on_loss_and_zero_rate` | `pretax` 1,268 → `tax` 126(내림). `pretax` −706 → 0. `tax_rate_bp` 0 인 설정 사본 → 항상 0. 손실 이월 없음(손실 다음 날 세금이 그날 `pretax`로만 계산) (#비용-세금) |
| EC7 | `test_economy.gd::test_demolish_refund_floor` | `refund_proposed {reason:"demolish", base_amount}` 1,000 → `+700`, 999 → `+699`, 1 → `+0`이고 `cash_changed` 없음. `reason` 다름·음수 → 무시. 환불은 `pretax`에 안 들어감 (F1~F3) |
| EC8 | `test_economy.gd::test_reference_scenario_baseline` | `tier1_baseline`: `compute_settlement` 결과가 `expected`의 S1~S14 키와 전부 같음. 버스로 하루 진행(build 지출 → 개런티 지출 → `sales_reported` → close)한 `day_settled` 페이로드도 같음. `net × rate_scale ÷ rent_per_day`가 `checks` 범위 안. `⌈(tier_2.unlock_cash − starting_cash + initial_build_spend) ÷ net⌉ == expected.days_to_tier2_cash ≤ checks.tier2_max_days` (#기준-시나리오) |
| EC9 | `test_economy.gd::test_bailout_offered_then_accepted` | 정산 뒤 `cash < 0`, `bailouts_left > 0` → `economy.bailout_offered` 페이로드가 공식대로(`deficit`, `amount`, `interest`, `total_due`, `first_installment`, `bailouts_left_after`). `economy.bailout_accept_requested` 후 경계 처리(`bus.dispatch_commands()`) → `cash == bailout_loan_amount`, `bailouts_left` 1 감소, `loans` 1개, `cash_changed {reason:"bailout"}` → `bailout_taken {auto:false}`. 두 번째 수락 명령은 무시 (#파산과-구제) |
| EC10 | `test_economy.gd::test_bailout_auto_accepted_on_next_day` | `d`일 close 에서 구제 제안 → 수락 없이 `time.next_day_requested` → `advance(0)` → 이벤트 순서 `time.day_started → time.phase_changed → time.speed_changed → economy.cash_changed → economy.bailout_taken {auto:true}`. `bailout_taken.day == d`(제안일), `loans[0].day_taken == d`. 그 다음 정산(`d + 1`일 close)의 `economy.day_settled.loan_repayment == bailout_offered.first_installment`. 같은 입력을 수동 수락(`d`일 close)으로 돌린 실행과 `d + 1`일 `day_settled` 페이로드가 같음. **S0 (SE-012 후속):** `EventBus`만으로 `d`일 close 에서 구제가 제안된 뒤 `time.day_started` 없이 `time.phase_changed {to:"close", day: d + 1}`을 직접 발행 → `push_warning` 1회, 이벤트 `economy.cash_changed {reason:"bailout"} → economy.bailout_taken {auto:true, day:d} → (settlement_delta ≠ 0 이면 economy.cash_changed {reason:"settlement"}) → economy.day_settled`, `bailouts_left` 1 감소, `loans[0].day_taken == d`, `day_settled.loan_repayment == first_installment`. 같은 날의 close 를 한 번 더 발행하면 아무 일도 없음(1회성, `pending_bailout` 그대로) |
| EC11 | `test_economy.gd::test_loan_installments` | `total_due` 4,116, `repay_days` 10 → `installments` = 412 × 6 + 411 × 4, 합 4,116. 첫 상환은 수락 뒤 첫 정산(S13), 10회 뒤 `loans`에서 제거. 두 대출이 겹치면 받은 순서로 합산 (R5, S13) |
| EC12 | `test_economy.gd::test_bankrupt_after_bailouts_exhausted`(파산 뒤 잘못된 `time.phase_changed` 페이로드 포함), `test_economy.gd::test_bankrupt_restore_keeps_pending_bailout`(복원한 `bankrupt: true` + `pending_bailout` 에서 `time.day_started` 자동 수락 없음) (SE-022 추가) | `tier1_bankrupt` 정책으로 날을 돌려 날마다 정산 뒤 `cash`가 `expected.cash_by_day`, 구제 제안일이 `bailout_offered_days`, 원금이 `bailout_amounts`, `economy.bankrupt {day}`가 `bankrupt_day`에 정확히 1회. 그 뒤 지출·환불·매출·가격·정산 입력이 전부 무시됨. **파산 뒤 `time.*` (SE-016):** 14일 close 파산 뒤 `time.day_started {day: 15}` → `time.phase_changed {from:"close", to:"day", day: 15}` → … → `{to:"close", day: 15}`를 보내면 `economy.day == 15`, `economy.phase == "close"`이고, `day`·`phase`를 뺀 `snapshot()`은 파산 직후와 같다. 이 사이 `economy.*` 이벤트는 `economy.charge_resolved {approved:false, decline_reason:"bankrupt"}`와 `economy.ticket_price_rejected {reason:"not_allowed", phase: <명령 처리 시점의 현재 구간>}`뿐이고 `economy.day_settled`·`bailout_offered`·`bailout_taken`·`cash_changed`는 0건. 가격 요청을 15일 `"day"` 구간에서 처리하면 `ticket_price_rejected.phase == "day"`(파산일의 `"close"`가 아님)를 리터럴로 단언한다 (B3, #파산과-구제 "파산 뒤") |
| EC13 | `test_economy.gd::test_ticket_price_rules` | P1~P5: 비정수 `"invalid"`, 낮 아닌 구간 `"not_allowed"`, 범위 밖 `"out_of_range"`, 같은 값 무시, 정상 → `ticket_price_changed {price, from}`. `{price: 25.0}`·`{price: 25.5}` → 각각 `publish()` `false` + `push_error` 1회, 경계 처리 뒤 `economy.ticket_price_*` 이벤트 0개, 상태 해시 불변(tick.md E4) (#티켓-가격) |
| EC14 | `test_economy.gd::test_settlement_event_order` | close 진입 틱의 이벤트: `time.phase_changed {to:"close"}` → `economy.cash_changed {reason:"settlement"}` → `economy.day_settled` → (`economy.bailout_offered` 또는 `economy.bankrupt`) → `time.speed_changed {speed:0}` → `tick.advanced`. 정산 연쇄는 최외곽 `time.phase_changed` 발행 안에서 끝난다(tick.md E3). `settlement_delta == 0`이면 `cash_changed` 없음 (#정산 이벤트) |
| EC15 | `test_economy.gd::test_determinism_no_rng` | 같은 시드·같은 명령/입력 열로 두 번 돌린 `economy.*` 이벤트 열과 `snapshot()` 해시가 같음. 정산 전후 `rng.get_state()["economy"]` 불변 (#결정성과-rng) |
| EC16 | `test_economy.gd::test_snapshot_roundtrip` | 대출 진행 중(`loans` 1개, `paid` ≥ 1)이고 `pending_bailout`이 있는 상태에서. (a) **`Economy` 단독 왕복:** `Economy.snapshot()` → JSON 왕복 → 새 `Economy.restore()` → 같은 입력 열 → 연속 진행과 경제 상태 해시가 같음. (b) **`TickLoop` 수준 왕복(SE-011):** economy 를 훅과 함께 등록한 루프에서 `TickLoop.snapshot()["systems"]["economy"] == Economy.snapshot()` → JSON 왕복 → 새 `TickLoop` + 새 `Economy`(같은 방식으로 등록)에 `restore()` `true` → 양쪽 `advance(3300)` + 같은 입력 → `TickLoop` 상태 해시(`systems.economy` 포함)와 `economy.*` 이벤트 열이 같음(복원 후 진행 = 연속 진행). (c) 잘못된 스냅샷(필드 누락, `loans[].installments`에 `1.5`, `cash`가 문자열)과 **범위 검사 ①~⑥ 각각의 위반 사본(SE-015)**: 정상 스냅샷(위 전제 상태)을 `duplicate(true)` 한 뒤 필드 하나만 바꾼다. ① `tier = 99`, ② `day = 0`, ③ `ticket_price = -1`(`upkeep_per_day`·`last_settled_day`·`bailouts_left`도 각 `-1` 1건씩 권장), ④ `ledger.admissions = -1`, ⑤ `pending_bailout.installments`에서 한 개 뺀 배열, ⑥ `loans[0].paid = loans[0].installments.size()`와 `loans[0].paid = -1`(총 ≥ 7건). 각 사본에서 `Economy.restore()`가 `false`, `push_error` 정확히 1회(`assert_push_error_count` 누적), 경제 상태 해시(`JSON.stringify(snapshot(), "", true)`) 불변. 같은 항목을 `systems.economy`에 넣은 `TickLoop` 스냅샷은 `TickLoop.restore()`가 `false`이고 `TickLoop`·`Economy` 해시 불변, `push_error` 2회(시스템 1 + `TickLoop` 1). 범위 위반의 `TickLoop` 경로는 ②·⑥ 두 건이면 된다. 어느 경우든 복원 중 이벤트 0개. 범위 위반 케이스는 같은 파일의 새 케이스 `test_restore_rejects_out_of_range`로 나눠도 된다 (#스냅샷 "범위 검사", tick.md #스냅샷 restore 5~7단계·SH3) |

## 테스트 방법

- 데이터: `python3 tools/validate_data.py --strict` — `economy.json`이 `economy.schema.json`(version `enum [1]`, `additionalProperties: false`, `rate_scale` `enum [10000]`, `demolish_refund_rate_bp` `enum [7000]`)을 통과.
- 손계산(qa, 이 티켓): #기준-시나리오와 #파산-시나리오 표를 이 문서의 공식과 `economy.json` 값만으로 다시 계산해 `docs/reports/SE-005.md`에 일치/불일치를 적는다. 기대값은 `reference_scenarios[].expected`와도 대조한다.
- 헤드리스(구현 티켓): `tools/run_tests.sh project/tests/sim` → `test_economy_config.gd`의 EC1, `test_economy.gd`의 EC2~EC16. 단위 케이스는 `EventBus` 하나에 `time.*` 이벤트를 테스트가 직접 발행해 구동하고, EC3·EC10·EC14·EC15·EC16(b) 는 `TickLoop`으로 구동한다(economy 를 훅과 함께 등록). Godot 이 없으면 `SKIP` → CI(`godot-tests`).
- 스펙 대조(reviewer): AC1·AC2·AC7·AC8 → `docs/reviews/SE-005.md`. 특히 이 문서의 이벤트 이름과 `events.md` 표, 공식의 상수와 `economy.json` 필드.

## 열린 질문

> **결정(2026-10-09, 프로덕트 오너):** 아래 질문 전부 추천안 채택. 현재 데이터 값이 확정값이다. 바꾸려면 새 질문으로 다시 올린다.

사람 결정 항목(Q1~Q5)은 producer 가 `docs/status/`로 옮긴다. 추천안은 이미 `economy.json`에 들어 있는 현재 값이다.

| # | 질문 | 선택지 | 추천 | 바꾸면 |
|---|---|---|---|---|
| Q1 | 구제 횟수 N (`bailout_count`) | (a) 1 (b) 2 (c) 3 | **(b) 2.** 적자 공연만 반복해도 14일 버텨 실수를 만회할 시간이 있고, 이자 10%·운영 자금 3,000 이라 구제가 공짜 돈이 되지 않는다. 프로덕션 목표 "봇 1,000판 파산율 10~25%"가 qa 통계로 나오면 재조정 | 데이터만. 파산 시나리오 게임 오버일: (a) 11일 (b) 14일 (c) 16일 |
| Q2 | 구제 방식 | (a) 긴급 대출만(현재) (b) 스폰서 구제만(상환 없음, 대신 일정 기간 매출 일부 양도) (c) 제안 시 둘 중 선택 | **(a) 티어 1~2 는 대출만.** 티어 3 에 스폰서 계약 시스템이 들어올 때(`tiers.json` `sponsor_contracts`) (c)로 확장 | (b)/(c)는 `kind: "sponsor"` 공식·필드 추가 = 스키마 version 2 + 이 문서 개정 |
| Q3 | 세금 v0 포함 여부 (`tax_rate_bp`) | (a) 0% (b) 10%(현재) (c) 20% | **(b) 10%.** 흑자일만 걷어 적자일 부담이 없고, 셋 다 기준 시나리오 목표를 지킨다: (a) `net` 1,268·2.11배·23일 (b) 1,142·1.90배·25일 (c) 1,015·1.69배·28일 | 데이터만(`reference_scenarios` 기대값 갱신 필요) |
| Q4 | 티켓가 플레이어 조정 범위 | (a) 고정(기본가 20) (b) 5~40, 1 단위(현재) (c) 10~30 | **(b), 단 audience.md 가 가격 → 입장 수 반응을 넣기 전까지 UI 는 (a)처럼 잠근다.** v0 경제에서 입장 수는 입력이라 가격을 올리면 손해 없이 매출만 오른다 | 데이터만(`ticket_price_min/max`). UI 잠금은 UI 티켓 |
| Q5 | 구제 거절 허용 | (a) 불가 — 수락 명령 또는 다음 날 자동 수락(현재) (b) 거절 가능, 거절 = 즉시 파산 | **(a).** 거절의 유일한 결과가 게임 오버라 선택지가 아니다. 스폰서(Q2 (c))가 생기면 "어느 구제를 받을지"만 고르게 한다 | (b)는 거절 명령 1개 추가(채택 시 events.md 에 이름 등록) + 이 문서 개정 |
| Q6 | (producer, 사람 결정 불요) 입력 이벤트 발행 주체 연결 | build·artist·audience 스펙이 #입력-계약의 `economy.charge_proposed`·`refund_proposed`·`sales_reported`·`upkeep_reported`를 쓰게 | 각 스펙 티켓의 범위에 "economy 입력 계약 준수"를 넣는다. 가구 필드 `upkeep_per_day`(예약), `build_cost`(제안) | — |
| Q7 | (producer, 사람 결정 불요) 스냅샷 연결 | 경제 상태를 `TickLoop.snapshot()`에 넣는 방법이 tick.md v0 에 없다(시간만) | **결정(SE-011):** 최상위 `economy` 키 대신 `TickLoop.register_system(id, update, snapshot_hook, restore_hook)` 훅으로 `TickLoop.snapshot()["systems"]["economy"]`에 넣는다. 복원은 tick.md #스냅샷 restore 5~7단계(불일치 규칙, 사전 스냅샷, 역순 롤백)를 따른다. economy 는 등록 필수다(#정산 "틱 업데이트·등록"). `snapshot_schema_version` 1→2·`sim.json` version 3 은 리터럴 테스트 3곳을 고치는 SE-012 와 같은 PR 에서 적용한다(game-designer 2차). 근거와 D1~D7 은 tick.md 변경 이력 SE-011 행과 docs/tickets/SE-011.md | 닫힘 |

## 변경 이력

| 날짜 | 버전 | 티켓 | 내용 |
|---|---|---|---|
| 2026-10-09 | economy.md v0 | SE-005 | 신규 작성 |
| 2026-10-09 | `economy.json` v1, `economy.schema.json` version 1 | SE-005 | 신규 테이블. 전역(`rate_scale`, `starting_cash`, `bailout_count`, `demolish_refund_rate_bp`, `guarantee_by_grade`, `charge_reasons`) + 티어 행(`rows[tier_1]`) + `reference_scenarios`(기준·파산 시나리오 입력과 기대값). 티켓 후보 필드 이름에서 바꾼 것: 비율은 정수 bp(`tax_rate` → `tax_rate_bp`, `bailout_interest_rate` → `bailout_interest_bp`, `bar_purchase_rate`·`bar_cost_rate`·`demolish_refund_rate` → `*_bp`). `tiers.json`은 바꾸지 않았다(경제 수치는 `economy.json` 행으로 분리) |
| 2026-10-09 | economy.md v0 (후속 수정) | SE-005 후속 (리뷰 발견 1) | 대출 `day_taken`과 `economy.bailout_taken.day`를 제안일(`pending_bailout.day`)로 고정했다. "첫 상환은 다음 정산(`day_taken + 1`)부터"를 "첫 회차는 수락 뒤 첫 정산(S13)"으로 바꾸고, 상환 시점에 날짜 조건을 두지 않는다고 적었다. EC10 에 단언 3개를 추가했다: 자동 수락 다음 정산의 `loan_repayment == first_installment`, `day_taken`·`bailout_taken.day` = 제안일, 수동 수락과 같은 `day_settled`. EC11 문구도 맞췄다. 상환 시점(S13)이 그대로라 `reference_scenarios` 기대값은 바뀌지 않았다(파산 시나리오 절 근거) |
| 2026-10-09 | economy.md v0 (후속 수정) | SE-005 후속 (리뷰 발견 2) | 입력 계약에서 "reputation 은 정산이 끝난 `cash`를 본다"를 지웠다. 대신 정산 결과가 필요한 시스템은 `economy.day_settled`를 구독한다고 적었다(티어 해금 자금 = `day_settled.cash`, 구독 순서와 무관). 티어 2 도달 추정 절의 해석 문구도 같은 이벤트로 맞췄다. "다른 시스템은 `cash`를 직접 읽지 않는다"와 모순되는 문장은 0개다 |
| 2026-10-09 | economy.md v0 (후속 수정), `economy.schema.json` version 1 유지 | SE-005 후속 (리뷰 발견 3) | 설정 로드 검사에 K4(`reference_scenarios[].guarantee_grade` ∈ `guarantee_by_grade` 키)를 추가했다. `EconomyConfig.guarantee()`에 모르는 등급이면 `push_error` 후 `-1`을 돌려준다고 적었다(그 값을 지출로 보내면 C2 거절). `row()`의 없는 티어 반환값(`{}`)도 적었다. EC1 에 K4 위반 사본과 `guarantee("midlevel") == -1`을 추가했다. 스키마는 enum 을 줄이지 않고(artist.md 등급 이름 5종 유지) `guarantee_grade`·`guarantee_by_grade`의 `description`만 고쳤다. 받아들이는 문서 집합이 그대로라 스키마 `version`과 `economy.json` `version`은 1 로 두었다. `economy.json`은 바꾸지 않았다 |
| 2026-10-09 | economy.md v0 (후속 수정), `economy.json`·스키마 변경 없음 | SE-008 (SE-001 리뷰 발견 1) | 명령 페이로드 숫자 `int` 전용(tick.md E4)에 맞췄다. 입력 계약의 "정수값인 `float` 허용(tick.md 배속 요청과 같은 규칙)"을 명령 입력(`int`만, `float`는 버스가 거부해 핸들러 도달 없음)과 상태 입력(방어적 정수값 `float` 정규화 유지, 세이브 동치 무관)으로 나눴다. P1 에서 정수값 `float` 허용을 지우고 "버스가 먼저 거부"로 바꿨다. EC13 의 "`25.0` 허용"을 "`{price: 25.0}`·`{price: 25.5}` → `publish()` false + `push_error`, 이벤트 0개, 상태 해시 불변"으로 바꿨다. 이벤트 이름·페이로드 키·수치 변경 없음 |
| 2026-10-09 | economy.md v0 (후속 수정), `economy.json`·스키마 변경 없음 | SE-011 (Q7 닫기) | `TickLoop` 스냅샷 연결을 확정했다. "틱 업데이트" 문단을 "틱 업데이트·등록"으로 바꿨다. 이전 문장은 "등록하지 않아도 된다"였고, 이제 economy 는 `register_system("economy", economy.update, economy.snapshot, economy.restore)`로 **반드시** 등록한다(`update`는 no-op). 공개 API 표에 `update(ctx)`를 더했다. 스냅샷 절에 `TickLoop.snapshot()["systems"]["economy"]` 연결, restore 5~7단계, 훅 규약 SH1~SH7 준수를 적었다. EC16 을 (a) `Economy` 단독 왕복, (b) `TickLoop` 수준 왕복(`systems.economy` 포함, 복원 후 진행 = 연속 진행), (c) 잘못된 스냅샷 거부로 넓혔다. EC1 파일을 `test_economy_config.gd`로 옮겼다. 사유: `tools/hooks/check_commit.py`가 `project/sim/economy_config.gd`의 짝 테스트 `test_economy_config.gd`를 요구한다. 상단 "구현 티켓" 행을 SE-012 와 파일 4개로, 수용 기준·테스트 방법의 파일 경로를 맞췄다. Q7 을 결정으로 닫았다. 공식·수치·이벤트 이름·`reference_scenarios` 기대값 변경 없음 |
| 2026-10-09 | economy.md v0 (후속 수정), `economy.json`·스키마 변경 없음 | SE-012 (game-designer 2차, sim-engineer 결과 절 남은 질문 1·2) | (1) **회계 분류와 장부 키.** `ledger` 키는 고정 3개 그대로 두고, `operating` 사유는 `ledger` 키가 있는 사유(v0 `guarantee`)로 제한하는 로드 검사 K5 를 더했다(`build: operating` → `null`, `capital`은 무제한). C4 행의 "v0 operating 사유는 `guarantee` 하나"를 K5 근거로 바꾸고, K5 를 통과한 설정에서는 닿지 않는 방어 경로(승인·`cash` 차감, `push_error` 1회, `ledger` 불변 = 현재 구현)를 적었다. `ledger`를 `charge_reasons` 키 전체로 일반화하는 안은 버렸다. 그래도 S8 이 `guarantee`만 읽어 금액이 손익에서 빠지는 문제는 남는다. 또 상태·스냅샷 형식과 EC2 가 바뀐다. 새 `operating` 사유는 스키마·`ledger`·S8~S9·`day_settled`를 한 번에 개정한다고 적었다. (2) **`time.day_started` 없이 온 다음 close.** 정산 S0 을 더했다. 1회성 검사 뒤 `pending_bailout`이 남아 있으면 `push_warning` 1회 후 `auto: true`로 수락하고 정산한다. B2 시점의 `pending_bailout`은 항상 `null`이라 덮어쓰기가 없다. 덮어쓰기(기존 구현)를 버린 이유는 두 가지다. 구제 횟수를 쓰지 않고 적자일이 하루 늘어난다. 또 `time.day_started`가 있었을 때와 결과가 달라진다. 기존 제안 유지(덮어쓰지 않음)도 버렸다. 옛 `deficit`으로 정한 원금으로는 수락 뒤 `cash`가 `bailout_loan_amount`가 되지 않고 음수로 남을 수 있다(#상태 `cash` 불변식 위반). 그리고 새 적자에 대한 B2/B3 판정이 건너뛰어진다. S0 은 빠진 `time.day_started`가 왔을 때와 같은 결과를 낸다. 수락 목록에 계약 위반 방어 항목을 더했고, B2 행·EC1(K5 두 케이스)·EC10(S0 케이스)도 고쳤다. **코드 변경 필요 — SE-012 후속(sim-engineer):** `economy_config.gd` K5, `economy.gd` `_on_phase_changed`의 S0, `test_economy_config.gd`·`test_economy.gd` 해당 케이스. #스냅샷의 `sim.json` v3 문장을 "적용됨(SE-012)"으로 바꿨다. 공식 S1~S17·수치·이벤트 이름·페이로드 키·`reference_scenarios` 기대값은 바뀌지 않았다(TickLoop 경로와 v0 데이터에서는 S0·K5 가 동작을 바꾸지 않는다) |
| 2026-10-09 | economy.md v0 (후속 수정), `economy.json`·스키마 변경 없음 | SE-015 (docs/reviews/SE-012.md 발견 2·후속 제안 B) | #스냅샷에 `Economy.restore`가 이미 하던 **범위 검사 ①~⑥**을 적었다: `tier` 행 존재, `day ≥ 1`, `upkeep_per_day`·`last_settled_day`·`bailouts_left`·`ticket_price ≥ 0`, `ledger.*` ≥ 0, `pending_bailout.installments` 개수 == `repay_days`, `0 ≤ loans[].paid < installments` 개수. 위반 처리는 타입 오류와 같다(`push_error` 1회, `false`, 상태 불변, 이벤트 0). 하지 않는 의미 검사도 적었다. 검사를 지우거나 완화하는 안은 버렸다(tick.md SH3, S13 범위 밖 인덱스 방지). EC16 (c)에 6종 위반 사본(⑥은 2건)과 `push_error` 횟수 단언을 더했다. 구현이 이미 이 규칙이라 제품 코드 변경은 없다(테스트만 sim-engineer 2차). 공식·수치·이벤트·`reference_scenarios` 기대값 변경 없음 |
| 2026-10-09 | economy.md v0 (후속 수정), `economy.json`·스키마 변경 없음 | SE-016 (docs/reviews/SE-012.md 발견 3·4·후속 제안 C, docs/status/2026-W41.md 결정 로그 추천안 (a)) | (1) "파산 뒤"를 "모든 입력 무시"에서 "**경제 입력**만 무시, `day`·`phase` 추적 유지"로 바꿨다. 파산 뒤 `time.day_started`·`time.phase_changed`는 페이로드 검사 뒤 `day`·`phase`만 갱신한다. 정산·S0·자동 수락은 하지 않고 이벤트도 내지 않는다. #상태 표 `day`·`phase` 정의와 맞추고, `ticket_price_rejected.phase`가 낡은 구간을 싣지 않게 하려는 변경이다. "고정이며 시간은 TickLoop 에서 읽는다"는 안 (b)는 버렸다. EC12 에 파산 뒤 `time.*` 단언을 더했다(`day == 15`, `phase == "close"`, 나머지 스냅샷 불변, `ticket_price_rejected.phase` = 처리 시점 구간). **코드 변경 필요(sim-engineer 2차):** `economy.gd` `_on_phase_changed`·`_on_day_started`. (2) 공개 API 표에 `EconomyConfig.has_row`·`scenario`·`static as_int`·상수 `START_TIER`·`LEDGER_*`·`LEDGER_KEYS`와 `Economy.static split_installments`를 더했다. `scenario`는 없는 id 면 `{}`이고 `push_error`는 없다(구현 확인). 이 부분은 코드 변경이 없다. 공식·수치·이벤트 이름·페이로드 키·`reference_scenarios` 기대값·리플레이 기준값 변경 없음(파산 뒤 `day`·`phase`는 기대값에 없다) |
| 2026-10-09 | economy.md v0 (후속 수정), `economy.json`·스키마 변경 없음 | SE-022 (docs/reviews/SE-016.md 참고 1·2·후속 제안 A) | 수용 기준 EC12 행의 테스트 열에 SE-022 1차(sim-engineer)가 더한 케이스를 적었다: `test_bankrupt_after_bailouts_exhausted` 확장(파산 뒤 `time.phase_changed {to: 1, day: 15}` → `push_warning` "time.phase_changed 페이로드 무시", `day`·`phase`·나머지 상태 불변, 이벤트 0)과 새 케이스 `test_bankrupt_restore_keeps_pending_bailout`(`bankrupt: true` + 정상 형식 `pending_bailout` 스냅샷 `restore()` → `true`, 이어 `time.day_started` → `day`만 갱신, `pending_bailout`·`cash` 불변, `bailout_taken`·`cash_changed` 0건). 둘 다 #파산과-구제 "파산 뒤" 문단의 기존 규칙을 고정할 뿐이다. 범위 검사 "`bankrupt == true` 이면 `pending_bailout == null`"은 넣지 않는다(producer 결정 로그 2026-10-09) — 그 조합이 `restore()`를 통과하는 것이 새 케이스의 전제다. 규칙·공식·수치·이벤트·`reference_scenarios` 기대값 변경 0, 코드·데이터 변경 0 |
| 2026-10-09 | economy.md v0 (후속 수정), `economy.json`·스키마 변경 없음 | SE-044 A2 (SE-044 C 인계 1) | 구현에 맞춘 문서 2곳. (1) 공개 API 표: `EconomyConfig.static as_int` 를 지우고 `JsonUtil.as_int`(core `project/core/json_util.gd`, `MapConfig`와 공용) 행으로 옮김 — `\|v\| ≥ 2^63` 인 float 도 `null`(2^63 가드). (2) #입력-계약 `time.phase_changed` 행과 "파산 뒤" 문단: `to`가 `sim.json` `phases[].id`가 아니면 `push_error` 1회 후 무시(`day`·`phase` 불변). 코드·테스트는 SE-044 C(`economy.gd` `_on_phase_changed`, `test_economy.gd::test_unknown_phase_ignored`)가 이미 이 규칙. 공식·수치·이벤트·기대값 변경 0 |
