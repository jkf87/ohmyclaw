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
```

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
```

---

## License

MIT
