class_name CrowdProxyMesh
extends RefCounted
## SE-038: 관객 캐릭터 프록시 메시 빌더(공유 모듈). SE-003 SpikeCrowd.build_proxy_mesh 에서 뺀 것이다 —
## 성능 스파이크(SpikeCrowd)와 실제 군중(CrowdView)이 같은 빌더를 쓴다(중복 구현 금지, SE-038 AC3).
## 캡슐 몸통 + 박스 머리 + 박스 팔 2개를 한 서피스(base)로 합친다(MultiMesh 드로우 1회).
## 피벗은 발 중심(y = 0, style-guide). 인스턴스 색은 정점 색(COLOR)으로 albedo 에 곱해진다(materials.md M3).
## 치수는 호출자가 리소스(.tres)에서 넘긴다. 이 파일에는 숫자 상수가 없다. 표시 전용.


static func build(body_radius_m: float, body_height_m: float, body_radial_segments: int, body_rings: int,
		head_size_m: float, arm_size_m: Vector3) -> ArrayMesh:
	var body: CapsuleMesh = CapsuleMesh.new()
	body.radius = body_radius_m
	body.height = body_height_m
	body.radial_segments = body_radial_segments
	body.rings = body_rings
	var head: BoxMesh = BoxMesh.new()
	head.size = Vector3.ONE * head_size_m
	var arm: BoxMesh = BoxMesh.new()
	arm.size = arm_size_m
	var st: SurfaceTool = SurfaceTool.new()
	st.append_from(body, 0, Transform3D(Basis.IDENTITY, Vector3(0.0, body_height_m * 0.5, 0.0)))
	st.append_from(head, 0, Transform3D(Basis.IDENTITY, Vector3(0.0, body_height_m + head_size_m * 0.5, 0.0)))
	var arm_x: float = body_radius_m + arm_size_m.x * 0.5
	var arm_y: float = body_height_m - body_radius_m - arm_size_m.y * 0.5
	st.append_from(arm, 0, Transform3D(Basis.IDENTITY, Vector3(-arm_x, arm_y, 0.0)))
	st.append_from(arm, 0, Transform3D(Basis.IDENTITY, Vector3(arm_x, arm_y, 0.0)))
	var mesh: ArrayMesh = st.commit()
	var mat: StandardMaterial3D = StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mesh.surface_set_material(0, mat)
	return mesh
