# ohmyclaw — robustness gates (P1-P7)
# Usage: make test | make lint | make schema | make doctor | make ci

SKILL := skills/ohmyclaw
BATS  ?= bats
JQ    ?= jq
AJV   ?= npx -y ajv-cli@5

.PHONY: help test lint schema doctor syntax ci clean

help:
	@echo "ohmyclaw — robustness gates"
	@echo ""
	@echo "  make test     bats 슈트 (58+ 케이스)"
	@echo "  make lint     bash -n + (가능 시) shellcheck"
	@echo "  make schema   routing.json + sample bridge event 를 ajv 로 검증"
	@echo "  make doctor   engine.sh doctor"
	@echo "  make syntax   모든 .sh 의 bash -n"
	@echo "  make ci       lint + schema + syntax + test (CI 와 동일)"
	@echo "  make clean    tmp 격리 state 청소"

syntax:
	@echo "→ bash -n"
	@for s in $(SKILL)/*.sh; do bash -n "$$s" && echo "  ✓ $$s" || exit 1; done

lint: syntax
	@if command -v shellcheck >/dev/null 2>&1; then \
	  echo "→ shellcheck"; \
	  shellcheck -S warning $(SKILL)/*.sh || exit 1; \
	else \
	  echo "  (shellcheck absent — bash -n only)"; \
	fi

schema:
	@echo "→ jq empty routing.json"
	@$(JQ) empty $(SKILL)/routing.json
	@echo "  ✓ valid JSON"
	@echo "→ ajv: routing.json against routing.schema.json"
	@$(AJV) validate --spec=draft2020 --errors=text \
	  -s $(SKILL)/schemas/routing.schema.json \
	  -d $(SKILL)/routing.json
	@echo "→ ajv: sample bridge event"
	@TMP_EV=/tmp/ohmyclaw-bridge-event-$$$$.json && \
	 printf '{"version":"1.0.0","type":"session-start","session":{"id":"smoke"},"ts":"2026-05-23T00:00:00Z","payload":{"summary":"smoke"}}' > $$TMP_EV && \
	 $(AJV) validate --spec=draft2020 --errors=text \
	   -s $(SKILL)/schemas/bridge-event.schema.json -d $$TMP_EV && \
	 rm -f $$TMP_EV

doctor:
	@$(SKILL)/engine.sh doctor

test:
	@if ! command -v $(BATS) >/dev/null 2>&1; then \
	  echo "ERROR: bats 미설치 — 'brew install bats-core' 또는 'apt install bats'"; \
	  exit 1; \
	fi
	@$(BATS) tests/

ci: lint schema doctor test
	@echo ""
	@echo "✅ all gates passed"

clean:
	@rm -rf /tmp/ohmyclaw-bats.* /tmp/ohmyclaw-bin.* 2>/dev/null || true
	@echo "cleaned"
