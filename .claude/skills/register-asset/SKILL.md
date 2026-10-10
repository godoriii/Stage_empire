---
name: register-asset
description: 검수 통과한 에셋을 review-queue 에서 project/assets 로 옮기고 데이터 테이블의 경로(`model`)를 확인한다. 사람(아트 디렉터)이 검수 후 메인 세션에서 실행한다. 사용 - /register-asset <asset-id>
---

# 에셋 등록 (사람 검수 후)

서브에이전트는 `project/assets/models|materials|audio` 에 쓸 수 없다. 이 스킬은 사람이 모는 메인 세션 전용이다.

1. `project/assets/review-queue/<asset-id>/` 의 `META.json`, `lint.json` 을 읽고 `verdict: "pass"`(거부 0)인지 확인한다. 실패면 멈추고 알려준다. `INDEX.md` 상태가 "테스트용(교체 예정)" 이면 등록 대상이 아니다 — 사람이 명시적으로 원할 때만 진행한다.
2. **가구 모델 전제 조건:** R-B(SE-041 2차, 슬롯 서피스별 셰이더)가 병합돼 있어야 한다. 그 전에 옮기면 툰 셰이더·외곽선 없이 glTF 원색으로 그려지고, 해당 가구가 나오는 기준 캡처가 strict 비교에서 깨진다.
3. 파일 이동(`git mv`):
   - 가구 모델 → `project/assets/models/<asset-id>.glb` (**하위 폴더 없음** — `furniture.schema.json` `model` 패턴과 build.md FC4 가 `res://assets/models/<id>.glb` 만 허용한다. 하위 폴더에 두면 경고 없이 프록시로 남는다)
   - 머티리얼 → `project/assets/materials/`, 오디오 → `project/assets/audio/<music|sfx>/`
   - `review-queue/.gdignore` 때문에 큐 안에는 `.import` 가 없다. 옮긴 뒤 `godot --headless --path project --import` 로 임포트 파일을 만들고 함께 커밋한다.
4. 데이터: 가구는 `project/data/furniture/furniture.json` 해당 행의 `model` 이 `res://assets/models/<asset-id>.glb` 인지 확인한다(없으면 game-designer 티켓으로 등록 — 이 스킬에서 수치·필드를 새로 만들지 않는다). furniture.json 에는 `status`·`path` 필드가 없다. 오디오 테이블은 그 테이블 스키마의 경로 필드를 따른다.
5. 검증: `python3 tools/validate_data.py --strict`, `tools/run_tests.sh`. 이 가구가 나오는 캡처(`project/tests/view/screenshots/recapture.sh` — 예: `build_baseline`, `crowd150_show`)를 재캡처하고, 룩이 바뀐 기준 PNG 는 사람이 승인한 뒤 같은 커밋에 갱신한다.
6. `project/assets/review-queue/INDEX.md` 의 해당 줄을 "승인 YYYY-MM-DD" 로 갱신하고 큐 디렉터리는 비운다(`git rm`).
7. 커밋 메시지: `SE-### register asset <asset-id>`.
