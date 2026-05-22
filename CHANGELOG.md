# Changelog

본 프로젝트는 [Keep a Changelog](https://keepachangelog.com/) 형식과 [SemVer](https://semver.org/) 를 따릅니다.

## [1.1.0] — 2026-05-23

### Added — 로버스트성 (P1–P7)
- **bats 테스트 슈트** (`tests/`, 58+ 케이스): select-model 라우팅 매트릭스·우선순위 규칙·plan cap·reasoning 인식·Codex/OpenRouter overlay 회귀 + engine.sh resolve(omp 우선/폴백, role→permission, 강제/no-fallback, acp-config, doctor) + pool.sh next/cooldown/release + worker semaphore + 동시성 race 시나리오.
- **JSON Schema**: `skills/ohmyclaw/schemas/routing.schema.json`, `skills/ohmyclaw/schemas/bridge-event.schema.json`. `engine.sh doctor` 와 CI 에서 `ajv-cli` 로 검증.
- **CI**: `.github/workflows/ci.yml` — ubuntu+macos 매트릭스, `bash -n` + shellcheck + ajv 스키마 검증 + bats 슈트.
- **Makefile**: `test`/`lint`/`schema`/`doctor`/`syntax`/`ci` 타깃.
- **Worker semaphore** (P5): `pool.sh acquire-worker` / `release-worker` / `sweep`. `ZAI_CODING_PLAN` 에 따른 `maxWorkers` 강제(만석 시 exit 11), `${OHMYCLAW_STATE_DIR}/pids/<session>/` 슬롯 파일에 PID 추적, dead PID 자동 회수.

### Changed — 동시성·정확성·문서
- **pool.sh 동시성 안전** (P2/F1): 모든 write 액션을 `with_state_lock` 으로 직렬화. Linux 는 `flock`, macOS 는 portable mkdir-lock 폴백. read-modify-write 사이클 race 종료.
- **bridge 이벤트 구조화** (P6/F7): SKILL.md §9 free-form `--text` 예제를 `bridge-event.schema.json` 기반 JSON 페이로드 패턴으로 교체. `payload.summary` 로 하위호환 텍스트 유지.
- **출처 정정**: README/SKILL.md 의 "우로보로스 → 갭 5유형" 인용을 사실 기반으로 수정. 실제 [Q00/ouroboros](https://github.com/Q00/ouroboros) 의 매커니즘은 "Ambiguity Score(4차원 가중, ≤0.2 게이트)" 이며, 갭 5유형(`assumption_injection / scope_creep / direction_drift / missing_core / over_engineering`)은 ohmyclaw 자체 분류임을 명시.

### Fixed
- routing.json 의 키 오타가 런타임까지 미발각되던 문제 — ajv 스키마 검증(F3)으로 사전 차단.
- 병렬 워커 fan-out 시 `pool-state.json` 의 `roundRobinIndex` 가 한쪽 writer 에게 lost-update 되던 race (F1).
- `concurrency.maxWorkers` 가 hud 표시용일 뿐 실제 spawn 한도가 강제되지 않던 결함 (F2).
- 비정상 종료 시 `${STATE_DIR}/pids/<session>/` 의 고아 슬롯이 누적되던 문제 — `pool.sh sweep` 으로 dead PID 회수 (F5).

## [1.0.0] — 2026-05-23 (먼저, omp ACP 엔진 이식)
- **Engine layer (omp via ACP)**: `engine.sh` 신규 — `acpx` 의 `--agent "omp acp"` escape hatch 로 oh-my-pi(omp) 를 1순위 엔진으로 spawn, omp 미설치 시 acpx 내장 어댑터(pi/codex/claude)로 graceful fallback.
- routing.json 최상위 `engine` 블록 + ohmyclaw=모델·계정·키 / omp=엔진툴·세부 role 소유권 분할.
- 우로보로스 reviewer.md 는 변경 없이 omp 툴(`lsp_diagnostics`/`ast_grep_search`)을 그대로 활용.
- SKILL.md `Engine layer` 섹션, §6-3/§7-2 spawn 을 engine.sh 경유로 교체, §10 가상 `zai-runner` 제거.
- SKILL.md 예제의 셸 인용/인젝션 결함 수정 (`printf %q` 안전 인용 17곳).

[1.1.0]: https://github.com/jkf87/ohmyclaw/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/jkf87/ohmyclaw/releases/tag/v1.0.0
