# Auth-order health sync (멀티계정 자동 라우팅)

## 문제

한 provider(예: `openai`)에 auth 프로파일이 여러 개 등록돼 있을 때
(`openai:default`, `openai:jjoongoo@gmail.com` …), openclaw 게이트웨이는 per-agent
**order override 가 없으면 라운드로빈**으로 프로파일을 번갈아 쓴다. 이 중 하나의
OAuth 로그인이 만료되면, 게이트웨이가 절반쯤 그 만료 프로파일을 골라:

```
⚠️ Model login expired on the gateway for openai. Re-auth with
   openclaw models auth login --provider openai, then try again.
🔁 Model Fallback: zai/glm-4.7 (selected openai/gpt-5.5; auth permanent (+N more attempts))
```

를 반복한다. (게이트웨이가 폴백은 해주므로 기능은 돌지만 경고가 시끄럽고, 만료
계정을 계속 재시도한다.)

> 이건 **openclaw 게이트웨이의 auth 프로파일 라운드로빈** 동작이다. 봇들은 ohmyclaw
> 하네스를 경유하지 않고 openclaw 네이티브 라우팅을 쓰므로, ohmyclaw 의 모델-라우팅
> 게이트(select-model)로는 못 막는다. → openclaw 의 auth order 를 직접 조정해야 한다.

## 해결: 정적 pin 이 아니라 health 기반 동적 order

계정 하나를 정적으로 고정(pin)하면 멀티계정 취지가 무너진다. 대신
`provider-health.sh sync-auth-order` 가 프로파일별 **라이브 health**(openclaw
`models status --probe`)를 보고 openclaw `models auth order` 를 동적으로 맞춘다:

| 상태 | 조치 | 효과 |
|------|------|------|
| 전부 정상 | `auth order clear` | 라운드로빈 유지 (멀티계정 부하분산) |
| 일부 만료 | `auth order set <정상만>` | 만료 프로파일 제외 → 경고 근절 |
| 전부 만료 | 재로그인 안내(로그) | 손댈 수 없음 — 재인증 필요 |

재로그인으로 프로파일이 회복되면(`status=ok`) 다음 싱크에서 **자동으로 order 를
해제(clear)** 하여 라운드로빈으로 복귀한다. 즉 사람이 개입할 일은 만료된 계정
재로그인뿐이고, 라우팅은 ohmyclaw 가 알아서 정상 계정만 쓰도록 유지한다.

## 수동 실행

```bash
SKILL=~/.openclaw/skills/ohmyclaw
$SKILL/provider-health.sh sync-auth-order            # dry-run (계획만 출력)
$SKILL/provider-health.sh sync-auth-order --apply    # 실제 적용
$SKILL/provider-health.sh probe-profiles openai      # 프로파일별 라이브 health
$SKILL/provider-health.sh profiles openai            # 등록 프로파일 목록
$SKILL/provider-health.sh agents-using openai        # 이 provider 쓰는 agent
```

- OAuth 이고 프로파일 ≥2 인 provider 만 대상(단일 프로파일/`static` api_key 는 skip).
- probe 결과가 비면(오프라인/실패) **아무것도 안 건드림**(잘못된 제외 방지).
- `OHMYCLAW_PROVIDER_HEALTH=false` 로 전체 비활성.

## 자동화 (launchd, macOS)

`register-commands` 와 동일한 패턴. 10분 주기 + 로드 시 1회.

```bash
sed "s|__HOME__|$HOME|g" scripts/com.ohmyclaw.auth-order-sync.plist.template \
  > ~/Library/LaunchAgents/com.ohmyclaw.auth-order-sync.plist
cp scripts/openclaw-auth-order-sync.sh ~/.openclaw/ohmyclaw-auth-order-sync.sh
chmod +x ~/.openclaw/ohmyclaw-auth-order-sync.sh
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.ohmyclaw.auth-order-sync.plist

# 제거
launchctl bootout gui/$(id -u)/com.ohmyclaw.auth-order-sync
```

로그: `~/.openclaw/logs/ohmyclaw-auth-order-sync.log` (profileId 만 기록, 토큰 비노출).

## 관련

- `provider-health.sh` — provider/프로파일 health 조회 + auth-expiry 게이트(select-model).
- SKILL.md § 6-6 — auth-expiry 게이트 개요.
