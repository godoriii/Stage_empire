---
name: register-asset
description: 검수 통과한 에셋을 review-queue 에서 project/assets 로 옮기고 데이터 테이블의 status 를 approved 로 바꾼다. 사람(아트 디렉터)이 검수 후 메인 세션에서 실행한다. 사용 - /register-asset <asset-id>
---

# 에셋 등록 (사람 검수 후)

서브에이전트는 `project/assets/models|materials|audio` 에 쓸 수 없다. 이 스킬은 사람이 모는 메인 세션 전용이다.

1. `project/assets/review-queue/<asset-id>/` 의 `META.json`, `lint.json` 을 읽고 검사 결과가 통과인지 확인한다. 실패면 멈추고 알려준다.
2. 모델은 `project/assets/models/<category>/<asset-id>.glb`, 머티리얼은 `project/assets/materials/`, 오디오는 `project/assets/audio/<music|sfx>/` 로 `git mv` 한다.
3. `project/data/furniture/*.json`(또는 `project/data/audio/`) 에서 해당 항목의 `"status": "review"` 를 `"approved"` 로 바꾸고 `path` 를 새 경로로 갱신한다.
4. `python3 tools/validate_data.py` 통과 확인.
5. `project/assets/review-queue/INDEX.md` 의 해당 줄을 "승인 YYYY-MM-DD" 로 갱신한다.
6. 커밋 메시지: `SE-### register asset <asset-id>`.
