# 🦞 ohmyclaw

> Multi-provider agent harness skill for OpenClaw

[![Release](https://img.shields.io/github/v/release/jkf87/ohmyclaw)](https://github.com/jkf87/ohmyclaw/releases)
[![CI](https://github.com/jkf87/ohmyclaw/actions/workflows/ci.yml/badge.svg)](https://github.com/jkf87/ohmyclaw/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

---

## 한국어

OpenClaw 용 멀티프로바이더 에이전트 하네스 스킬. Z.ai GLM 시리즈, OpenAI GPT-5.6 (Codex OAuth), OpenRouter 200+ 모델을 작업 복잡도에 따라 자동 라우팅하고, goal/evidence 기반으로 작업 완료를 추적합니다.

### 설치

```bash
bash <(curl -sL https://raw.githubusercontent.com/jkf87/ohmyclaw/main/install.sh)
```

또는 수동:

```bash
git clone https://github.com/jkf87/ohmyclaw.git
ln -sfn "$(pwd)/ohmyclaw/skills/ohmyclaw" ~/.openclaw/skills/ohmyclaw
```

### 사용법

```
/ohmyclaw                          — HUD 대시보드
/ohmyclaw route <작업>              — 모델 라우팅 미리보기
/ohmyclaw exec <작업>               — 자율 실행
/ohmyclaw plan <작업>               — 계획 수립
/ohmyclaw review                    — 코드 리뷰 + 갭 감지
/ohmyclaw team N <작업>             — 병렬 워커 N명
/ohmyclaw ralph <작업>              — 통과까지 루프
/ohmyclaw debug <작업>              — 디버깅
/ohmyclaw interview [주제]          — Socratic 명확화 인터뷰
/omc_experimental [list|enable|disable <name>]
                                   — 실험 기능 on/off
/omc_star [--status|--never]        — 저장소 별 링크 안내
```

### 긴 작업 재개

작업이 타임아웃·크래시로 중단돼도 처음부터 다시 하지 않습니다. 단계·태스크 단위로 sqlite 에 커밋해두고 재개 시 **남은 일만** 다시 배정합니다.

```bash
S=~/.openclaw/skills/ohmyclaw/session-store.sh
$S interrupted --stale-sec 900   # 중단된 세션 찾기
$S resume <세션ID>                # 남은 일만 받기 (완료분은 재실행 안 함)
$S status <세션ID>
```

`OHMYCLAW_SESSION_ID` 를 설정한 경우에만 기록합니다. 설정하지 않으면 비활성이며 기존 동작 그대로입니다.

### 실험 기능 (기본 off)

라이브 검증이 끝나지 않은 기능은 기본 비활성이며, 설정 파일을 직접 고치지 않고 켜고 끕니다.

챗에서는 `/omc_experimental`, 셸에서는 `cli.sh` 로 실행합니다:

```bash
C=~/.openclaw/skills/ohmyclaw/cli.sh

$C experimental list                     # 현재 상태
$C experimental enable thinkingSuffix    # 켜기 (영구)
$C experimental disable thinkingSuffix   # 끄기

OHMYCLAW_GLM53=true $C route "..."       # 이번 한 번만
```

자주 쓴다면 `alias ohmyclaw=~/.openclaw/skills/ohmyclaw/cli.sh` 를 셸 설정에 넣어두세요.

| 기능 | 켜면 | 기본 off 인 이유 |
|---|---|---|
| `thinkingSuffix` | HIGH 슬롯이 `max` reasoning effort 로 실행 | `model[effort]` 접미의 spawn 수용 여부 미검증. 거부되면 폴백 체인으로 강등 |
| `glm53` | pro/max HIGH 슬롯에 `glm-5.3` 사용 | OpenClaw zai 카탈로그에 미등재. 꺼져 있으면 `glm-5.2` 로 강등 |

`enable` 시 리스크를 함께 출력하며, `disable` 하면 켜기 전과 완전히 동일한 동작으로 돌아갑니다.

### 끄는 스위치

| 대상 | 방법 |
|---|---|
| 별 안내 | `cli.sh star --never` / `OHMYCLAW_SKIP_STAR_PROMPT=1` |
| 업데이트 확인 | `OHMYCLAW_SKIP_UPDATE_CHECK=1` |
| 실험 기능 | `cli.sh experimental disable <name>` |
| 세션 스토어 | `OHMYCLAW_SESSION_ID` 미설정 |


---

## English

A multi-provider agent harness skill for OpenClaw. Routes across Z.ai GLM, OpenAI GPT-5.6 (Codex OAuth), and OpenRouter 200+ models based on task complexity, with evidence-driven goal completion tracking.

### Install

```bash
bash <(curl -sL https://raw.githubusercontent.com/jkf87/ohmyclaw/main/install.sh)
```

Or manually:

```bash
git clone https://github.com/jkf87/ohmyclaw.git
ln -sfn "$(pwd)/ohmyclaw/skills/ohmyclaw" ~/.openclaw/skills/ohmyclaw
```

### Usage

```
/ohmyclaw                          — HUD dashboard
/ohmyclaw route <task>             — model routing preview
/ohmyclaw exec <task>              — autonomous execution
/ohmyclaw plan <task>              — planning
/ohmyclaw review                   — code review + gap detection
/ohmyclaw team N <task>            — parallel workers
/ohmyclaw ralph <task>             — loop until pass
/ohmyclaw debug <task>             — debugging
/ohmyclaw interview [topic]        — Socratic clarification interview
/omc_experimental [list|enable|disable <name>]
                                   — toggle experimental features
/omc_star [--status|--never]       — repo star link
```

### Resuming long runs

A run cut short by a timeout or crash does not start over. Stages and tasks are committed to sqlite, and a resume hands back **only the remaining work**.

```bash
S=~/.openclaw/skills/ohmyclaw/session-store.sh
$S interrupted --stale-sec 900   # find interrupted sessions
$S resume <session-id>           # remaining work only; done tasks are never re-run
$S status <session-id>
```

Recording happens only when `OHMYCLAW_SESSION_ID` is set. Leave it unset and behavior is unchanged.

### Experimental features (off by default)

Features that have not completed live verification ship disabled, and toggle without editing config by hand.

From chat use `/omc_experimental`; from a shell use `cli.sh`:

```bash
C=~/.openclaw/skills/ohmyclaw/cli.sh

$C experimental list                     # current state
$C experimental enable thinkingSuffix    # turn on (persistent)
$C experimental disable thinkingSuffix   # turn off

OHMYCLAW_GLM53=true $C route "..."       # one invocation only
```

If you use these often, add `alias ohmyclaw=~/.openclaw/skills/ohmyclaw/cli.sh` to your shell config.

| Feature | When on | Why it ships off |
|---|---|---|
| `thinkingSuffix` | HIGH slots run at `max` reasoning effort | The `model[effort]` suffix is unverified at spawn time; if rejected, routing falls through the fallback chain |
| `glm53` | `glm-5.3` fills pro/max HIGH slots | Not yet in the OpenClaw zai catalog; demotes to `glm-5.2` while off |

`enable` prints the feature's risk, and `disable` restores exactly the prior behavior.

### Kill switches

| Target | How |
|---|---|
| Star prompt | `cli.sh star --never` / `OHMYCLAW_SKIP_STAR_PROMPT=1` |
| Update check | `OHMYCLAW_SKIP_UPDATE_CHECK=1` |
| Experimental features | `cli.sh experimental disable <name>` |
| Session store | leave `OHMYCLAW_SESSION_ID` unset |


---

## License

MIT
