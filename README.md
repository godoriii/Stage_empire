# Stage Empire

지하 라이브클럽에서 글로벌 메가 페스티벌까지 키우는 2.5D 아이소메트릭 건설·경영 시뮬레이션. Godot 4.x.

- 기준 문서: `docs/PRD.md` (원본은 Claude Docs)
- 작업 규칙: `CLAUDE.md`
- 에이전트: `.claude/agents/` (producer, game-designer, content-writer, sim-engineer, render-engineer, art-pipeline, audio, qa, reviewer)
- 경계 정책: `tools/hooks/boundary_policy.json`, 강제는 `.claude/settings.json` hooks
- 주간 상태: `docs/status/`

## 시작하기

```bash
git lfs install
python3 tools/validate_data.py            # 데이터 테이블 검증
python3 tools/hooks/boundary.py --self-test
tools/run_tests.sh                        # Godot + GUT 설치 후 (docs/adr/0003)
```

사람은 Claude Code 메인 세션에서 **producer** 에이전트만 상대한다:

```
> producer 에이전트로 "티어 1 공연 루프가 돌아가게" 마일스톤을 티켓으로 쪼개줘
```

## 구조

```
stage-empire/
├─ CLAUDE.md                 아키텍처 원칙, 경계 규칙, 명령어, 티켓 형식
├─ .claude/agents/           에이전트 9종
├─ .claude/skills/           new-ticket, headless-test, register-asset, sheet-export, build
├─ .claude/settings.json     hooks: 경계 차단, 커밋 전 검증, main/force push 차단
├─ docs/  PRD.md gdd/ adr/ tickets/ reviews/ reports/ status/ style-guide.md
├─ project/                  Godot 프로젝트: core/ sim/ world/ view/ ui/ data/ assets/
├─ tools/                    validate_data.py run_tests.sh hooks/ (assets/ bot/ 예정)
└─ tests/                    sim/ view/ e2e/
```
