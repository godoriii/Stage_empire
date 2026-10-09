extends GutTest
## SE-013 qa 추가 검증(qa 작성). 기존 test_spike_scene.gd 의 빈 곳을 메운다.
## - 구성 E 와 B 의 씬은 군중 cast_shadow 한 곳만 다르다(그림자를 끄면서 다른 캐스터가 같이 꺼지지 않았는지).
## - 무대 프록시가 "범위 안" 단언을 넘어, 라이트가 움직이는 동안에도 셰도우 Omni(큐브 그림자, 방향 무관)의
##   구체와 실제로 겹치는지(= 군중 그림자를 꺼도 셰도우 패스가 비지 않는다는 E 측정의 전제).
## - --config= 대소문자 무시.

const SPIKE_SCENE: String = "res://view/perf/spike_crowd.tscn"
const SETTINGS_PATH: String = "res://view/perf/spike_configs.tres"
const STEPS: int = 12
const STEP_SEC: float = 0.5

var _settings: SpikeConfigSet


func before_all() -> void:
	_settings = load(SETTINGS_PATH) as SpikeConfigSet


func _spawn(config_id: String) -> SpikeCrowd:
	var vp: SubViewport = ViewTestUtil.make_viewport(self)
	autofree(vp)
	var spike: SpikeCrowd = (load(SPIKE_SCENE) as PackedScene).instantiate() as SpikeCrowd
	spike.config_id = config_id
	vp.add_child(spike)
	return spike


## 씬 안 모든 GeometryInstance3D 의 "스파이크 기준 경로" → cast_shadow.
func _shadow_map(spike: SpikeCrowd) -> Dictionary:
	var out: Dictionary = {}
	var re: RegEx = RegEx.create_from_string("@\\d+")
	for n: Node in spike.find_children("*", "GeometryInstance3D", true, false):
		if n.is_queued_for_deletion():
			continue
		# 자동 이름(@MeshInstance3D@145)은 인스턴스마다 번호가 달라서 번호를 떼고, 같은 이름은 순번을 붙인다.
		var base: String = re.sub(str(spike.get_path_to(n)), "", true)
		var key: String = base
		var seq: int = 1
		while out.has(key):
			seq += 1
			key = "%s#%d" % [base, seq]
		out[key] = (n as GeometryInstance3D).cast_shadow
	return out


func test_e_differs_from_b_only_in_crowd_cast_shadow() -> void:
	var b: Dictionary = _shadow_map(_spawn("B"))
	var e: Dictionary = _shadow_map(_spawn("E"))
	assert_true(b.has("Crowd"), "B: Crowd 경로 존재")
	assert_eq(e.keys(), b.keys(), "E 와 B 의 지오메트리 노드 목록이 같다")
	var diff: PackedStringArray = PackedStringArray()
	for k: String in b:
		if e.has(k) and e[k] != b[k]:
			diff.append(k)
	assert_eq(diff, PackedStringArray(["Crowd"]), "cast_shadow 가 다른 노드는 Crowd 하나뿐: %s" % ", ".join(diff))
	assert_eq(b["Crowd"], GeometryInstance3D.SHADOW_CASTING_SETTING_ON, "B Crowd ON")
	assert_eq(e["Crowd"], GeometryInstance3D.SHADOW_CASTING_SETTING_OFF, "E Crowd OFF")
	# 캐스터가 남아 있다: E 에서 ON 인 노드가 무대 프록시 수만큼 있다(그리드 바닥 등은 별개).
	var on_in_e: int = 0
	for k: String in e:
		if str(k).begins_with("StageProps/") and e[k] == GeometryInstance3D.SHADOW_CASTING_SETTING_ON:
			on_in_e += 1
	assert_eq(on_in_e, _settings.stage_prop_count, "E: 셰도우를 드리우는 StageProps 노드 수")


## 박스 AABB(월드, 회전 박스라 꼭짓점 8개의 외접 AABB 로 보수적이 아닌 정확한 구-박스 판정은 못 하므로
## 박스 로컬 좌표로 구 중심을 옮겨 가장 가까운 점까지의 거리를 잰다).
func _dist_light_to_box(light_pos: Vector3, mi: MeshInstance3D) -> float:
	var half: Vector3 = mi.mesh.get_aabb().size * 0.5
	var local: Vector3 = mi.global_transform.affine_inverse() * light_pos
	var clamped: Vector3 = Vector3(clampf(local.x, -half.x, half.x), clampf(local.y, -half.y, half.y), clampf(local.z, -half.z, half.z))
	return (local - clamped).length()


func test_every_prop_stays_inside_a_shadow_omni_while_lights_move() -> void:
	var spike: SpikeCrowd = _spawn("E")
	var omnis: Array[OmniLight3D] = []
	for l: Light3D in spike.get_light_nodes():
		if l.shadow_enabled and l is OmniLight3D:
			omnis.append(l as OmniLight3D)
	assert_gt(omnis.size(), 0, "셰도우 Omni 가 있다(큐브 그림자는 방향과 무관)")
	for s: int in range(STEPS):
		for mi: MeshInstance3D in spike.get_stage_prop_nodes():
			var best: float = INF
			for o: OmniLight3D in omnis:
				best = minf(best, _dist_light_to_box(o.global_position, mi))
			var reach: float = omnis[0].omni_range
			assert_lte(best, reach, "t=%.1fs %s: 가장 가까운 셰도우 Omni 까지 %.2f m ≤ 범위 %.1f m" % [spike.get_elapsed_sec(), mi.name, best, reach])
		spike.advance(STEP_SEC)
	# 대조군: 군중 영역 밖으로 한참 떨어진 점은 어느 셰도우 Omni 에도 닿지 않는다(검사가 항상 참이 아님).
	var far: MeshInstance3D = spike.get_stage_prop_nodes()[0]
	var far_pos: Vector3 = omnis[0].global_position + Vector3(1000.0, 0.0, 0.0)
	assert_gt(_dist_light_to_box(far_pos, far), omnis[0].omni_range, "대조군: 멀리 있는 점은 범위 밖")


func test_config_arg_is_case_insensitive() -> void:
	assert_eq(SpikeCrowd.resolve_config_id("", PackedStringArray(["--config=e"]), "B"), "E")
	assert_eq(SpikeCrowd.resolve_config_id("B", PackedStringArray(["--config=e"]), "E"), "B", "@export 가 명령줄보다 우선")
	assert_eq(SpikeCrowd.resolve_config_id("", PackedStringArray(), "E"), "E", "둘 다 없으면 기본값")
