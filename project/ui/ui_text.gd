class_name UiText
extends RefCounted
## SE-039: UI 문자열 조회. 키 → 문장 템플릿(`{name}` 자리표시, String.format).
## 출처: res://data/text/ui_ko.json(SE-039 2차, game-designer) + artists_ko.json(SE-031, 바이오·성격 태그). 읽기만 한다.
## 1차 폴백(결정 b): 테이블에 키가 없으면 "키" 를, 값이 있으면 "키 값1 값2 …"(params 삽입 순서)를 그대로 보인다.
## 테스트는 from_strings 로 픽스처 사전을 주입한다(결정 a 병행). 코드에는 한국어 리터럴을 두지 않는다(AC7).

const UI_PATH: String = "res://data/text/ui_ko.json"
const ARTISTS_PATH: String = "res://data/text/artists_ko.json"
const STRINGS_KEY: String = "strings"
const FALLBACK_SEP: String = " "

var _strings: Dictionary = {}


## 기본 테이블을 읽는다. 파일이 없으면(2차 전) 그 파일만 건너뛴다(폴백 표시).
static func load_default(paths: PackedStringArray = PackedStringArray([UI_PATH, ARTISTS_PATH])) -> UiText:
	var t: UiText = UiText.new()
	for p: String in paths:
		var d: Variant = UiData.read_json(p, true)
		if d is Dictionary and (d as Dictionary).get(STRINGS_KEY) is Dictionary:
			t._strings.merge((d as Dictionary)[STRINGS_KEY], true)
	return t


## 픽스처 사전 주입(테스트·프리셋).
static func from_strings(strings: Dictionary) -> UiText:
	var t: UiText = UiText.new()
	t._strings = strings.duplicate(true)
	return t


func has_key(key: String) -> bool:
	return _strings.has(key)


## 키 → 표시 문자열. 없는 키는 폴백(위 설명).
func t(key: String, params: Dictionary = {}) -> String:
	if _strings.has(key):
		return str(_strings[key]).format(params)
	if params.is_empty():
		return key
	var parts: PackedStringArray = PackedStringArray([key])
	for k: Variant in params:
		parts.append(str(params[k]))
	return FALLBACK_SEP.join(parts)


## 하위 키 하나를 붙인 조회(예: reason 문자열). 접두어 + "." + id.
func sub(prefix: String, id: Variant, params: Dictionary = {}) -> String:
	return t("%s.%s" % [prefix, str(id)], params)
