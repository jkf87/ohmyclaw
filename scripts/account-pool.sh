#!/usr/bin/env bash
# OpenClaw 하네스 — 계정 풀 관리 (OAuth Round-Robin / Fan-Out)
# 여러 OAuth 계정을 풀로 관리하여 rate limit 분산 및 가용성 향상
#
# 사용법: ./account-pool.sh <액션> [인자...]
#   next <pool> | fanout <pool> | cooldown <pool> <acct> | release <pool> <acct>
#   status [pool] | reset [pool]
set -euo pipefail

HARNESS_DIR="${HARNESS_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
ACCOUNTS_FILE="${ACCOUNTS_FILE:-${HARNESS_DIR}/routing/accounts.yaml}"
STATE_DIR="${HARNESS_DIR}/state"
POOL_STATE="${POOL_STATE:-${STATE_DIR}/account-pool-state.json}"
mkdir -p "${STATE_DIR}"

now_epoch() { date +%s; }
now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }
log_info()  { echo "[account-pool] INFO  $*" >&2; }
log_warn()  { echo "[account-pool] WARN  $*" >&2; }
log_error() { echo "[account-pool] ERROR $*" >&2; }

# ── YAML 파싱 (경량 grep/sed, jq/yq 불필요) ──

yaml_get_default() {
    local key="$1"
    grep "^  ${key}:" "${ACCOUNTS_FILE}" 2>/dev/null | head -1 \
        | sed 's/.*: *//' | sed 's/ *#.*//' | tr -d '"'
}

yaml_get_pool_strategy() {
    local pool="$1" in_pool=0
    while IFS= read -r line; do
        if echo "$line" | grep -qE "^  ${pool}:"; then in_pool=1; continue; fi
        if [[ "$in_pool" -eq 1 ]]; then
            if echo "$line" | grep -qE '^  [a-z]' && ! echo "$line" | grep -qE '^\s{4,}'; then break; fi
            if echo "$line" | grep -q 'strategy:'; then
                echo "$line" | sed 's/.*strategy: *//' | sed 's/ *#.*//' | tr -d '"'; return
            fi
        fi
    done < "${ACCOUNTS_FILE}"
    yaml_get_default "strategy"
    return 0
}

#  출력 포맷 (한 줄당 한 계정):
#    id|auth_type|auth_value|weight|enabled
#  여기서 auth_value 는 auth_type 에 따라 다음을 의미한다:
#    oauth_codex      → codex_home 경로 (~ 확장 후)
#    oauth_openclaw   → openclaw 프로파일 이름
#    api_key          → 환경변수 이름 (예: ZAI_API_KEY)
yaml_get_pool_accounts() {
    local pool="$1" in_pool=0 in_accounts=0
    local cid="" ctype="" cval="" cw="5" ce="true"
    _emit() {
        local av="$cval"
        # ~ 확장 (oauth_codex 등)
        case "$av" in "~"*) av="${HOME}${av#\~}";; esac
        echo "${cid}|${ctype}|${av}|${cw}|${ce}"
    }
    while IFS= read -r line; do
        if echo "$line" | grep -qE "^  ${pool}:"; then in_pool=1; continue; fi
        [[ "$in_pool" -eq 0 ]] && continue
        if echo "$line" | grep -qE '^  [a-z]' && ! echo "$line" | grep -qE '^\s{4,}'; then break; fi
        if echo "$line" | grep -q 'accounts:'; then in_accounts=1; continue; fi
        [[ "$in_accounts" -eq 0 ]] && continue
        if echo "$line" | grep -qE '^\s+- id:'; then
            [[ -n "$cid" ]] && _emit
            cid=$(echo "$line" | sed 's/.*id: *//' | sed 's/ *#.*//' | tr -d '"')
            ctype="" cval="" cw="5" ce="true"; continue
        fi
        if echo "$line" | grep -q 'auth_type:'; then
            ctype=$(echo "$line" | sed 's/.*auth_type: *//' | sed 's/ *#.*//' | tr -d '"')
        elif echo "$line" | grep -q 'codex_home:'; then
            cval=$(echo "$line" | sed 's/.*codex_home: *//' | sed 's/ *#.*//' | tr -d '"')
            [[ -z "$ctype" ]] && ctype="oauth_codex"
        elif echo "$line" | grep -q 'openclaw_profile:'; then
            cval=$(echo "$line" | sed 's/.*openclaw_profile: *//' | sed 's/ *#.*//' | tr -d '"')
            [[ -z "$ctype" ]] && ctype="oauth_openclaw"
        elif echo "$line" | grep -q 'env_key:'; then
            cval=$(echo "$line" | sed 's/.*env_key: *//' | sed 's/ *#.*//' | tr -d '"')
            [[ -z "$ctype" ]] && ctype="api_key"
        elif echo "$line" | grep -q 'weight:'; then
            cw=$(echo "$line" | sed 's/.*weight: *//' | sed 's/ *#.*//' | tr -d '"')
        elif echo "$line" | grep -q 'enabled:'; then
            ce=$(echo "$line" | sed 's/.*enabled: *//' | sed 's/ *#.*//' | tr -d '"')
        fi
    done < "${ACCOUNTS_FILE}"
    [[ -n "$cid" ]] && _emit
    return 0
}

yaml_get_pool_names() {
    local in_pools=0
    while IFS= read -r line; do
        if echo "$line" | grep -qE '^pools:'; then in_pools=1; continue; fi
        [[ "$in_pools" -eq 1 ]] && echo "$line" | grep -qE '^  [a-z][a-z0-9_-]*:' \
            && ! echo "$line" | grep -qE '^\s{4,}' \
            && echo "$line" | sed 's/:.*//' | tr -d ' '
    done < "${ACCOUNTS_FILE}"
    return 0
}

ensure_state() {
    [[ -f "${POOL_STATE}" ]] || echo '{"pools":{},"last_updated":"'"$(now_iso)"'"}' > "${POOL_STATE}"
}

get_cooldown_seconds()   { local v; v=$(yaml_get_default "cooldown_seconds"); echo "${v:-60}"; }
get_max_cooldown()       { local v; v=$(yaml_get_default "max_cooldown_seconds"); echo "${v:-600}"; }
get_backoff_multiplier() { local v; v=$(yaml_get_default "backoff_multiplier"); echo "${v:-2}"; }

# ── next: 라운드 로빈 계정 선택 ──

action_next() {
    local pool="${1:?풀 이름 필요 (예: zai, openai)}"
    ensure_state
    local accounts; accounts=$(yaml_get_pool_accounts "$pool")
    [[ -z "$accounts" ]] && { log_error "풀 '${pool}'에 계정 없음"; exit 1; }

    local selected
    selected=$(_PS="${POOL_STATE}" _P="${pool}" _N="$(now_epoch)" \
        _NI="$(now_iso)" _A="${accounts}" _HM="${HOME}" python3 -c '
import json,sys,os
def is_available(at,av):
    if at=="api_key":
        return bool(os.environ.get(av,""))
    if at=="oauth_codex":
        return bool(av) and os.path.isfile(os.path.join(av,"auth.json"))
    if at=="oauth_openclaw":
        d = os.path.join(os.environ["_HM"],".openclaw") if av in ("default","",None) \
            else os.path.join(os.environ["_HM"],".openclaw-{}".format(av))
        return os.path.isdir(d)
    return False
p=os.environ["_PS"]
with open(p) as f: s=json.load(f)
pn,now=os.environ["_P"],int(os.environ["_N"])
if pn not in s.get("pools",{}):
    s["pools"][pn]={"last_index":-1,"accounts":{}}
ps=s["pools"][pn]; cs=[]
for ln in os.environ["_A"].strip().split("\n"):
    pt=ln.split("|")
    if len(pt)<5: continue
    aid,at,av,w,en=pt[0],pt[1],pt[2],int(pt[3]),pt[4].strip()
    if en!="true" or not is_available(at,av): continue
    if now<ps["accounts"].get(aid,{}).get("cooldown_until",0): continue
    cs.append({"id":aid,"at":at,"av":av,"w":w})
if not cs: print("ERROR:ALL_COOLDOWN"); sys.exit(0)
cs.sort(key=lambda x:-x["w"])
ni=(ps.get("last_index",-1)+1)%len(cs); sel=cs[ni]
ps["last_index"]=ni
a=ps["accounts"].setdefault(sel["id"],{})
a["last_used"]=now; a["use_count"]=a.get("use_count",0)+1
s["last_updated"]=os.environ["_NI"]
with open(p,"w") as f: json.dump(s,f,indent=2,ensure_ascii=False)
print("{}|{}|{}".format(sel["id"],sel["at"],sel["av"]))
')

    if [[ "$selected" == "ERROR:ALL_COOLDOWN" ]]; then
        log_error "풀 '${pool}': 모든 계정 쿨다운 중"
        echo "error: all_accounts_in_cooldown"; return 1
    fi
    local acct_id acct_type acct_value
    IFS='|' read -r acct_id acct_type acct_value <<< "$selected"
    log_info "선택: ${acct_id} (${acct_type}=${acct_value}) [풀=${pool}]"
    printf 'account_selection:\n  pool: %s\n  account_id: %s\n  auth_type: %s\n  auth_value: %s\n  strategy: round_robin\n  timestamp: %s\n' \
        "$pool" "$acct_id" "$acct_type" "$acct_value" "$(now_iso)"
}

# ── fanout: 전체 계정 동시 호출용 ──

action_fanout() {
    local pool="${1:?풀 이름 필요}"
    ensure_state
    local accounts; accounts=$(yaml_get_pool_accounts "$pool")
    [[ -z "$accounts" ]] && { log_error "풀 '${pool}'에 계정 없음"; exit 1; }

    _PS="${POOL_STATE}" _P="${pool}" _N="$(now_epoch)" _A="${accounts}" _HM="${HOME}" python3 -c '
import json,os
def is_available(at,av):
    if at=="api_key":
        return bool(os.environ.get(av,""))
    if at=="oauth_codex":
        return bool(av) and os.path.isfile(os.path.join(av,"auth.json"))
    if at=="oauth_openclaw":
        d = os.path.join(os.environ["_HM"],".openclaw") if av in ("default","",None) \
            else os.path.join(os.environ["_HM"],".openclaw-{}".format(av))
        return os.path.isdir(d)
    return False
with open(os.environ["_PS"]) as f: s=json.load(f)
pn,now=os.environ["_P"],int(os.environ["_N"])
ps=s.get("pools",{}).get(pn,{"accounts":{}})
av,cd=[],[]
for ln in os.environ["_A"].strip().split("\n"):
    pt=ln.split("|")
    if len(pt)<5: continue
    aid,at,avv,w,en=pt[0],pt[1],pt[2],int(pt[3]),pt[4].strip()
    if en!="true" or not is_available(at,avv): continue
    if now<ps.get("accounts",{}).get(aid,{}).get("cooldown_until",0):
        cd.append(aid); continue
    av.append({"id":aid,"at":at,"av":avv,"w":w})
av.sort(key=lambda x:-x["w"])
print("fan_out_accounts:")
print("  pool: {}".format(pn))
print("  available_count: {}".format(len(av)))
print("  cooldown_count: {}".format(len(cd)))
print("  accounts:")
for a in av:
    print("    - id: {}".format(a["id"]))
    print("      auth_type: {}".format(a["at"]))
    print("      auth_value: {}".format(a["av"]))
    print("      weight: {}".format(a["w"]))
if cd: print("  in_cooldown: [{}]".format(", ".join(cd)))
'
}

# ── cooldown: 지수 백오프 쿨다운 등록 ──

action_cooldown() {
    local pool="${1:?풀 이름 필요}" account="${2:?계정 ID 필요}" reason="${3:-rate_limit}"
    ensure_state
    _PS="${POOL_STATE}" _P="${pool}" _AI="${account}" _R="${reason}" \
    _N="$(now_epoch)" _CB="$(get_cooldown_seconds)" \
    _MC="$(get_max_cooldown)" _BK="$(get_backoff_multiplier)" _NI="$(now_iso)" \
    python3 -c '
import json,os
p=os.environ["_PS"]
with open(p) as f: s=json.load(f)
pn,ai=os.environ["_P"],os.environ["_AI"]
now,cb=int(os.environ["_N"]),int(os.environ["_CB"])
mc,bk=int(os.environ["_MC"]),int(os.environ["_BK"])
if pn not in s.get("pools",{}):
    s["pools"][pn]={"last_index":-1,"accounts":{}}
a=s["pools"][pn]["accounts"].setdefault(ai,{})
c=a.get("consecutive_errors",0)+1; a["consecutive_errors"]=c
cd=min(cb*(bk**(c-1)),mc)
a["cooldown_until"]=now+int(cd)
a["cooldown_reason"]=os.environ["_R"]
a["cooldown_started"]=now
s["last_updated"]=os.environ["_NI"]
with open(p,"w") as f: json.dump(s,f,indent=2,ensure_ascii=False)
print(f"cooldown: {ai} for {int(cd)}s (attempt #{c})")
'
    log_warn "쿨다운: ${account} [풀=${pool}, 사유=${reason}]"
}

# ── release: 쿨다운 해제 ──

action_release() {
    local pool="${1:?풀 이름 필요}" account="${2:?계정 ID 필요}"
    ensure_state
    _PS="${POOL_STATE}" _P="${pool}" _AI="${account}" _NI="$(now_iso)" \
    python3 -c '
import json,os
p=os.environ["_PS"]
with open(p) as f: s=json.load(f)
pn,ai=os.environ["_P"],os.environ["_AI"]
if pn in s.get("pools",{}):
    a=s["pools"][pn].get("accounts",{}).get(ai,{})
    for k in("cooldown_until","cooldown_reason","cooldown_started"):a.pop(k,None)
    a["consecutive_errors"]=0
s["last_updated"]=os.environ["_NI"]
with open(p,"w") as f: json.dump(s,f,indent=2,ensure_ascii=False)
'
    log_info "쿨다운 해제: ${account} [풀=${pool}]"
}

# ── status: 상태 조회 ──

action_status() {
    local pool="${1:-}"
    ensure_state
    if [[ -n "$pool" ]]; then
        local accounts strategy
        accounts=$(yaml_get_pool_accounts "$pool")
        strategy=$(yaml_get_pool_strategy "$pool")
        _PS="${POOL_STATE}" _P="${pool}" _N="$(now_epoch)" \
        _A="${accounts}" _S="${strategy}" _HM="${HOME}" python3 -c '
import json,os
def is_available(at,av):
    if at=="api_key":
        return bool(os.environ.get(av,""))
    if at=="oauth_codex":
        return bool(av) and os.path.isfile(os.path.join(av,"auth.json"))
    if at=="oauth_openclaw":
        d = os.path.join(os.environ["_HM"],".openclaw") if av in ("default","",None) \
            else os.path.join(os.environ["_HM"],".openclaw-{}".format(av))
        return os.path.isdir(d)
    return False
with open(os.environ["_PS"]) as f: s=json.load(f)
pn,now=os.environ["_P"],int(os.environ["_N"])
ps=s.get("pools",{}).get(pn,{"last_index":-1,"accounts":{}})
print("pool_status:")
print("  pool: {}".format(pn))
print("  strategy: {}".format(os.environ["_S"]))
print("  last_index: {}".format(ps.get("last_index",-1)))
print("  accounts:")
for ln in os.environ["_A"].strip().split("\n"):
    pt=ln.split("|")
    if len(pt)<5: continue
    aid,at,avv,w,en=pt[0],pt[1],pt[2],int(pt[3]),pt[4].strip()
    a=ps.get("accounts",{}).get(aid,{})
    ht=is_available(at,avv)
    cu=a.get("cooldown_until",0); ic=now<cu
    st=("disabled" if en!="true"
        else "no_auth" if not ht
        else "cooldown" if ic
        else "ready")
    print("    - id: {}".format(aid))
    print("      auth_type: {}".format(at))
    print("      auth_value: {}".format(avv))
    print("      weight: {}".format(w))
    print("      status: {}".format(st))
    print("      use_count: {}".format(a.get("use_count",0)))
    if ic:
        print("      cooldown_remaining: {}s".format(max(0,cu-now)))
        print("      cooldown_reason: {}".format(a.get("cooldown_reason","unknown")))
'
    else
        echo "account_pool_summary:"
        echo "  state_file: ${POOL_STATE}"
        local pools; pools=$(yaml_get_pool_names)
        for p in $pools; do
            local st ac
            st=$(yaml_get_pool_strategy "$p")
            ac=$(yaml_get_pool_accounts "$p" | wc -l | tr -d ' ')
            echo "  - pool: ${p}"
            echo "    strategy: ${st}"
            echo "    account_count: ${ac}"
        done
    fi
}

# ── reset: 상태 초기화 ──

action_reset() {
    local pool="${1:-}"
    if [[ -n "$pool" ]]; then
        ensure_state
        _PS="${POOL_STATE}" _P="${pool}" _NI="$(now_iso)" python3 -c '
import json,os
p=os.environ["_PS"]
with open(p) as f: s=json.load(f)
s["pools"].pop(os.environ["_P"],None)
s["last_updated"]=os.environ["_NI"]
with open(p,"w") as f: json.dump(s,f,indent=2,ensure_ascii=False)
'
        log_info "풀 '${pool}' 초기화 완료"
    else
        echo '{"pools":{},"last_updated":"'"$(now_iso)"'"}' > "${POOL_STATE}"
        log_info "전체 풀 초기화 완료"
    fi
}

# ── 메인 ──

ACTION="${1:-}"; shift || true
case "$ACTION" in
    next)     action_next "$@" ;;
    fanout)   action_fanout "$@" ;;
    cooldown) action_cooldown "$@" ;;
    release)  action_release "$@" ;;
    status)   action_status "$@" ;;
    reset)    action_reset "$@" ;;
    *)
        echo "사용법: $0 <액션> [인자...]" >&2
        echo "  next <pool> | fanout <pool> | cooldown <pool> <acct> [reason]" >&2
        echo "  release <pool> <acct> | status [pool] | reset [pool]" >&2
        exit 1 ;;
esac
