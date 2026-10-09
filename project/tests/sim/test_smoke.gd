extends GutTest
## 테스트 인프라 자체가 도는지 확인하는 스모크 테스트. 실제 시스템 테스트는 test_<시스템>.gd 에.


func test_gut_runs_headless() -> void:
	assert_true(true, "GUT 가 헤드리스로 실행된다")


func test_data_tables_load() -> void:
	var f := FileAccess.open("res://data/sim/sim.json", FileAccess.READ)
	assert_not_null(f, "sim.json 을 열 수 있다")
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	assert_true(parsed is Dictionary, "sim.json 은 객체다")
	assert_eq(int(parsed["ticks_per_second"]), 10, "고정 틱은 10/s (CLAUDE.md)")
