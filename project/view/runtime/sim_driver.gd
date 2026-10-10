class_name SimDriver
extends Node
## SE-040: 실시간 구동기. 매 프레임 `session.step(delta)` 하나만 부른다(tick.md #배속 "step(delta_s) 는 실시간 구동기",
## CLAUDE.md 원칙 2 의 유일한 예외 — `_process` 에서 시간을 진행시키는 것은 이 Node 뿐이다).
## 배속·일시정지(speed 0)·프레임 델타 상한(sim.json max_ticks_per_step)은 sim 이 정한다. view 는 delta 를 자르지 않는다.
## hold = true 면 step(0.0) 을 부른다: 시간은 흐르지 않고 명령(메뉴의 session.* 포함)만 경계에서 처리된다(tick.md S2).
## 시작 메뉴가 떠 있는 동안 main.gd 가 켠다(게임 상태가 아니라 "아직 시작 안 함" 표시 상태).
## 경계: GameSession 타입 참조만 허용(test_view_boundary 허용 목록, AC1). 다른 sim 메서드를 부르지 않는다.

## 시간 진행 없이 명령만 처리할 때 넘기는 델타(초).
const HOLD_DELTA_S: float = 0.0

## 주입(main.gd). null 이면 아무것도 하지 않는다.
var session: GameSession = null
## true 면 시간 정지(step(0.0) — 명령만 처리).
var hold: bool = false
## 마지막 프레임에 처리한 틱 수(디버그·테스트용 표시 값).
var last_ticks: int = 0


func _init() -> void:
	name = "SimDriver"
	# 같은 프레임의 표시 보간(CrowdView 등)보다 먼저 돈다: 이번 프레임의 틱 이벤트를 받은 뒤 보간한다.
	process_priority = -1


func _process(delta: float) -> void:
	drive(delta)


## 한 프레임 구동. 처리한 틱 수.
func drive(delta: float) -> int:
	if session == null:
		return 0
	last_ticks = session.step(HOLD_DELTA_S if hold else delta)
	return last_ticks
