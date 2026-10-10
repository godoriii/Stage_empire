class_name FakeArtistSystem
extends RefCounted
## SE-039 테스트용 가짜 ArtistSystem(읽기 전용 멤버 roster·entry·check_book 만). 호출 기록을 남긴다.

var reason_by_id: Dictionary = {}
var rows: Array = []
var calls: PackedStringArray = PackedStringArray()


func roster() -> Array:
	calls.append("roster")
	return rows.duplicate(true)


func entry(id: String) -> Dictionary:
	calls.append("entry")
	for r: Dictionary in rows:
		if r.get("id") == id:
			return r.duplicate(true)
	return {}


func check_book(id: Variant) -> String:
	calls.append("check_book")
	return str(reason_by_id.get(id, ""))
