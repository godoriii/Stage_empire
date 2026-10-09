# 머티리얼 슬롯·에셋 규약 (materials.md)

| 항목 | 값 |
|---|---|
| 상태 | v0 |
| 스펙 티켓 | SE-019 (game-designer 1차: 이 문서 / art-pipeline 2차: [`tools/assets/GLTF_SPEC.md`](../../tools/assets/GLTF_SPEC.md) / 메인 세션: `docs/style-guide.md` "머티리얼 슬롯 이름" 행) |
| 구현 티켓 | 후속 render-engineer 티켓 2개(아래 "부록 A. 현 구현 일치 판정"의 R-A·R-B, producer 발행), 후속 art-pipeline 티켓(glTF 린터 `tools/assets/lint_gltf.py`) |
| 데이터 | 없음. `project/data/` 변경 0. 슬롯 색을 가구 테이블에 둘지는 열린 질문 Q1 |
| 이벤트 | 없음(표시 전용 규약. 시뮬레이션 상태·이벤트 버스와 무관) |
| 난수 | 없음. 이 규약의 어느 단계도 난수를 쓰지 않는다 |
| 근거 | `docs/style-guide.md` "머티리얼 슬롯 이름"·"상태 변형"·"포맷"·"폴리곤 예산" 행, [docs/reviews/SE-004.md](../reviews/SE-004.md) 판단 5·후속 A, [docs/reports/SE-004.md](../reports/SE-004.md) "리뷰어에게" 5·비용 표, `project/view/shaders/toon.gdshader:5-7, 29, 40-42`, `project/view/shaders/shader_variants.gd:73-74`, `project/view/perf/spike_crowd.gd:211-232, 298-306` |

절 순서는 SE-019 AC1 을 따른다: 목적 → 규칙 → 비교표 → 채택안·근거 → 부속 규약 → glass → 룩 영향 없음 → 열린 질문. 일반 GDD 형식의 수용 기준·테스트 방법과 현 구현 일치 판정은 열린 질문 뒤 부록 A~C 에 둔다.

## 목적

가구·설비·캐릭터 모델이 네 머티리얼 슬롯(`base`/`accent`/`emissive`/`glass`)을 **어디에 어떻게 표기하는지**를 하나로 고정한다.
지금 `toon.gdshader:40-42` 는 "정점 알파가 0 인 곳 = accent" 라는 암묵 규약(SE-004 프로토타입)을 쓴다. 이는 (1) glTF 임포트에서 정점 알파를 의미 채널로 만들고, (2) 투명 `glass` 슬롯과 충돌하며, (3) 군중 MultiMesh 인스턴스 색의 알파가 1 미만이면 accent 로 오인된다(SE-004 리뷰 판단 5, qa "리뷰어에게" 5).

이 문서는 규약만 정한다. 셰이더·적용 코드 변경은 후속 render 티켓(부록 A), glTF 린터는 후속 art-pipeline 티켓이다. 팔레트(슬롯에 들어갈 실제 색)와 폴리곤 예산 확정은 별도 티켓이다.

## 규칙

### 슬롯 4종

| 슬롯 | 필수 | 용도(예) | 셰이딩 | 색 출처(이 슬롯 서피스가 읽는 파라미터) | 정점 색·인스턴스 색 |
|---|---|---|---|---|---|
| `base` | **필수**(모든 메시에 서피스 1개) | 몸체 전부. 바 카운터 상판·몸통, 의자 프레임, 캐릭터 피부·옷 | 툰(셀 + 림) + 외곽선 | `base_color` | **곱한다**: `COLOR.rgb`(정점 색 × MultiMesh 인스턴스 색). 알파는 무시 |
| `accent` | 선택 | 장르 강조색·보조색 영역. 쿠션, 테두리 띠, 스피커 그릴, 캐릭터 모자·소품 | 툰 + 외곽선 | `accent_color` | 곱하지 않는다 |
| `emissive` | 선택 | 빛나는 면. 램프 갓 안쪽, LED 패널, 앰프 표시등, 냉장고 조명 | 툰 + 외곽선, 추가로 발광 | 표면색 `emissive_color`, 발광 `emissive_color × emissive_energy`(0 = 꺼짐) | 곱하지 않는다 |
| `glass` | 선택 | 투명한 면. 창, 음료 냉장고 문, 부스 칸막이 유리 | 알파 블렌드, 외곽선 없음, 그림자 없음(아래 "glass") | `glass_color`(rgb = 색, a = 불투명도) — 새 파라미터, 후속 glass 셰이더 티켓 | 곱하지 않는다 |

- 슬롯 이름은 정확히 위 네 개(소문자 ASCII)다. 다른 이름은 없다(대소문자 변형, `base.001` 같은 DCC 접미, `metal`·`wood` 같은 재질 이름 전부 불가).
- 슬롯은 "무엇을 그리나"가 아니라 "어떤 파라미터로 칠하나"다. 같은 오브젝트의 두 영역이 같은 색 출처를 쓰면 같은 슬롯에 넣는다(예: 의자 다리와 등받이 프레임 = 둘 다 `base`).
- 한 메시에 같은 슬롯은 최대 1개 서피스다(같은 슬롯 영역이 떨어져 있어도 한 서피스로 합친다. 드로우콜 상한 = 4).
- 툰 셰이더 룩 파라미터(`cell_steps`·`shadow_tint`·`rim_*`)와 외곽선 파라미터(`outline_px`·`outline_color`)는 슬롯과 무관하게 시안(`toon_<id>.tres`·`outline_<id>.tres`) 하나에서 온다. 슬롯마다 룩 상수를 따로 두지 않는다.

### 상태 변형과의 관계

style-guide "상태 변형" 행(기본/켜짐/고장/철거중 — 머티리얼 또는 이미시브 변화로, 별도 메시 금지)과 같은 원칙이다. 상태는 **슬롯 파라미터 값**으로만 바뀌고 메시·서피스 구성은 바뀌지 않는다. 아래 표는 "어느 슬롯의 어느 파라미터가 움직이나"만 정한다. 실제 색·세기 값은 팔레트 티켓 몫이다(Q3).

| 상태 | `base` | `accent` | `emissive` | `glass` |
|---|---|---|---|---|
| 기본(설치됨, 꺼짐) | 오브젝트 정의 색 | 오브젝트 정의 색 | `emissive_energy` = 0 | 정의 색·불투명도 |
| 켜짐(가동 중) | 그대로 | 그대로 | `emissive_energy` > 0 | 그대로 |
| 고장 | 고장 틴트(오브젝트 단위 곱) | 고장 틴트 | `emissive_energy` = 0 또는 점멸 | 그대로 |
| 철거중 | 철거 틴트(오브젝트 단위 곱) | 철거 틴트 | `emissive_energy` = 0 | 철거 틴트 |

- `emissive` 서피스가 없는 오브젝트는 켜짐/꺼짐이 화면 색으로 보이지 않는다(UI 아이콘 등 다른 수단 — 빌드 UX 티켓 몫).
- 틴트·점멸은 오브젝트 단위 인스턴스 파라미터다("부속 규약" 복제 금지). 점멸 주기는 렌더 시간(보간)으로 그리며 게임 상태를 바꾸지 않는다.

### 런타임 슬롯 판정

- 메시 서피스의 슬롯 = 그 서피스의 이름이다. Godot 4.7.2 glTF 임포트(에디터 임포트·`GLTFDocument` 런타임 경로 모두)는 glTF 머티리얼 `name` 을 `ArrayMesh.surface_get_name(i)` 와 `surface_get_material(i).resource_name` **둘 다**에 그대로 남긴다. 접미(`base.001`)·대소문자(`Accent`)·중복(`base` 2개)을 보존하고 정규화하지 않는다(확인: [GLTF_SPEC.md §9](../../tools/assets/GLTF_SPEC.md), SE-019 2차).
- 판정 순서: ① `surface_get_name(i)` 를 읽는다(우선). ② 그것이 `''` 이고 서피스 머티리얼이 있으면 `surface_get_material(i).resource_name` 을 읽는다(보조 — 시안 적용 코드가 서피스 머티리얼을 덮어쓰면 사라지므로 우선 기준으로 쓰지 않는다). ③ 얻은 이름을 **완전 일치**로 4종과 비교한다.
- 판정 결과: 4종 중 하나 → 그 슬롯. `''` → `base`. 그 밖의 이름 → `base` + `push_warning`.
- `''` 이 나오는 경우는 둘뿐이다: 코드로 만든 프록시 메시(`CapsuleMesh`·`BoxMesh`·`SurfaceTool` 결과, 스파이크 군중 `build_proxy_mesh`)와 glTF 에서 `material` 키가 없는 primitive. 그래서 현 프로토타입 메시는 전부 `base` 단일 서피스다.
- **임포트 에셋의 이름 없는 머티리얼은 `''` 이 아니다.** `name` 이 없는 glTF 머티리얼은 `material_<materials[] 인덱스>`(예: `material_2`)라는 자동 이름으로 들어오므로 "슬롯 이름이 아닌 이름" 경로(`base` + `push_warning`)로 간다. 실제 에셋에서는 린터 R4(이름 없는 머티리얼 거부)가 임포트 전에 먼저 막는다. 런타임 경고를 만나는 것은 린터를 거치지 않은 에셋(접미·대소문자 변형·자동 이름 `material_<n>`)뿐이다. `material` 키 없는 primitive 는 `''` 이라 경고 없이 `base` 가 되므로 린터(GLTF_SPEC 의 머티리얼 없는 primitive 거부)만이 막는다.
- 이 판정은 render 쪽 **한 함수에 모은다**(R-B). 시안 적용·인스턴스 파라미터·테스트가 모두 그 함수만 부른다. 슬롯 중복(같은 이름 서피스 2개)은 Godot 이 자동으로 구분하지 않으므로 린터가 거부하고, 런타임은 두 서피스를 같은 슬롯으로 칠한다(경고 없음 — 색 결과가 같으므로).

## 비교표 — accent(그리고 나머지 슬롯) 표기 방식 3안

드로우콜 식: 오브젝트 1개의 메인 패스 드로우 = 서피스 수 `k`, 외곽선 패스 = `glass` 를 뺀 서피스 수, 그림자를 드리우는 오브젝트는 그림자 패스마다 `glass` 를 뺀 서피스 수. MultiMesh(군중)는 인스턴스 수와 무관하게 "서피스 수"만큼이다. 삼각형 수(primitives)는 세 안 모두 같다(같은 메시를 나눌 뿐).

| 열 | (a) 정점 알파 0 = accent (현행) | **(b) 슬롯 = 별도 서피스** | (c) UV2.x 에 슬롯 id 인코딩 (단일 서피스) |
|---|---|---|---|
| 1. glTF·Blender 표준 워크플로 호환 | 낮음. Blender 는 색 속성 알파를 칠해야 하고 내보내기 설정(색 속성 포함 여부·선형/sRGB)에 따라 알파가 빠지거나 바뀐다. 이미지→3D 생성 도구는 정점 알파를 의미 있게 만들지 않는다 | **높음.** Blender 머티리얼 슬롯 = glTF primitive 의 머티리얼 = Godot 서피스. 아티스트·생성 파이프라인이 "머티리얼 이름 붙이기"만 하면 된다 | 낮음. 면마다 상수 UV 값을 가진 두 번째 UV 맵을 손으로(또는 스크립트로) 만들어야 한다. 표준 도구의 의미와 다르다 |
| 2. 생성 에셋 린터로 검사 가능 | 부분적. "알파 ∈ {0, 1}"은 검사 가능하지만 "의도한 영역이 accent 인가"는 검사 불가. 보간 경계(삼각형 안 알파 0~1 섞임)도 생긴다 | **쉬움.** "머티리얼 이름 ∈ 4종, `base` 존재, 중복 없음" — glTF JSON 만 읽으면 된다(메시 버퍼 해석 불필요) | 가능하지만 무겁다. 버퍼를 디코드해 TEXCOORD_1.x 가 삼각형마다 상수이고 정수 0~3 인지 봐야 한다 |
| 3. 드로우콜(서피스 수) | 1 (+ 외곽선 1) | `k`(가구 소형 2~3) + 외곽선 `k − glass`. 군중 MultiMesh 는 서피스 수만큼(인스턴스 5,000 이어도 +1~2) | 1 (+ 외곽선 1) |
| 4. 군중 MultiMesh 인스턴스 색(`COLOR`) 충돌 | **충돌.** 인스턴스 색이 `COLOR` 에 곱해져 들어오므로 인스턴스 알파 < 1 이면 그만큼 accent 로 칠해진다(현재는 `crowd_palette` 알파가 전부 1 이라 우연히 안전) | **없음.** 슬롯은 서피스가 정하고 `COLOR.a` 는 어디서도 읽지 않는다 | 없음(UV2 는 `COLOR` 와 별개) |
| 5. `glass` 투명 패스 분리 | **불가.** 알파가 이미 마스크라 투명도로 쓸 수 없고, 단일 서피스라 불투명/투명 패스를 나눌 수 없다 | **저절로 분리.** `glass` 서피스에만 투명 머티리얼을 붙인다 | 불가. 단일 서피스는 한 머티리얼 = 한 패스라 일부만 투명하게 그릴 수 없다(전체를 투명 패스로 보내면 정렬·깊이 문제) |
| 6. 외곽선 패스(`next_pass`)와의 관계 | 메시 전체에 외곽선. glass 영역 제외 불가 | 서피스별 머티리얼이라 `glass` 머티리얼만 `next_pass` 를 안 붙이면 된다. 불투명 서피스들의 헐 합은 전체 메시 헐과 같아(같은 정점·법선) 외곽선 화면 결과 동일 | 메시 전체에 외곽선. glass 제외하려면 외곽선 셰이더도 UV2 를 읽어 버려야 하고, 그래도 투명 패스는 못 만든다 |
| 7. 툰 셰이더 변경 필요 | 없음(현행). 단 4슬롯 중 2개(base/accent)만 표현된다 | 작음: `:40-41` accent 알파 분기 삭제 + 슬롯별 색 선택(R-A/R-B). glass 는 새 셰이더 | 큼: UV2 디코드 + 슬롯별 색 분기, 외곽선 셰이더도 수정 |
| 8. 표현 가능한 슬롯 수 | 2(알파 0/1). 4슬롯은 알파 단계(0, ⅓, ⅔, 1) 같은 깨지기 쉬운 인코딩이 필요 | 4(필요하면 늘릴 수 있음) | 4 |
| 9. 다른 Godot 기능과의 충돌 | 정점 알파를 쓰는 기능(투명 정점 색)과 겹침 | 없음 | **UV2 는 Godot 의 라이트맵(LightmapGI) UV 채널.** 임포트 시 "Lightmap UV 생성"을 켜면 덮어쓴다. 지금 라이트맵 계획은 없지만 채널을 선점한다 |
| 10. 다른 안으로의 변환 | (b)/(c) 로 가려면 영역을 사람이 다시 나눠야 한다(정보 부족) | **정보 손실 없음.** 임포트 스크립트로 불투명 서피스를 합쳐 (c) 형태로 기계 변환 가능 | (b) 로 기계 변환 가능 |

## 채택안·근거

**채택: (b) 슬롯 = 별도 서피스.** glTF 머티리얼 이름 = 슬롯 이름, 메시 서피스 하나당 슬롯 하나. producer 추천 초안과 같다. game-designer 는 반박할 수치 근거를 찾지 못했다(아래 비용 추정).

근거:

1. **4슬롯을 전부 표현하는 안 중 표준 워크플로와 맞는 유일한 안.** (a) 는 슬롯 2개만, (c) 는 비표준 UV 작업이 필요하다. (b) 는 Blender 머티리얼 슬롯·glTF primitive·Godot 서피스가 1:1 이라 아티스트와 생성 파이프라인 모두 "머티리얼 이름 붙이기"만 한다.
2. **린터가 가장 싸고 확실하다.** glTF JSON 의 `materials[].name` 과 `meshes[].primitives[].material` 만 보면 되고, 실패 메시지가 사람이 고칠 수 있는 형태("머티리얼 'Metal' 은 슬롯 이름이 아님")다.
3. **`glass` 가 저절로 분리된다.** 투명 머티리얼, `next_pass` 없음, 그림자 off 를 서피스 단위로 붙인다. (a)·(c) 는 단일 서피스라 원리적으로 불가.
4. **정점 알파·인스턴스 알파를 의미 채널로 쓰지 않는다.** 군중 색·투명과의 충돌이 0 이 된다(SE-004 판단 5 해소).
5. **결정을 나중에 뒤집기 가장 싸다.** (b) 는 정보가 가장 많은 저장 형식이라 (c) 로의 변환이 기계적이다(비교표 10행). 반대 방향은 수작업이다.

비용 추정(드로우콜 — 반박 근거가 되는지 확인한 값):

| 장면 | 가정 | (a)/(c) 메인+외곽선 | (b) 메인+외곽선 | 증가 |
|---|---|---|---|---|
| 티어 1 클럽(24×24) | 오브젝트 300, 평균 서피스 `k̄` = 2.5, 오브젝트당 glass 0.2 | 300 + 300 = 600 | 750 + 690 = 1,440 | +840 |
| 군중 MultiMesh(관문 E 규모 5,000) | 캐릭터 서피스 2(`base` + `accent`), glass 0 | 1 + 1 = 2 | 2 + 2 = 4 | +2 |

- 오브젝트 300 은 24×24 = 576 타일에 가구를 빽빽이 채운 상한 쪽 가정이다(티켓의 "수백"). 그림자를 드리우는 가구는 그림자 패스마다 서피스 수만큼 더 든다.
- 참고 실측: SE-004 비용 표에서 오브젝트 41개 추가(+32 draw calls, 69 → 101) 시 비용은 거의 전부 외곽선 primitives ×2 였고(GPU 쪽), draw call 수 자체가 병목이라는 증거는 없었다(M1 70.5 fps, 관문 30). (b) 는 primitives 를 늘리지 않는다.
- 판단: 티어 1 은 수용한다(드로우콜 1,440 + 그림자 패스는 데스크톱 Forward+ 에서 병목이 될 규모가 아니라고 본다 — **추정, 미측정**). 티어 4~6(400×400, 오브젝트 수천)에서 드로우콜이 문제가 되면 첫 대응은 (c) 로 바꾸는 것이 아니라 "같은 가구 종류 × 서피스"를 청크(32×32)별 MultiMesh 로 묶는 것이다. 그러면 드로우콜은 오브젝트 수가 아니라 (청크 수 × 종류 수 × 서피스 수)에 비례한다. 측정은 Q4.

대안이 진 이유 한 줄씩:
- (a) 정점 알파: 슬롯 2개만 표현, glass 와 원리적 충돌, 군중 인스턴스 알파 오인. 현행이라 셰이더 변경 0 이 유일한 장점이다.
- (c) UV2: 드로우콜 1 이 유일한 장점. 비표준 저작, 무거운 린터, glass 분리 불가, 라이트맵 채널 선점. 드로우콜 이점은 (b) 저장 + 임포트 시 변환으로도 얻을 수 있다.

**뒤집는 방법.** 다음 조건이 측정으로 확인되면 (b) 를 "저장 형식"으로 유지한 채 임포트 단계에서 불투명 슬롯을 (c) 형태로 합치는 안을 producer 에게 제안한다(저작 규약·GLTF_SPEC 은 그대로): 대표 장면 성능 측정(Q4)에서 (b) 로 평균 fps 가 관문 기준 아래이고 측정기의 `bound_hint` 가 `cpu`(드로우·패스 준비 쪽)이며 청크 MultiMesh 묶음으로도 기준을 넘지 못할 때. 저작 규약 자체를 (a)/(c) 로 바꾸려면 이 문서 개정(v1) + GLTF_SPEC 개정 + 린터 개정 + 기존 에셋 재내보내기가 필요하고, producer 결정 로그에 남긴다(ADR 대상 아님: CLAUDE.md "결정된 사항"에 슬롯 표기 방식은 없다).

## 부속 규약

| # | 규약 |
|---|---|
| M1 | **정점 알파는 의미가 없다.** 셰이더는 `COLOR.a` 를 어디서도 읽지 않는다. 에셋의 정점 색은 넣지 않는 것이 기본이고, 넣는다면 알파는 1.0 이어야 한다(린터: 1.0 이 아니면 거부) |
| M2 | **정점 색 RGB 는 `base` 슬롯에서만 곱한다.** 기본(정점 색 없음)은 흰색(1, 1, 1)이라 영향이 없다. glTF 에셋에 RGB 정점 색을 넣는 것은 권장하지 않는다(린터: 경고). 코드로 만든 프록시의 정점 색(SE-004 이전 `plain` 룩)은 이 규칙으로 계속 보인다 |
| M3 | **군중 MultiMesh 인스턴스 색**은 `use_colors = true` 로 넣고 `COLOR.rgb` 로 `base` 서피스에만 곱해진다. 인스턴스 색 알파는 항상 1.0 으로 쓴다(`spike_crowd.gd:302` 의 `c.a` 자리는 1.0). 알파가 1 이 아니어도 결과는 같다(M1) — 1.0 은 의미 없는 채널을 고정해 두는 관례다. `accent`·`emissive`·`glass` 서피스는 인스턴스 색을 받지 않는다(옷 색은 바뀌어도 모자 강조색·발광은 그대로) |
| M4 | **슬롯별 색은 그 서피스 머티리얼의 파라미터에서 온다.** `base` → `base_color`, `accent` → `accent_color`, `emissive` → `emissive_color`·`emissive_energy`, `glass` → `glass_color`. 한 서피스는 자기 슬롯의 파라미터만 읽는다(예: `base` 서피스는 `emissive_energy` 를 쓰지 않는다 — 현 `toon.gdshader:43` 은 모든 서피스에 발광을 더하므로 R-B 에서 슬롯별로 나뉜다) |
| M5 | **오브젝트별 색 변형은 머티리얼 복제가 아니라 인스턴스 파라미터로 한다(복제 금지).** 같은 시안·같은 슬롯의 머티리얼 리소스는 장면 전체에서 1개를 공유한다. 바 카운터 A 는 빨강 accent, B 는 파랑 accent 여도 `accent` 머티리얼은 하나이고 색 차이는 오브젝트 단위 파라미터다. 군중은 M3 의 인스턴스 색이 그 역할을 한다. 구현 방식(Godot 인스턴스 uniform, MultiMesh 커스텀 데이터 등)은 R-B 가 정한다. 이유: 복제는 시안 전환(`ShaderVariants.apply`)·룩 상수 일원화(`toon_<id>.tres` 한 곳)를 깨고, 머티리얼 수만큼 파이프라인 상태 전환이 는다 |
| M6 | 상태 변형(켜짐/고장/철거중)도 M5 의 오브젝트 단위 파라미터로 표현한다. 메시 교체·서피스 추가 금지(style-guide "상태 변형" 행) |

## glass

`glass` 서피스는 **알파 블렌드 투명**(`glass_color.a` = 불투명도)으로 그리고, **외곽선 `next_pass` 를 붙이지 않으며**, **그림자를 드리우지 않는다.** 투명 면에 역면 헐 외곽선을 그리면 유리 뒤 물체 위에 검은 테가 겹쳐 보이고, 투명 면이 불투명 그림자를 드리우면 창으로 들어오는 무대 조명이 가려지기 때문이다. 셀 셰이딩·림은 다른 슬롯과 같은 시안 상수를 쓰되(유리도 무대 조명 색을 받는다) 깊이는 쓰지 않는 쪽을 기본으로 한다(투명 정렬은 Godot 기본 — 오브젝트 단위 뒤→앞). 군중·캐릭터에는 `glass` 를 쓰지 않는다(인스턴싱된 투명 정렬 비용 회피, 폴리곤 예산 행의 캐릭터 대상). 셰이더 파일(`glass.gdshader` 가칭)과 그림자 off 를 머티리얼·인스턴스 중 어디서 거는지는 Godot 4.7.2 동작을 확인해 R-B 가 정한다. 이 문서는 규약만 정한다.

## 룩 영향 없음

**채택안 (b) 는 화면 색 결과를 바꾸지 않는다: 현 시안 `toon_{a,b,c}.tres` 의 `accent_color` 가 흰색 (1, 1, 1, 1) 이고 군중 인스턴스 알파가 전부 1 이라 `toon.gdshader:40-42` 의 accent 항(`slot`)은 지금 모든 픽셀에서 정확히 1 이며, 현 메시는 전부 이름 없는 단일 서피스(= `base`)라 슬롯을 서피스로 옮겨도 같은 픽셀이 같은 파라미터로 칠해지기 때문이다.** 슬롯을 "어디에 저장하나"의 문제이고 실제 슬롯 색은 팔레트 티켓이 정한다. 따라서 이 티켓에 **사람 결정(아트 디렉션)이 필요한 항목은 없다.** `glass` 의 외곽선 제외·그림자 off 는 아직 `glass` 를 쓰는 에셋이 없어 화면에 나타나지 않으며, 첫 glass 에셋이 들어올 때 그 에셋의 스크린샷 검수(사람, 룩 변경)에서 함께 본다.

## 열린 질문

| # | 질문 | 선택지 | 추천 | 결정 주체·시점 |
|---|---|---|---|---|
| Q1 | 슬롯 색(오브젝트 정의 색)을 어디에 두나 | (a) 가구 데이터 테이블(`project/data/furniture/*.json`)에 슬롯별 팔레트 id 필드(`slots: {base, accent, emissive, glass}`) (b) glTF 머티리얼 baseColorFactor 를 그대로 기본값으로 (c) 둘 다 — glTF 값은 미리보기용, 게임은 테이블 | (a). 수치(색)는 `project/data/` 원칙, 팔레트 확정 뒤 일괄 교체 가능. glTF 의 색은 저작 미리보기로만 쓰고 런타임은 무시 | 가구 스키마 티켓(game-designer, 팔레트 확정 뒤) |
| Q2 | 캐릭터(군중)에 `accent` 를 허용하나 | (a) 허용 — 서피스 2, MultiMesh 드로우 +1(+외곽선 1) (b) `base` 만 — 색은 인스턴스 색 한 가지 | (a) 허용. 비용이 인스턴스 수와 무관(+2 드로우). 장르별 관객 의상 강조에 쓸 여지 | 캐릭터 에셋 티켓 |
| Q3 | 상태 변형의 실제 값(고장·철거 틴트 색, `emissive_energy` 켜짐 값, 점멸 주기) | — | 팔레트 티켓에서 함께. 사람 아트 디렉션 항목은 그쪽 | 팔레트 티켓 |
| Q4 | (b) 의 드로우콜 증가가 티어 1 대표 장면과 티어 4+ 에서 문제가 되나 | 측정 | 티어 1 가구 배치가 생긴 뒤 성능 측정 티켓에 "서피스 수별 draw calls·fps" 행 추가. 뒤집는 조건은 "채택안·근거" 끝 | qa 성능 측정(관문 시점, 사람 GPU) |
| Q5 | Godot 4.7.2 glTF 임포터가 슬롯 이름을 서피스 이름·서피스 머티리얼 `resource_name` 중 어디에 남기나, Blender 의 `base.001` 같은 접미가 어떻게 들어오나 | 확인 | **확인됨(SE-019 2차, GLTF_SPEC §9):** 둘 다에 그대로 남고 정규화 없음, 이름 없는 머티리얼은 `material_<n>`. "런타임 슬롯 판정"에 반영. 남은 확인: 실제 Blender 내보내기·임포트 옵션 변경·`EditorScenePostImport` 단계(GLTF_SPEC §9 한계) | art-pipeline(첫 Blender 에셋) / R-B |
| Q6 | SE-021 스크린스페이스 외곽선(`ss`)이 채택되면 `glass` 외곽선 제외를 어떻게 하나 | (a) glass 를 외곽선 포스트 패스의 깊이·법선 입력에서 빼기(투명 패스는 깊이를 안 쓰므로 기본 동작) (b) 마스크 | (a). 투명은 깊이를 쓰지 않아 깊이 기반 포스트 외곽선에 자동으로 빠진다 — 확인만 | SE-021 결과 뒤 |

## 부록 A. 현 구현 일치 판정 (`toon_b` 기준)

판정: **불일치.** `toon.gdshader:40-42` 는 (a) 정점 알파 규약을 구현한다. (b) 채택 시 `:40-41` 과 `:42` 의 `* slot` 은 M1 위반(정점 알파를 의미 채널로 씀)이고, 슬롯 판정은 셰이더가 아니라 서피스가 해야 한다.

인용(`project/view/shaders/toon.gdshader`, SE-018 병합 뒤 `8a6e4e1` 기준, SE-018 은 `.gdshader` 를 바꾸지 않았다):

```
 5	// 머티리얼 슬롯(style-guide: base/accent/emissive. glass 는 후속 티켓):
 6	//   albedo = 정점색(COLOR) × base_color, 정점 알파가 0 인 곳(accent 영역)은 추가로 × accent_color.
 7	//   스파이크 군중은 MultiMesh 인스턴스 색이 COLOR 로 들어오므로 시안을 씌워도 색 분포가 default 와 같다.
...
29	uniform vec4 accent_color : source_color = vec4(1.0);
...
40		float accent_w = 1.0 - COLOR.a;
41		vec3 slot = mix(vec3(1.0), accent_color.rgb, accent_w);
42		ALBEDO = base_color.rgb * COLOR.rgb * slot;
43		EMISSION = emissive_color.rgb * emissive_energy;
```

`toon_b.tres` 의 `accent_color = Color(1, 1, 1, 1)`(그리고 `toon_a`·`toon_c` 도 같음)이라 `:41` 의 `slot` 은 항상 (1, 1, 1) — 화면 영향 0, 코드만 죽은 분기다.

관련 불일치 하나 더: `shader_variants.gd:73-74` 는 `material_override` 로 메시 **전체 서피스**를 시안 머티리얼 하나로 덮는다. (b) 에서는 서피스마다 슬롯 머티리얼이 달라야 하므로(특히 `glass` 는 다른 셰이더·`next_pass` 없음) 슬롯 서피스를 가진 에셋에는 이 방식이 맞지 않는다. 현 프록시는 전부 단일 `base` 서피스라 지금은 결과가 같다.

후속 render 티켓 요청 문구는 부록 B.

## 부록 B. 후속 render 티켓 요청 (producer 발행용)

**R-A. `toon.gdshader` accent 정점 알파 분기 제거(룩 변화 0)** — render-engineer, SE-019 병합 뒤 바로 가능.
- 바꿀 줄: `project/view/shaders/toon.gdshader:40-42` → `:40-41` 삭제, `:42` 를 `ALBEDO = base_color.rgb * COLOR.rgb;` 로. `:5-7` 주석을 "슬롯 = 서피스(docs/gdd/materials.md), 정점 알파 무의미, COLOR.rgb 는 base 에만" 으로 교체. `:29` `accent_color` uniform 은 **유지**(R-B 에서 accent 서피스 색으로 쓴다).
- `.tres` 6개 영향: **없음.** `toon_{a,b,c}.tres` 의 `shader_parameter/accent_color` 는 uniform 이 남으므로 그대로, `outline_{a,b,c}.tres` 무관.
- 테스트 영향: 기존 테스트 실패 없음 — `test_toon_shader.gd::test_shader_files_declare_required_uniforms`(`accent_color` 선언·`COLOR` 사용 그대로 충족), `::test_variant_params_match_table`(.tres 불변), `::test_no_shader_constants_in_code`(리터럴 추가 없음). 추가 단언 요청: `test_toon_shader.gd` 에 "`toon.gdshader` 가 `COLOR.a` 를 읽지 않는다"(정규식 `\bCOLOR\s*\.\s*a\b` 매치 0, 대조군: 그 문자열을 넣은 소스는 매치).
- 수용 기준: 커밋된 기준 캡처 5장(`project/tests/view/screenshots/SE-002/grid_yaw45_zoom2.png`, `SE-004/{a,b,c}_yaw45_zoom2.png`·`b_yaw45_zoom0.png`)을 같은 명령(SE-020 `recapture.sh`)으로 재캡처해 픽셀 차 0.

**R-B. 슬롯 서피스 적용·glass 셰이더·인스턴스 파라미터** — render-engineer, 첫 슬롯 서피스 glTF 에셋(또는 슬롯 서피스를 가진 테스트 메시)이 생길 때.
- 바꿀 곳: `project/view/shaders/shader_variants.gd:73-74`(`material_override` → 서피스별 슬롯 머티리얼; 이름 없는 단일 서피스 = `base`, 지금과 같은 결과), `toon.gdshader:43`(발광을 `emissive` 서피스로 한정), 새 `glass` 셰이더·시안별 glass 파라미터, M5 인스턴스 파라미터.
- `.tres` 영향: `toon_{a,b,c}.tres` 는 슬롯별 머티리얼을 어떻게 만드느냐에 따라 바뀔 수 있다(룩 상수는 시안 파일 한 곳 유지 — M5·"슬롯 4종" 마지막 줄). `outline_{a,b,c}.tres` 는 값 불변(glass 에만 안 붙음).
- 테스트 영향(`material_override` 를 단언하는 것): `test_shader_variants.gd::test_load_failure_pushes_error_and_apply_changes_nothing`(:73, :78, :87), `::test_apply_sets_override_and_next_pass_without_new_nodes`(:149-168), `::test_apply_rejects_unknown_id_without_changes`(:181), `test_spike_scene.gd::test_default_material_is_b`(:373-384), `::test_material_variant_keeps_mesh_and_instance_counts`(:395-397). 단일 서피스 프록시만 있는 지금 장면에서는 `material_override` 를 유지하고 다중 서피스 메시에만 서피스별 적용을 하는 설계면 이 테스트들은 그대로 통과할 수 있다(설계는 R-B 가 정함).

## 부록 C. 수용 기준·테스트 방법

이 문서 자체는 SE-019 AC1·AC2·AC4·AC6(reviewer 문서 대조), AC5(qa: `git diff --stat origin/main` 에 `project/` 0건, `python3 tools/validate_data.py --strict` exit 0)로 확인한다. 후속 구현이 지킬 측정 가능한 문장:

| # | 기준 | 확인 방법(헤드리스) |
|---|---|---|
| C1 | `toon.gdshader` 소스에 `COLOR.a` 읽기가 0 건 | R-A 의 `test_toon_shader.gd` 정규식 단언 |
| C2 | 이름 없는 단일 서피스 메시에 시안 B 를 적용한 결과가 R-A 전과 픽셀 동일 | SE-020 `recapture.sh` 5장 + `compare_png.gd` 픽셀 차 0 |
| C3 | 슬롯 서피스 4개 테스트 메시에서 `glass` 서피스 머티리얼의 `next_pass == null`, 나머지 3개는 `outline_<id>.tres` | R-B 단위 테스트(헤드리스, 노드 트리 검사) |
| C4 | 같은 시안·같은 슬롯의 머티리얼 리소스가 장면 전체에서 1개(오브젝트 2개에 다른 accent 색을 줘도 `accent` 머티리얼 인스턴스 id 가 같다) | R-B 단위 테스트 |
| C5 | 군중 인스턴스 색 알파를 0.0 으로 바꿔도 `base`/`accent` 서피스 색 계산이 같다 | R-B 단위 테스트 또는 캡처 비교(인스턴스 1개) |
| C6 | glTF 린터가 슬롯 이름 외 머티리얼·`base` 누락·슬롯 중복·정점 알파 ≠ 1.0 을 거부한다 | 후속 art-pipeline 린터 티켓(GLTF_SPEC 체크리스트 대상 fixture) |

## 변경 이력

| 날짜 | 버전 | 티켓 | 내용 |
|---|---|---|---|
| 2026-10-09 | materials.md v0 | SE-019 | 신규 작성. 채택 (b) 슬롯 = 별도 서피스. `project/data/` 변경 없음, 스키마 변경 없음 |
| 2026-10-09 | materials.md v0 (1차 보정) | SE-019 (2차 art-pipeline Q5 확인) | "런타임 슬롯 판정"을 Godot 4.7.2 임포트 사실에 맞췄다: 슬롯 이름은 `surface_get_name(i)` 우선·`resource_name` 보조, 완전 일치, 판정 함수 한 곳. "이름 없는 서피스 = `base`" 는 프록시 메시·`material` 키 없는 primitive(`''`)에만 해당하고, 임포트 에셋의 이름 없는 머티리얼은 `material_<n>` 으로 들어와 `base` + `push_warning` 경로(린터 R4 가 먼저 거부). Q5 확인됨. 채택안·슬롯 규약·데이터 변경 없음 |
