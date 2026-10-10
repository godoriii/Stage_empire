extends SceneTree
## SE-042 봇 러너 (qa). 호출은 tools/bot/play_bot.sh 가 한다. 본체 로직은 bot_play.gd (class BotPlay).
##
##   godot --headless --path project -s res://tests/e2e/bot_runner.gd -- run   --policy <id> --seed-start <s> --seeds <n> --days <d> --out <part.json>
##   godot --headless --path project -s res://tests/e2e/bot_runner.gd -- merge --parts <dir> --out <result.json>
##
## run: 시드 구간 하나를 돌려 부분 결과(part) 파일을 쓴다(실행 시간 같은 비결정 값은 파일에 넣지 않고 stdout 에만 낸다).
## merge: parts 디렉터리의 *.json 을 시드 순서로 합쳐 결과 파일(SE-042.json 형식)을 쓴다.
## 종료 코드: 0 성공, 2 인자 오류, 3 실행 오류.

const EXIT_OK: int = 0
const EXIT_USAGE: int = 2
const EXIT_FAIL: int = 3


func _initialize() -> void:
	quit(_main(OS.get_cmdline_user_args()))


func _main(argv: PackedStringArray) -> int:
	if argv.is_empty():
		printerr("usage: -- run|merge ...")
		return EXIT_USAGE
	var opts: Dictionary = {}
	var i: int = 1
	while i < argv.size():
		if not argv[i].begins_with("--") or i + 1 >= argv.size():
			printerr("인자 오류: %s" % argv[i])
			return EXIT_USAGE
		opts[argv[i].trim_prefix("--")] = argv[i + 1]
		i += 2
	match argv[0]:
		"run":
			return _run(opts)
		"merge":
			return _merge(opts)
	printerr("알 수 없는 모드: %s" % argv[0])
	return EXIT_USAGE


func _run(o: Dictionary) -> int:
	for k: String in ["policy", "seeds", "days", "out"]:
		if not o.has(k):
			printerr("--%s 필요" % k)
			return EXIT_USAGE
	var id: String = o["policy"]
	var first: int = int(o.get("seed-start", "1"))
	var count: int = int(o["seeds"])
	var days: int = int(o["days"])
	if count < 1 or days < 1:
		printerr("--seeds, --days 는 1 이상")
		return EXIT_USAGE
	var policy: Dictionary = BotPlay.load_policy(id)
	if policy.is_empty() or policy.get("id") != id:
		printerr("정책 파일을 읽지 못했다: %s" % id)
		return EXIT_USAGE
	var configs: Dictionary = GameSession.load_configs()
	var data: Dictionary = BotPlay.load_data()
	var runs: Array = []
	var t0: int = Time.get_ticks_msec()
	for sd: int in range(first, first + count):
		var r: Dictionary = BotPlay.play_game(policy, sd, days, configs, data)
		if r.is_empty():
			return EXIT_FAIL
		runs.append(r)
		print("[bot] %s seed %d: bankrupt_day=%s final_cash=%d final_rep=%d (%.1f s elapsed)" % [
			id, sd, str(r["bankrupt_day"]), r["final_cash"], r["final_rep"], (Time.get_ticks_msec() - t0) / 1000.0])
	var part: Dictionary = {
		"ticket": BotPlay.TICKET, "policy": id, "days": days, "first_seed": first, "count": count,
		"policy_file_sha1": BotPlay.policy_sha1(id), "runs": runs,
	}
	return _write(o["out"], BotPlay.to_json(part))


func _merge(o: Dictionary) -> int:
	for k: String in ["parts", "out"]:
		if not o.has(k):
			printerr("--%s 필요" % k)
			return EXIT_USAGE
	var parts: Array = []
	var dir: DirAccess = DirAccess.open(o["parts"])
	if dir == null:
		printerr("parts 디렉터리를 열 수 없다: %s" % o["parts"])
		return EXIT_USAGE
	var files: Array = Array(dir.get_files())
	files.sort()
	for f: String in files:
		if f.ends_with(".json"):
			var v: Variant = JsonUtil.int_deep(JSON.parse_string(FileAccess.get_file_as_string(String(o["parts"]).path_join(f))))
			if v is Dictionary and v.has("policy") and v.has("runs"):
				parts.append(v)
	var targets: Variant = BotPlay.read_json(BotPlay.TARGETS_FILE)
	if not (targets is Dictionary):
		return EXIT_FAIL
	var res: Dictionary = BotPlay.merge_parts(parts, targets)
	if res.is_empty():
		return EXIT_FAIL
	return _write(o["out"], BotPlay.to_json(res))


func _write(path: String, text: String) -> int:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		printerr("쓰기 실패: %s" % path)
		return EXIT_FAIL
	f.store_string(text)
	f.close()
	return EXIT_OK
