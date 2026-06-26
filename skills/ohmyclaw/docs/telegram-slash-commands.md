# Telegram 슬래시 명령 등록 & 자동 복구 (v1.7.1)

ohmyclaw 의 `omc_*` 슬래시 명령(`/omc_interview` 등)을 텔레그램 봇의 **자동완성 메뉴**에 노출하고, 게이트웨이 재시작 후에도 유지되도록 자동 복구한다.

> 슬래시 명령 자체의 **동작**(`/ohmyclaw interview`, `commands menu` 버튼, `commands dispatch`)은 등록과 무관하게 항상 작동한다. setMyCommands 등록은 `/` 입력 시 뜨는 **자동완성 UX** 용이다.

## 왜 자동 복구가 필요한가

openclaw 2026.6.6 에는 setMyCommands 전용 CLI 가 없고, 게이트웨이는 **시작 시 `deleteMyCommands` + `setMyCommands`** 로 자기 명령(코어/플러그인)을 재설정한다. 따라서 수동으로 등록한 `omc_*` 는 다음 게이트웨이 재시작 때 사라진다. 이를 launchd 주기 실행으로 자동 복구한다.

## 구성

| 파일 | 역할 |
|------|------|
| [`scripts/telegram-register-commands.sh`](../../../scripts/telegram-register-commands.sh) | 활성 봇마다 기존 명령 보존-병합 후 `omc_*` 등록 (idempotent) |
| [`scripts/com.ohmyclaw.register-commands.plist.template`](../../../scripts/com.ohmyclaw.register-commands.plist.template) | launchd LaunchAgent 템플릿 (RunAtLoad + StartInterval 300s) |

### 동작 원리

1. 명령 목록은 **단일 소스** `cli.sh commands json` 에서 가져온다.
2. 각 봇(`~/.openclaw/openclaw.json` 의 활성 telegram accounts)에 대해 `getMyCommands` → **기존 명령 보존** + `omc_*` 병합 → `setMyCommands`.
3. `getMyCommands` 결과는 Telegram 측 캐시로 **비결정적 stale** 가능 → 읽기로 no-op 판단하지 않고 **항상 merge+set**. 병합 결과는 읽기가 stale 든 fresh 든 동일(openclaw 명령 보존 + `omc_*` 포함).
4. launchd 가 로드/로그인 시 1회 + **5분(StartInterval 300)** 마다 실행 → 재시작 후 ≤5분 내 자동 복구.

## 설치 (macOS)

```bash
# 1) 스크립트 배치
cp scripts/telegram-register-commands.sh ~/.openclaw/ohmyclaw-register-commands.sh
chmod +x ~/.openclaw/ohmyclaw-register-commands.sh

# 2) LaunchAgent 생성 (홈 경로 치환)
sed "s|__HOME__|$HOME|g" scripts/com.ohmyclaw.register-commands.plist.template \
  > ~/Library/LaunchAgents/com.ohmyclaw.register-commands.plist

# 3) 로드 (즉시 1회 실행 + 이후 주기)
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.ohmyclaw.register-commands.plist
```

## 운영

```bash
launchctl list | grep ohmyclaw                                   # 상태
tail -f ~/.openclaw/logs/ohmyclaw-register-commands.log          # 로그
bash ~/.openclaw/ohmyclaw-register-commands.sh                   # 수동 즉시 실행
launchctl kickstart -k gui/$(id -u)/com.ohmyclaw.register-commands  # 강제 1회 실행
launchctl bootout  gui/$(id -u)/com.ohmyclaw.register-commands   # 중지/제거
```

복구 간격 변경은 plist 의 `StartInterval`(초) 을 조정 후 재로드(`bootout` → `bootstrap`).

## 일회성 등록 (자동 복구 없이)

```bash
cli.sh commands register     # setMyCommands JSON 페이로드 + Bot API/@BotFather 적용 가이드 출력
cli.sh commands botfather    # @BotFather 붙여넣기 형식
```

## 참고

- [docs/ask-flow.md](ask-flow.md) — `commands` verb (list/json/botfather/register/dispatch/menu) 와 presentation 버튼
- [Telegram Bot API setMyCommands](https://core.telegram.org/bots/api#setmycommands)
