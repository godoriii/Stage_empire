# glTF 임포트 규약 (GLTF_SPEC.md)

| 항목 | 값 |
|---|---|
| 상태 | v0 |
| 티켓 | SE-019 2차 (art-pipeline). 1차 규약: [`docs/gdd/materials.md`](../../docs/gdd/materials.md) (채택안 (b) 슬롯 = 별도 서피스) |
| 적용 대상 | 가구·설비·캐릭터 `.glb` 전부. 검수 큐(`project/assets/review-queue/<asset-id>/`)에 올리기 전에 이 규약을 통과해야 한다 |
| 구현 | 이 문서는 규약과 린터 체크리스트만 정한다. 린터(`tools/assets/lint_gltf.py`)는 후속 art-pipeline 티켓 |
| 근거 | `docs/style-guide.md` "포맷"·"폴리곤 예산"·"머티리얼 슬롯 이름"·"상태 변형" 행, `docs/gdd/materials.md` M1~M6·glass·Q5 |

이 문서와 `materials.md` 가 어긋나면 `materials.md` 가 이긴다(슬롯 이름 4종, 표기 방식 = 서피스). 어긋남을 발견하면 이 문서를 고치는 티켓을 낸다.

## 1. 포맷·단위·좌표·피벗

- **파일:** glTF 2.0 바이너리 `.glb` 한 파일. 외부 `.bin`·이미지 참조 금지. 압축 확장(Draco, meshopt)은 쓰지 않는다(린터가 버퍼를 직접 읽는다). `extensionsRequired` 는 비어 있어야 한다.
- **단위:** 미터. 1 타일 = 1 m. 스케일은 1.0(노드 `scale` 없음).
- **축:** +Y 업, -Z 전방(프로젝트 규약. glTF 2.0 기본 정면은 +Z 이므로 Blender 내보내기 '+Y Up' 설정만으로는 정면이 정해지지 않는다 — 모델을 -Z 를 향하게 두고 내보낸다).
- **피벗(원점):** 바닥 중심. 타일 점유 영역(`w×d`)의 중앙, y = 0. 메시 노드의 변환(translation / rotation / scale)은 항등이고 정점이 이 원점 기준으로 놓인다. AABB 가 `min.y = 0`, x·z 범위의 중심이 원점이어야 한다(허용 오차 기본 0.01 m, 린터 옵션).
- **풋프린트·높이:** 티켓의 `w×d`·높이를 `META.json` 에 적고, AABB 가 그 안(풋프린트 ± 허용 오차, 높이 ± 5%)이어야 한다.
- **삼각형만:** primitive `mode` 는 4(TRIANGLES). 점·선·스트립 금지.
- **노멀:** 모든 primitive 에 `NORMAL` 속성이 있어야 한다(외곽선 패스가 법선 방향 확장을 쓴다 — 시안 B, SE-018). 스무딩 방식(플랫/스무스)은 아트 디렉션 몫이라 여기서 정하지 않는다.

## 2. 머티리얼 이름 = 슬롯 이름

각 primitive(= Godot 서피스)의 머티리얼 `name` 은 아래 네 개 중 **정확히 하나**다. 소문자 ASCII, 완전 일치.

| 슬롯 | 필수 | 용도 |
|---|---|---|
| `base` | **필수** | 몸체 전부 |
| `accent` | 선택 | 장르 강조색·보조색 영역 |
| `emissive` | 선택 | 빛나는 면(켜짐/꺼짐으로 세기가 바뀐다) |
| `glass` | 선택 | 투명한 면. 캐릭터에는 금지(§8) |

- 서피스 하나에 슬롯 하나. 한 메시에 같은 슬롯은 서피스 1개(영역이 떨어져 있어도 한 primitive 로 합친다).
- 서피스 수는 1~4. `accent`·`emissive`·`glass` 서피스가 없는 에셋은 정상이다.
- glTF 머티리얼의 색·알파 모드는 **저작 미리보기용**이다(`baseColorFactor`, `emissiveFactor`, `glass` 는 `alphaMode: BLEND` 권장). 런타임 색은 슬롯 파라미터와 게임 데이터에서 온다(materials.md M4, Q1). 사실적 PBR 값(metallic·roughness)은 쓰지 않는다(기본값 유지).
- 같은 정점이라도 "무엇을 그리나"가 아니라 "어떤 파라미터로 칠하나"로 슬롯을 나눈다. 의자 다리와 등받이 프레임이 같은 색 출처면 둘 다 `base`.

## 3. 거부 규칙

아래는 전부 **거부**(린터 exit 1, 검수 큐 진입 불가). 메시지에는 파일 이름과 문제의 머티리얼 이름·primitive 번호를 넣는다.

| # | 거부 대상 | 예 | 메시지 예 |
|---|---|---|---|
| R1 | 슬롯 이름이 아닌 머티리얼 이름 | `metal`, `wood`, `Material` | `chair.glb: 머티리얼 'metal' 은 슬롯 이름이 아님 (base|accent|emissive|glass)` |
| R2 | 대소문자 변형 | `Base`, `ACCENT` | 〃 |
| R3 | DCC 접미 | `base.001`, `accent_1`, `glass.002`, `base ` (공백) | 〃 (Blender 가 이름 충돌 시 `.001` 을 붙인다) |
| R4 | 이름 없는 머티리얼 | `name` 키 없음 | `머티리얼 #2 이름 없음` |
| R5 | **머티리얼이 없는 primitive** | primitive 에 `material` 키 없음 | `메시 'X' primitive #4 머티리얼 없음` (이름 없는 primitive 는 슬롯을 알 수 없다) |
| R6 | `base` 서피스 없음 | `accent` 만 있음 | `base 슬롯 서피스 없음` |
| R7 | 같은 슬롯 서피스 2개 이상 | 같은 이름 머티리얼 2개, 또는 한 머티리얼을 primitive 2개가 공유 | `슬롯 'base' 서피스 2개 (primitive #0, #1)` |
| R8 | 서피스 5개 이상 | 슬롯이 4종이라 R1~R7 을 모두 통과하면 불가능하다. 린터는 총수 검사를 안전망으로 둔다 | `서피스 5개 (최대 4)` |

- Blender 작업 지침: 머티리얼 이름을 슬롯 이름으로 짓고, 이름 충돌로 `.001` 이 붙으면 지우고 같은 슬롯 안에서 한 머티리얼로 합친다. 같은 머티리얼을 쓰는 면은 한 슬롯에 몰아 넣는다.
- 미사용 머티리얼(어느 primitive 도 참조하지 않는 `materials[]` 항목)은 거부하지 않고 경고한다.

## 4. 정점 색

- 기본: `COLOR_0` 를 넣지 않는다.
- 있다면 **알파는 전부 1.0**(오차 1e-4). 아니면 거부(materials.md M1: 정점 알파는 의미 채널이 아니다).
- RGB 가 (1, 1, 1) 이 아니면 경고. RGB 는 `base` 서피스에만 곱해진다(M2)는 점을 메시지에 적는다.

## 5. 텍스처 0

`images`, `textures`, `samplers` 배열이 비어 있거나 없다. 머티리얼에 `baseColorTexture`·`normalTexture`·`emissiveTexture`·`occlusionTexture`·`metallicRoughnessTexture` 참조 금지. 이유: 플랫 컬러 + 툰 셰이더 룩, 사실적 텍스처 금지(style-guide "결정된 것").

## 6. 메시 노드 1개 (v0)

- 장면(`scenes[0]`)의 노드 중 메시를 가진 노드는 정확히 1개, `meshes[]` 도 1개. 빈 부모 노드·자식 노드 없음.
- `skins`, `animations` 는 v0 에서 비어 있다. 캐릭터 리그·애니메이션은 캐릭터 에셋 티켓에서 이 문서를 개정해 허용한다.
- 카메라·라이트 노드 금지.

## 7. 폴리곤 예산

`docs/style-guide.md` "폴리곤 예산" 행이 기준이다. 이 문서에 수치를 복사하지 않는다(행이 바뀌면 린터 설정만 바뀐다). 현재 행의 값: 가구 소형 ≤ 300 tri, 대형 설비 ≤ 1,500 tri, 캐릭터 ≤ 800 tri, 임포스터용 LOD1 ≤ 150 tri. 삼각형 수는 **모든 서피스의 합**이고, 카테고리는 티켓(→ `META.json`)에서 읽는다. LOD1 파일의 이름·슬롯 요구는 v0 에서 정하지 않았다(임시: 같은 규칙 적용, 린터 티켓에서 확정).

## 8. 캐릭터는 `glass` 금지

카테고리가 캐릭터(군중 인스턴싱 대상)인 에셋에는 `glass` 서피스를 두지 않는다(인스턴싱된 투명 정렬 비용 회피 — materials.md "glass"). `accent` 는 허용(Q2 추천안, 캐릭터 티켓에서 확정). `accent`·`emissive` 서피스는 군중 인스턴스 색을 받지 않는다(M3).

## 9. Godot 4.7.2 임포트 후 슬롯 이름 위치 (Q5 확인 결과)

**확인함(2026-10-09, Godot 4.7.2.stable, 헤드리스).** 표준 라이브러리만으로 만든 최소 `.glb`(쿼드 1개 = primitive 1개, 정점 법선 포함)를 두 경로로 읽어 확인했다. (1) `GLTFDocument.append_from_file` + `generate_scene`(임포터가 쓰는 같은 코드, 런타임 경로), (2) 빈 프로젝트에서 `godot --headless --import` 로 만든 `.scn` 캐시를 `load()` 해 `instantiate()`(에디터 임포트 경로). 두 경로의 결과가 같았다.

| 입력 glTF | 임포트 후 `MeshInstance3D.mesh`(ArrayMesh) |
|---|---|
| 머티리얼 `base` / `accent` / `emissive` / `glass` (primitive 4개) | 서피스 4개. 각 서피스에서 `surface_get_name(i)` 와 `surface_get_material(i).resource_name` 이 **둘 다** glTF 머티리얼 이름과 같다(`'base'`, `'accent'`, ...). 이름이 바뀌지 않는다 |
| `glass` 가 `alphaMode: BLEND`, `baseColorFactor.a = 0.4` | 머티리얼 `transparency = 4`(`TRANSPARENCY_ALPHA_DEPTH_PRE_PASS`). 런타임은 이 값을 쓰지 않고 glass 셰이더로 덮는다 |
| 머티리얼 `base.001`, `Accent`, `metal` | **이름 그대로** 남는다. Godot 이 접미를 떼거나 소문자로 바꾸지 않는다 → 접미·대소문자 거부는 Godot 이 아니라 린터의 몫이고, 런타임 판정은 완전 일치로 해야 한다 |
| `name` 없는 머티리얼(`materials[]` 의 세 번째) | 서피스 이름과 `resource_name` 이 **`'material_2'`**(`materials[]` 인덱스 기준 자동 이름). **빈 문자열이 아니다** |
| primitive 에 `material` 키 없음 | 서피스 이름 `''`, 머티리얼 `resource_name` `''`(머티리얼은 `null` 이 아니라 기본 머티리얼 객체였음) |
| 같은 이름 `base` 머티리얼 2개를 primitive 2개에 | 서피스 2개 모두 이름 `'base'`. 자동으로 `base_2` 같은 이름을 붙이지 않는다 → 중복 검출은 런타임/린터가 해야 한다 |
| 머티리얼 1개를 primitive 2개가 공유 | 서피스 2개 모두 이름 `'base'` (같은 결과) |
| `COLOR_0` 포함(알파 0.5) | 메시 배열 `ARRAY_COLOR` 에 남는다. 머티리얼 `vertex_color_use_as_albedo` 는 `false` (우리 셰이더가 `COLOR` 를 직접 읽으므로 무관) |

판정(R-B 와 런타임 판정 함수가 따를 것):

1. **슬롯 이름은 `ArrayMesh.surface_get_name(i)` 에서 읽는다.** `surface_get_material(i).resource_name` 은 같은 값이지만 서피스에 머티리얼이 붙어 있어야만 읽을 수 있고, 시안 적용 코드가 서피스 머티리얼을 덮어쓰기 시작하면 사라진다. 보조(fallback)로만 쓴다.
2. 판정 함수는 한 곳(`render` 쪽 한 함수)에 둔다. 입력 이름이 4종 중 하나면 그 슬롯, `''` 이면 `base`, 그 밖(`material_2` 같은 자동 이름, 접미, 대소문자 변형 포함)은 `base` + `push_warning` (materials.md "런타임 슬롯 판정"과 동일).
3. **materials.md 반영됨(02c3e87):** "이름이 없는 서피스 = `base`" 문장은 코드로 만든 프록시 메시에만 맞는다. 임포트된 `.glb` 의 이름 없는 머티리얼은 `'material_N'` 으로 들어와 슬롯 이름이 아닌 이름 취급이 된다(→ `base` + 경고). 린터가 R4 로 먼저 거부하므로 실제 에셋에서 문제가 되지 않는다.

**한계(확인 필요):**
- Blender 에서 실제 내보낸 `.glb` 는 확인하지 못했다(이 환경에 Blender 없음). Blender 가 이름 충돌 시 `.001` 을 붙이는 동작은 Blender 쪽 사실이고, 붙은 이름이 glTF 에 그대로 실린다는 점은 위 `base.001` 입력이 Godot 에서 보존됨으로 간접 확인했다. 첫 Blender 내보내기 에셋에서 재확인.
- 에디터 임포트 옵션을 기본값으로만 시험했다(머티리얼 추출·"Import as" 변경 시 이름이 어떻게 되는지는 미확인). 임포트 설정을 바꾸는 티켓이 생기면 재확인.
- `EditorScenePostImport` 스크립트가 받는 노드의 서피스 이름은 시험하지 않았다(`ImporterMesh` 단계). 후처리 스크립트를 쓰게 되면 재확인.

**재현 방법:**

```bash
python3 tools/assets/q5_probe/make_probe_glb.py <임시 디렉터리>/glb          # 5개 .glb 생성
mkdir -p <임시 프로젝트> && printf 'config_version=5\n[application]\nconfig/name="q5"\n' > <임시 프로젝트>/project.godot
# (1) 런타임 경로(GLTFDocument)
godot --headless --path <임시 프로젝트> -s <절대경로>/tools/assets/q5_probe/probe_import.gd -- <임시 디렉터리>/glb/slots4.glb
# (2) 에디터 임포트 경로: .glb 를 임시 프로젝트에 복사 -> 임포트 -> res:// 로 읽기
cp <임시 디렉터리>/glb/*.glb <임시 프로젝트>/ && godot --headless --path <임시 프로젝트> --import
godot --headless --path <임시 프로젝트> -s <절대경로>/tools/assets/q5_probe/probe_import.gd -- res://slots4.glb
```

저장소의 `project/` 는 건드리지 않는다(임시 프로젝트는 저장소 밖에 둔다).

## 10. 린터 체크리스트 (`tools/assets/lint_gltf.py`, 구현은 후속 티켓)

입력은 `.glb` 한 파일 + `META.json`(카테고리, 타일 점유, 높이). 표준 라이브러리만으로 glTF JSON 과 버퍼를 읽는다(헤드리스, Godot 불필요). 판정 수준: **거부**(exit 1) / 경고(exit 0, `lint.json` 에 기록). 결과는 `project/assets/review-queue/<asset-id>/lint.json` 에 항목 id 별로 남긴다.

| # | 항목 | 검사 | 수준 | 거부 규칙 |
|---|---|---|---|---|
| L1 | 머티리얼 이름 ∈ 4종 | 모든 primitive 의 `materials[idx].name` 이 `base`/`accent`/`emissive`/`glass` 와 완전 일치(접미·대소문자·이름 없음 포함) | 거부 | R1~R4 |
| L2 | `base` 존재 | 이름이 `base` 인 서피스가 있다 | 거부 | R6 |
| L3 | 슬롯 중복 없음 | 같은 슬롯 이름의 서피스(primitive)가 2개 이상이 아니다. 서피스 총수 1~4 | 거부 | R7, R8 |
| L4 | 머티리얼 없는 primitive 없음 | 모든 primitive 가 `material` 을 가진다 | 거부 | R5 |
| L5 | 정점 알파 = 1.0 | `COLOR_0` 가 있으면 모든 알파 = 1.0 ± 1e-4. RGB 가 흰색이 아니면 경고 | 거부(알파) / 경고(RGB) | §4 |
| L6 | 텍스처 0 | `images`·`textures`·`samplers` 0, 머티리얼 텍스처 참조 0 | 거부 | §5 |
| L7 | 메시 노드 1 | 메시를 가진 노드 1, `meshes[]` 1, 자식 노드 0, skins·animations 0 | 거부 | §6 |
| L8 | 삼각형 예산 | 서피스 합 tri ≤ style-guide 행의 카테고리 값(소형/대형/캐릭터/LOD1). 모든 primitive `mode = 4` | 거부(초과) | §7 |
| L9 | 피벗·스케일 | AABB `min.y` ≈ 0, x·z 중심 ≈ 0, 노드 변환 항등, AABB 가 `META.json` 풋프린트·높이 안(1 타일 = 1 m) | 거부 | §1 |
| L10 | 캐릭터 `glass` 없음 | `META.json` 카테고리가 캐릭터이면 `glass` 서피스 0 | 거부 | §8 |

덧붙임(10항목 밖, 린터 티켓이 채택 여부를 정한다): 모든 primitive 에 `NORMAL` 존재(§1), 미사용 머티리얼 경고(§3), `extensionsRequired` 비어 있음(§1).

픽스처(린터 티켓의 테스트 입력)는 `tools/assets/q5_probe/make_probe_glb.py` 가 만드는 `.glb` 로 시작할 수 있다: `slots4.glb`(통과), `bad_names.glb`(L1·L4), `dup_two_materials.glb`·`dup_shared_material.glb`(L3), `vertex_alpha.glb`(L5). 피벗·예산·텍스처·노드 수·캐릭터 glass 픽스처는 린터 티켓이 추가한다.

## 11. 생성 프롬프트 템플릿 수정안

현행(`docs/style-guide.md` 하단):

```
low-poly <object>, flat colors, no texture, clean topology, game asset, isometric-friendly,
single mesh, origin at bottom center, fits <w>x<d> meter footprint, height <h> m, <accent color> accent
```

수정안(메인 세션이 style-guide 에 적용):

```
low-poly <object>, flat colors, no texture, clean topology, game asset, isometric-friendly,
single mesh with material slots named exactly base, accent (optional), emissive (optional), glass (optional),
one surface per slot, no vertex colors, origin at bottom center, fits <w>x<d> meter footprint, height <h> m,
<accent color> accent on the accent slot only
```

- 이미지→3D 생성 도구는 이름 붙은 머티리얼 슬롯을 만들지 못하는 경우가 많다. 프롬프트의 슬롯 요구는 **요청**일 뿐이고 통과 여부는 린터(§10)가 정한다. 생성물이 슬롯을 갖지 못하면 art-pipeline 이 `BRIEF.md` 에 "영역 → 슬롯" 표(어느 면이 `base`/`accent`/`emissive`/`glass` 인가)를 적고 모델링 단계(Blender)에서 슬롯을 나눈다.
- 프롬프트에 `<accent color>` 의 실존 브랜드·로고·아티스트 연상 요소를 넣지 않는다(style-guide 금지 항목).

## 변경 이력

| 날짜 | 버전 | 티켓 | 내용 |
|---|---|---|---|
| 2026-10-09 | v0 | SE-019 | 신규. 슬롯 = 서피스 규약의 glTF 임포트 규약, Q5 Godot 4.7.2 확인(헤드리스), 린터 체크리스트 10항목 |
