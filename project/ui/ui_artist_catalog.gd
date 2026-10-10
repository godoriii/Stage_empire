class_name UiArtistCatalog
extends RefCounted
## SE-039: 섭외 패널용 명단 읽기(sim 이 붙기 전 — 샌드박스·테스트). ArtistConfig 의 SE-033 인계 멤버와 같은 이름·반환형만
## 제공한다(artist_ids·artist·guarantee·unlock_reputation). SE-040 통합 때는 실제 ArtistConfig 를 같은 자리에 넣는다.
## 출처: artists.json rows(순서 그대로), artist.json grades[].unlock_reputation, economy.json guarantee_by_grade. 읽기만.

const ARTISTS_PATH: String = "res://data/artists/artists.json"
## 없는 등급의 개런티·임계(ArtistConfig 와 같은 규약).
const UNKNOWN: int = -1

var _ids: Array[String] = []
var _rows: Dictionary = {}
var _unlock: Dictionary = {}
var _guarantee: Dictionary = {}


static func load_default() -> UiArtistCatalog:
	return from_dicts(UiData.read_json(ARTISTS_PATH), UiData.read_json(UiData.ARTIST_PATH), UiData.read_json(UiData.ECONOMY_PATH))


static func from_dicts(artists: Variant, rules: Variant, economy: Variant) -> UiArtistCatalog:
	var c: UiArtistCatalog = UiArtistCatalog.new()
	for r: Dictionary in UiData._rows(artists, "rows"):
		var id: String = str(r.get("id", ""))
		c._ids.append(id)
		c._rows[id] = r.duplicate(true)
	for g: Dictionary in UiData._rows(rules, "grades"):
		c._unlock[str(g.get("id", ""))] = int(g.get("unlock_reputation", UNKNOWN))
	if economy is Dictionary and (economy as Dictionary).get("guarantee_by_grade") is Dictionary:
		var gb: Dictionary = (economy as Dictionary)["guarantee_by_grade"]
		for k: Variant in gb:
			c._guarantee[str(k)] = int(gb[k])
	return c


func artist_ids() -> Array[String]:
	return _ids.duplicate()


func artist(id: String) -> Dictionary:
	return (_rows.get(id, {}) as Dictionary).duplicate(true)


func guarantee(grade: String) -> int:
	return int(_guarantee.get(grade, UNKNOWN))


func unlock_reputation(grade: String) -> int:
	return int(_unlock.get(grade, UNKNOWN))
