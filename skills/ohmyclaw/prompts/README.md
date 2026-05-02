# ohmyclaw prompts/

OMX (oh-my-codex) 의 role prompt 패턴을 카피한 후 ohmyclaw 통합 블록을 덧붙인 디렉토리입니다. 각 prompt 는 XML contract 포맷 (`<identity>` / `<constraints>` / `<execution_loop>` / `<output_contract>`) 으로 작성되어 있어, ohmyclaw 의 composable verbs (§ 7) 가 spawn 시 그대로 inject 합니다.

## 출처 / 라이선스

원본: https://github.com/Yeachan-Heo/oh-my-codex (MIT)
- 이 디렉토리의 9 prompts 는 OMX `prompts/*.md` 에서 카피 + 짧은 통합 블록 추가
- `reviewer.md` 는 OMX 의 `code-reviewer.md` + `security-reviewer.md` + `quality-reviewer.md` 합본 + 5관점 + 갭 감지 통합
- 각 파일 마지막 `## ohmyclaw integration` 섹션에 출처와 차이점 명시

## 매핑 표 — Prompt × Verb × Default Model

| Prompt | 사용 동사 | 카테고리 (auto) | Pro 기본 모델 | +Codex HIGH |
|--------|----------|-----------------|---------------|-------------|
| `executor.md` | `$ohmyclaw exec`, `$ohmyclaw ralph` (executor 단계) | `auto` | glm-5 / glm-5.1 | gpt-5.5 |
| `planner.md` | `$ohmyclaw plan`, `$ohmyclaw deep-interview` | `reasoning` | glm-5.1 | gpt-5.5 |
| `architect.md` | `$ohmyclaw plan --consensus` 의 architect 단계 | `coding_arch` | glm-5.1 | **gpt-5.5** |
| `reviewer.md` | `$ohmyclaw review`, `$ohmyclaw ralph` 의 검증 단계 | `reasoning` | glm-5.1 | gpt-5.5 |
| `verifier.md` | `$ohmyclaw verify`, `$ohmyclaw ralph` | `reasoning` | glm-5.1 | gpt-5.5 |
| `debugger.md` | `$ohmyclaw debug` | `debugging` | glm-5 | **gpt-5.5** (HIGH) |
| `critic.md` | `$ohmyclaw plan --consensus` 의 critic 단계 | `reasoning` | glm-5.1 | gpt-5.5 |
| `team-orchestrator.md` | `$ohmyclaw team N:role` 의 리더 | `reasoning` | glm-5.1 | gpt-5.5 |
| `team-executor.md` | `$ohmyclaw team N:executor` 의 워커 | `auto` | glm-5 / glm-5.1 | gpt-5.5 |

> Lite 플랜에서는 위 표의 `glm-5.1` 이 `select-model.sh` 의 `cap_for_lite` 에 의해 자동으로 `glm-5` 로 강등됩니다.

## Verb × Prompt 합성 규칙

| Verb | 합성 |
|------|------|
| `$ohmyclaw exec "<task>"` | `executor.md` 단일 spawn |
| `$ohmyclaw team N:executor "<task>"` | `team-orchestrator.md` 1 + `team-executor.md` × N |
| `$ohmyclaw ralph "<task>"` | `executor.md` + `verifier.md` 루프 (max iterations = 플랜별, lite=2/pro=3/max=4) |
| `$ohmyclaw plan "<task>"` | `planner.md` 단일 |
| `$ohmyclaw plan --consensus "<task>"` | `planner.md` → `architect.md` → `critic.md` 합의 루프 |
| `$ohmyclaw deep-interview "<task>"` | `planner.md` 의 ambiguity gating 부분만 |
| `$ohmyclaw review <files>` | `reviewer.md` 단일 (5관점 + 갭 감지) |
| `$ohmyclaw debug "<task>"` | `debugger.md` 단일 (4단계 RCA, 3-failure circuit breaker) |
| `$ohmyclaw verify <claim>` | `verifier.md` 단일 (PASS / FAIL / PARTIAL) |

## 모델 선택 × 계정 선택 통합 패턴

각 prompt 를 spawn 할 때 외부 호출자가 다음을 수행:

```bash
SKILL=skills/ohmyclaw
PROMPT=$SKILL/prompts/<role>.md

# 1. 모델 결정 (select-model.sh)
MODEL=$($SKILL/select-model.sh "<task>" <category> --plan=$ZAI_CODING_PLAN ${CODEX_OAUTH_ENABLED:+--codex})

# 2. 계정 결정 (pool.sh round-robin)
read -r ID AUTH_TYPE AUTH_VAL PLAN WEIGHT <<< $(echo "$($SKILL/pool.sh next $MODEL)" | tr '|' ' ')

# 3. 인증 적용 후 spawn (OpenClaw bash + sessions_spawn 패턴)
case "$AUTH_TYPE" in
  oauth_zai)   openclaw-profile activate "$AUTH_VAL" ;;
  oauth_codex) export CODEX_HOME="$AUTH_VAL" ;;
  api_key)     export ZAI_API_KEY="${!AUTH_VAL}" ;;
esac

# 에이전트가 직접 실행 (기본 — sub-agent spawn 불필요)
# → 해당 prompt 의 <execution_loop> 를 읽고 직접 따릅니다.
# 병렬/background 필요 시에만 CLI spawn:
bash pty:true workdir:"$PROJECT" background:true command:"codex exec --full-auto '<task>'"
# 또는: claude --permission-mode bypassPermissions --print '<task>'
# 또는: pi --provider zai --model $MODEL '<task>'

# 4. 실패 시 cooldown + 다음 계정으로 재시도
[[ $? -ne 0 ]] && $SKILL/pool.sh cooldown "$ID"
```

## XML contract 포맷 요약

모든 OMX-스타일 prompt 는 같은 구조:

```markdown
---
description: "<role 한 줄>"
argument-hint: "<input 형태>"
---
<identity>          # 누구이고 무엇을 책임지는지
<constraints>       # scope_guard / ask_gate / reasoning_effort
<execution_loop>    # 단계별 워크플로
<success_criteria>  # 완료 조건
<verification_loop> # 검증 단계
<tool_persistence>  # 도구 재시도 정책
<delegation>        # 위임 정책 (선택)
<tools>             # 사용 가능한 도구
<style>
  <output_contract> # 출력 포맷
  <anti_patterns>   # 금지 패턴
  <scenario_handling> # Good/Bad 예시
  <final_checklist> # 자체 점검
</style>
```

## 차이점 요약 (vs OMX 원본)

| 항목 | OMX 원본 | ohmyclaw 적응 |
|------|----------|---------------|
| 모델 선택 | 호출자 자유 | `select-model.sh` 통과 의무 (P95 plan_block 적용) |
| 계정 풀 | OMX 자체 OAuth | `pool.sh` round-robin (zai + codex) |
| 한국어 처리 | 영문 기본 | 한국어 비율 > 0.5 시 한국어 출력 |
| 알림 | `omx system event` | `openclaw system event` (OMX hook 호환) |
| reviewer 분리 | 3개 (code/security/quality) | 1개 합본 + Stage 5 갭 감지 |
| Plan→Work→Review | 별도 파이프라인 | 동사 합성으로 분해 (`$ralph` = exec+verify, `$plan --consensus` = plan+arch+critic) |

## 추가/제거 제안

새 role 이 필요하면:
1. OMX `prompts/` 에 같은 컨셉이 있는지 먼저 확인
2. 있으면 카피 + 본 README 매핑 표 추가
3. 없으면 새로 작성 (XML contract 포맷 준수)

기존 role 이 안 쓰이면 SKILL.md § 7 동사 매핑에서 제거 후 prompt 파일도 삭제.
