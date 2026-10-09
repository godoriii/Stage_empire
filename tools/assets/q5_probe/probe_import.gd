# SE-019 Q5 확인 스크립트. 사용:
#   godot --headless --path <빈 Godot 프로젝트 디렉터리> -s <이 파일> -- <a.glb> [<b.glb> ...]
# 인자가 파일 시스템 경로면 GLTFDocument 로 직접 읽고(런타임 경로), "res://" 로 시작하면
# 에디터 임포트(`godot --headless --import` 로 만든 .scn 캐시)를 PackedScene 으로 읽어
# 서피스 이름·머티리얼 resource_name·COLOR 배열 유무를 출력한다.
extends SceneTree


func _q(s: Variant) -> String:
	return "'" + str(s) + "'"


func _dump(n: Node, ind: String) -> void:
	print(ind, n.get_class(), " ", _q(n.name))
	if n is ImporterMeshInstance3D:
		var im: ImporterMesh = n.mesh
		for i in im.get_surface_count():
			var mat: Material = im.get_surface_material(i)
			print(ind, "  ImporterMesh surf ", i, " surface_name=", _q(im.get_surface_name(i)),
				" material.resource_name=", (_q(mat.resource_name) if mat else "null"))
	if n is MeshInstance3D and n.mesh:
		var mesh: Mesh = n.mesh
		for i in mesh.get_surface_count():
			var mat: Material = mesh.surface_get_material(i)
			var sname: String = ""
			if mesh is ArrayMesh:
				sname = (mesh as ArrayMesh).surface_get_name(i)
			var extra := ""
			if mat is BaseMaterial3D:
				extra = " transparency=" + str(mat.transparency) + " vertex_color_use_as_albedo=" + str(mat.vertex_color_use_as_albedo)
			var arrays: Array = mesh.surface_get_arrays(i)
			extra += " has_COLOR=" + str(arrays[Mesh.ARRAY_COLOR] != null)
			print(ind, "  Mesh surf ", i, " surface_name=", _q(sname),
				" material.resource_name=", (_q(mat.resource_name) if mat else "null"), extra)
	for c in n.get_children():
		_dump(c, ind + "  ")


func _init() -> void:
	for f in OS.get_cmdline_user_args():
		print("== ", f.get_file())
		if f.begins_with("res://"):
			var ps: PackedScene = load(f)
			var inst: Node = ps.instantiate()
			_dump(inst, "")
			inst.free()
			continue
		var doc := GLTFDocument.new()
		var st := GLTFState.new()
		var err: int = doc.append_from_file(f, st)
		print("append_from_file err=", err)
		if err != OK:
			continue
		var root: Node = doc.generate_scene(st)
		_dump(root, "")
		root.free()
	quit()
