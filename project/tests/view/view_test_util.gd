class_name ViewTestUtil
extends RefCounted
## project/tests/view 공용 헬퍼(테스트 파일 아님: test_ 접두어 없음).

const VIEWPORT_SIZE: Vector2i = Vector2i(1920, 1080)
const ISO_CAMERA_SCENE: String = "res://view/camera/iso_camera.tscn"
const SOURCE_ROOTS: Array[String] = ["res://view", "res://ui"]


## 1080p SubViewport 를 만들어 parent 에 붙인다. 헤드리스에서도 Camera3D 투영 수학은 이 크기를 쓴다.
static func make_viewport(parent: Node) -> SubViewport:
	var vp: SubViewport = SubViewport.new()
	vp.size = VIEWPORT_SIZE
	vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
	parent.add_child(vp)
	return vp


static func make_camera(parent: Node) -> IsoCamera:
	var cam: IsoCamera = (load(ISO_CAMERA_SCENE) as PackedScene).instantiate() as IsoCamera
	parent.add_child(cam)
	return cam


## 카메라 기저에서 (피치, 요)를 도 단위로. 요는 [0, 360).
static func camera_pitch_yaw_deg(cam: Camera3D) -> Vector2:
	var e: Vector3 = cam.global_transform.basis.get_euler(EULER_ORDER_YXZ)
	return Vector2(rad_to_deg(e.x), fposmod(rad_to_deg(e.y), 360.0))


## 두 각도(도)의 최소 차이 절댓값.
static func angle_diff_deg(a: float, b: float) -> float:
	return absf(wrapf(a - b, -180.0, 180.0))


static func read_json(path: String) -> Variant:
	var f: FileAccess = FileAccess.open(path, FileAccess.READ)
	if f == null:
		return null
	return JSON.parse_string(f.get_as_text())


## tiers.json 에서 직접 읽은 grid_size(GridDataLoader 와 독립적으로 검증하기 위해).
static func expected_grid_size(tier_id: String) -> int:
	var root: Dictionary = read_json("res://data/tiers/tiers.json")
	for row: Dictionary in root["rows"]:
		if row["id"] == tier_id:
			return int(row["grid_size"])
	return -1


static func expected_tile_size_m() -> float:
	var root: Dictionary = read_json("res://data/sim/sim.json")
	return float(root["tile_size_m"])


## SOURCE_ROOTS 아래 확장자가 ext 인 파일 경로 전부(재귀).
static func list_sources(roots: Array[String], ext: String) -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	for root: String in roots:
		_walk(root, ext, out)
	return out


static func _walk(dir_path: String, ext: String, out: PackedStringArray) -> void:
	var dir: DirAccess = DirAccess.open(dir_path)
	if dir == null:
		return
	for f: String in dir.get_files():
		if f.get_extension() == ext:
			out.append(dir_path.path_join(f))
	for d: String in dir.get_directories():
		_walk(dir_path.path_join(d), ext, out)


## 파일들에서 정규식에 걸리는 "경로:줄번호: 내용" 목록.
static func grep(paths: PackedStringArray, pattern: String, exclude_suffix: String = "") -> PackedStringArray:
	var re: RegEx = RegEx.create_from_string(pattern)
	var hits: PackedStringArray = PackedStringArray()
	for p: String in paths:
		if not exclude_suffix.is_empty() and p.ends_with(exclude_suffix):
			continue
		var lines: PackedStringArray = FileAccess.get_file_as_string(p).split("\n")
		for i: int in lines.size():
			if re.search(lines[i]) != null:
				hits.append("%s:%d: %s" % [p, i + 1, lines[i].strip_edges()])
	return hits
